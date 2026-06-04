// translator_core.cpp - Translation functionality for WoWTranslate
// Reengineered to use Official Baidu Translation API with MD5 Authentication

#include <windows.h>
#include <wininet.h>
#include <string>
#include <algorithm>
#include <sstream>
#include <iomanip>
#include <codecvt>
#include <locale>
#include <vector>
#include <cstdio>
// #include <wincrypt.h> 移除，已交由 utils.cpp 统一处理 MD5

#include "../include/translator_core.h"
#include "../include/logging.h"
#include "../include/utils.h"

#pragma comment(lib, "wininet.lib")

// 确保老旧编译环境下也能识别 Win7 的 TLS 1.2 标记与 WinINet 选项
#ifndef FLAG_SECURE_PROTOCOL_TLS1_2
#define FLAG_SECURE_PROTOCOL_TLS1_2 0x00000800
#endif

#ifndef INTERNET_OPTION_SECURE_PROTOCOLS
#define INTERNET_OPTION_SECURE_PROTOCOLS 31
#endif

using namespace std;

// UTF-8 字符集转换辅助器
static string ConvertCodepointToUTF8(unsigned int codepoint) {
    string result;
    if (codepoint <= 0x7F) {
        result += static_cast<char>(codepoint);
    } else if (codepoint <= 0x7FF) {
        result += static_cast<char>(0xC0 | (codepoint >> 6));
        result += static_cast<char>(0x80 | (codepoint & 0x3F));
    } else if (codepoint <= 0xFFFF) {
        result += static_cast<char>(0xE0 | (codepoint >> 12));
        result += static_cast<char>(0x80 | ((codepoint >> 6) & 0x3F));
        result += static_cast<char>(0x80 | (codepoint & 0x3F));
    } else if (codepoint <= 0x10FFFF) {
        result += static_cast<char>(0xF0 | (codepoint >> 18));
        result += static_cast<char>(0x80 | ((codepoint >> 12) & 0x3F));
        result += static_cast<char>(0x80 | ((codepoint >> 6) & 0x3F));
        result += static_cast<char>(0x80 | (codepoint & 0x3F));
    }
    return result;
}

// 轻量级 JSON 转义字符解析器
class SimpleJsonParser {
public:
    static string unescapeJson(const string& input) {
        string result = input;
        size_t pos = 0;

        while ((pos = result.find("\\\"", pos)) != string::npos) {
            result.replace(pos, 2, "\"");
            pos += 1;
        }
        pos = 0;
        while ((pos = result.find("\\\\", pos)) != string::npos) {
            result.replace(pos, 2, "\\");
            pos += 1;
        }
        pos = 0;
        while ((pos = result.find("\\n", pos)) != string::npos) {
            result.replace(pos, 2, "\n");
            pos += 1;
        }
        pos = 0;
        while ((pos = result.find("\\r", pos)) != string::npos) {
            result.replace(pos, 2, "\r");
            pos += 1;
        }
        pos = 0;
        while ((pos = result.find("\\t", pos)) != string::npos) {
            result.replace(pos, 2, "\t");
            pos += 1;
        }

        pos = 0;
        while ((pos = result.find("\\u", pos)) != string::npos) {
            if (pos + 5 < result.length()) {
                string hexStr = result.substr(pos + 2, 4);
                try {
                    unsigned int codepoint = stoul(hexStr, nullptr, 16);
                    string utf8_char = ConvertCodepointToUTF8(codepoint);
                    result.replace(pos, 6, utf8_char);
                    pos += utf8_char.length();
                } catch (...) {
                    pos += 6;
                }
            } else {
                break;
            }
        }
        return result;
    }
};

// 全局变量定义
unique_ptr<TranslationClient> g_translator = nullptr;
char g_translation_buffer[4096] = {0};
char g_error_buffer[256] = {0};

TranslationClient::TranslationClient()
    : hSession(nullptr), hConnect(nullptr), initialized(false), running(false) {
}

TranslationClient::~TranslationClient() {
    Cleanup();
}

bool TranslationClient::Initialize() {
    if (initialized) Cleanup();

    // 加载或创建本地 wt_config.ini 配置文件
    LoadConfig();

    // 百度翻译开放平台官方标准 HTTPS 通信终结点
    const string host = "api.fanyi.baidu.com";
    const int port = 443;

    LOG_INFO("Initializing Baidu Translate Official API Client (WinINet HTTPS Mode)");

    hSession = InternetOpenW(L"WoWTranslate-Client/2.0",
                             INTERNET_OPEN_TYPE_PRECONFIG,
                             NULL, NULL, 0);
    if (!hSession) {
        LOG_ERROR("Failed to initialize WinINet session for Baidu API");
        return false;
    }

    // 强制开启强加密传输 TLS 1.2 支持
    DWORD protocols = FLAG_SECURE_PROTOCOL_TLS1_2;
    InternetSetOptionW(hSession, INTERNET_OPTION_SECURE_PROTOCOLS, &protocols, sizeof(protocols));

    // 设置稳定合理的网络超时时间 (8秒)
    DWORD timeout = 8000;
    InternetSetOptionW(hSession, INTERNET_OPTION_CONNECT_TIMEOUT, &timeout, sizeof(timeout));
    InternetSetOptionW(hSession, INTERNET_OPTION_RECEIVE_TIMEOUT, &timeout, sizeof(timeout));
    InternetSetOptionW(hSession, INTERNET_OPTION_SEND_TIMEOUT, &timeout, sizeof(timeout));

    wstring wHost(host.begin(), host.end());
    hConnect = InternetConnectW(hSession, wHost.c_str(),
                                static_cast<INTERNET_PORT>(port),
                                NULL, NULL, INTERNET_SERVICE_HTTP, 0, 0);
    if (!hConnect) {
        LOG_ERROR("Failed to connect to api.fanyi.baidu.com");
        InternetCloseHandle(hSession);
        hSession = nullptr;
        return false;
    }

    running = true;
    workerThread = thread(&TranslationClient::WorkerThreadFunc, this);
    initialized = true;
    LOG_INFO("Baidu Official Translation Client Engine Started Successfully");
    return true;
}

void TranslationClient::Cleanup() {
    if (running) {
        running = false;
        if (workerThread.joinable()) {
            workerThread.join();
        }
    }

    if (hConnect) {
        InternetCloseHandle(hConnect);
        hConnect = nullptr;
    }

    if (hSession) {
        InternetCloseHandle(hSession);
        hSession = nullptr;
    }

    cache.clear();
    initialized = false;
    LOG_INFO("Baidu Translation Client Cleanup Complete");
}

// 【修复】重定向至全局 utils 的 UrlEncode，避免逻辑冲突
string TranslationClient::UrlEncode(const string& text) {
    return ::UrlEncode(text);
}

string TranslationClient::GenerateCacheKey(const string& text, const string& sourceLang, const string& targetLang) {
    return sourceLang + "->" + targetLang + ":" + text;
}

void TranslationClient::CleanExpiredCache() {
    DWORD currentTime = GetTickCount();
    auto it = cache.begin();

    while (it != cache.end()) {
        if (currentTime - it->second.timestamp > CACHE_EXPIRY_MS) {
            it = cache.erase(it);
        } else {
            ++it;
        }
    }

    if (cache.size() > MAX_CACHE_SIZE) {
        size_t removeCount = cache.size() - MAX_CACHE_SIZE / 2;
        for (size_t i = 0; i < removeCount && !cache.empty(); ++i) {
            cache.erase(cache.begin());
        }
    }
}

// 将魔兽世界插件标准的语言代码精确映射为百度 API 格式
string TranslationClient::MapLangCode(const string& lang) {
    if (lang == "zh" || lang == "zh-CN" || lang == "zh-Hans") return "zh";
    if (lang == "zh-TW" || lang == "zh-Hant" || lang == "cht") return "cht";
    return lang;
}

string TranslationClient::HttpsPost(const string& path, const string& postData) {
    return "";
}

// 精准解析百度官方返回的 JSON 数据流
string TranslationClient::ParseBaiduResponse(const string& json) {
    if (json.find("error_code") != string::npos) {
        size_t msgPos = json.find("\"error_msg\":\"");
        if (msgPos != string::npos) {
            size_t start = msgPos + 13;
            size_t end = json.find("\"", start);
            if (end != string::npos) {
                LOG_ERROR("Baidu API Response Error: " + json.substr(start, end - start));
            }
        }
        return "";
    }

    string extractedResult = "";
    size_t pos = 0;
    
    while ((pos = json.find("\"dst\":\"", pos)) != string::npos) {
        pos += 7;
        size_t end = pos;
        while (end < json.length()) {
            if (json[end] == '"' && json[end - 1] != '\\') {
                break;
            }
            end++;
        }
        if (end >= json.length()) break;
        
        if (!extractedResult.empty()) {
            extractedResult += "\n";
        }
        extractedResult += json.substr(pos, end - pos);
        pos = end + 1;
    }
    
    return SimpleJsonParser::unescapeJson(extractedResult);
}

// 核心功能重构：彻底解决 GBK 与 UTF-8 的时空混乱问题
TranslationResult TranslationClient::TranslateText(const string& text, string& result,
                                                   const string& sourceLang,
                                                   const string& targetLang) {
    if (!initialized || text.empty()) return TranslationResult::INVALID_PARAMS;

    // 优先读取本地高频缓存 (缓存键和值均统一采用纯正 UTF-8 格式)
    string cacheKey = GenerateCacheKey(text, sourceLang, targetLang);
    auto cacheIt = cache.find(cacheKey);
    if (cacheIt != cache.end() && (GetTickCount() - cacheIt->second.timestamp) < CACHE_EXPIRY_MS) {
        result = cacheIt->second.translation;
        return TranslationResult::SUCCESS;
    }

    CleanExpiredCache();

    // 【优化修复 1】: 现代魔兽客户端（如乌龟服）本身全流程采用 UTF-8 编码，直接使用原文，无需画蛇添足做 ANSI 转换
    string utf8Text = text;

    // 检查授权秘钥完整性
    if (m_appId.empty() || m_secretKey.empty()) {
        LOG_ERROR("Baidu API Credentials missing. Use '/wtkey <AppID> <SecretKey>' in game first.");
        return TranslationResult::API_ERROR;
    }

    string sl = MapLangCode(sourceLang);
    string tl = MapLangCode(targetLang);
    
    // 生成百度鉴权三要素：随机盐值 (Salt) 和安全签名 (Sign)
    string salt = to_string(GetTickCount());
    
    // 签名使用纯正的 UTF-8 文本进行拼接计算
    string signSource = m_appId + utf8Text + salt + m_secretKey; 
    string md5Sign = ::CalculateMD5(signSource); // 统一调用 utils 中的原生 MD5

    // URL Encode 对 UTF-8 的文本操作
    string postData = "q=" + ::UrlEncode(utf8Text) +
                      "&from=" + sl +
                      "&to=" + tl +
                      "&appid=" + m_appId +
                      "&salt=" + salt +
                      "&sign=" + md5Sign;

    // 开启安全的 POST 请求通道
    HINTERNET hPostReq = HttpOpenRequestW(hConnect, L"POST", L"/api/trans/vip/translate", 
                                          nullptr, nullptr, nullptr, 
                                          INTERNET_FLAG_SECURE | INTERNET_FLAG_RELOAD | INTERNET_FLAG_NO_CACHE_WRITE, 0);
    if (!hPostReq) {
        LOG_ERROR("Failed to open HTTPS POST request handle");
        return TranslationResult::NETWORK_ERROR;
    }

    DWORD flags = SECURITY_FLAG_IGNORE_UNKNOWN_CA | SECURITY_FLAG_IGNORE_CERT_CN_INVALID | SECURITY_FLAG_IGNORE_CERT_DATE_INVALID;
    InternetSetOptionW(hPostReq, INTERNET_OPTION_SECURITY_FLAGS, &flags, sizeof(flags));

    wstring headers = L"Content-Type: application/x-www-form-urlencoded\r\n";

    LOG_DEBUG("Sending Request to Baidu API. Payload Length: " + to_string(postData.length()));

    string response;
    BOOL res = HttpSendRequestW(hPostReq, headers.c_str(), (DWORD)-1, (LPVOID)postData.c_str(), (DWORD)postData.length());
    
    if (res) {
        DWORD statusCode = 0;
        DWORD statusLen  = sizeof(DWORD);
        HttpQueryInfoW(hPostReq, HTTP_QUERY_STATUS_CODE | HTTP_QUERY_FLAG_NUMBER, &statusCode, &statusLen, NULL);
            
        if (statusCode == 429) {
            LOG_WARNING("Baidu API Rate Limited (HTTP 429)");
            InternetCloseHandle(hPostReq);
            return TranslationResult::RATE_LIMITED;
        }

        char buffer[8192];
        DWORD bytesRead = 0;
        while (InternetReadFile(hPostReq, buffer, sizeof(buffer) - 1, &bytesRead) && bytesRead > 0) {
            response.append(buffer, bytesRead);
        }
    } else {
        LOG_ERROR("Baidu HTTPS Post execution failed. GetLastError: " + to_string(GetLastError()));
    }
    InternetCloseHandle(hPostReq);

    if (response.empty()) {
        LOG_ERROR("Received empty response from Baidu API server");
        return TranslationResult::NETWORK_ERROR;
    }

    // 解析过滤回传数据 (此时 translationUtf8 是纯正的 UTF-8 编码)
    string translationUtf8 = ParseBaiduResponse(response);

    if (translationUtf8.empty()) {
        LOG_ERROR("Baidu Response parse failure. Raw payload: " + response.substr(0, 150));
        return TranslationResult::API_ERROR;
    }

    // 【核心修复 4】: 移除毁灭性的 Utf8ToAnsi 转换！直接将原汁原味的 UTF-8 结果回传并加入缓存，完美适配现代多语言游戏客户端
    cache[cacheKey] = CacheEntry(translationUtf8);
    result = translationUtf8;
    LOG_DEBUG("Successfully Translated Text!");
    return TranslationResult::SUCCESS;
}

bool TranslationClient::TranslateAsync(const string& requestId, const string& text,
                                       const string& sourceLang, const string& targetLang) {
    if (!initialized || !running) return false;

    lock_guard<mutex> lock(requestMutex);
    requestQueue.push(AsyncRequest(requestId, text, sourceLang, targetLang));
    return true;
}

bool TranslationClient::PollResult(string& requestId, string& translation, string& error) {
    lock_guard<mutex> lock(resultMutex);

    if (resultQueue.empty()) return false;

    AsyncResult result = resultQueue.front();
    resultQueue.pop();

    requestId = result.requestId;
    translation = result.translation;
    error = result.error;

    return true;
}

size_t TranslationClient::GetPendingCount() {
    lock_guard<mutex> lock(requestMutex);
    return requestQueue.size();
}

void TranslationClient::WorkerThreadFunc() {
    LOG_INFO("Async Worker thread channel standby");

    while (running) {
        AsyncRequest request;
        bool hasRequest = false;

        {
            lock_guard<mutex> lock(requestMutex);
            if (!requestQueue.empty()) {
                request = requestQueue.front();
                requestQueue.pop();
                hasRequest = true;
            }
        }

        if (hasRequest) {
            string translation;
            string error;

            TranslationResult tr = TranslateText(request.text, translation,
                                                 request.sourceLang, request.targetLang);

            if (tr != TranslationResult::SUCCESS) {
                switch (tr) {
                    case TranslationResult::NETWORK_ERROR:  error = "network error"; break;
                    case TranslationResult::API_ERROR:      error = "API credentials error"; break;
                    case TranslationResult::ENCODING_ERROR: error = "encoding error"; break;
                    case TranslationResult::TIMEOUT_ERROR:  error = "timeout"; break;
                    case TranslationResult::RATE_LIMITED:   error = "rate limited"; break;
                    default:                                error = "unknown error"; break;
                }
                translation = "";
            }

            {
                lock_guard<mutex> lock(resultMutex);
                resultQueue.push(AsyncResult(request.requestId, translation, error));
            }
        } else {
            Sleep(50);
        }
    }
    LOG_INFO("Async Worker thread stopped safely");
}

string TranslationClient::GetConfigPath() {
    char dllPath[MAX_PATH] = {0};
    GetModuleFileNameA(GetModuleHandleA("WoWTranslate.dll"), dllPath, MAX_PATH);
    string path(dllPath);
    size_t pos = path.find_last_of("\\/");
    if (pos != string::npos) {
        path = path.substr(0, pos + 1) + "wt_config.ini";
    } else {
        path = "wt_config.ini";
    }
    return path;
}

void TranslationClient::LoadConfig() {
    string iniPath = GetConfigPath();
    char appBuf[256] = {0};
    char keyBuf[256] = {0};

    GetPrivateProfileStringA("BaiduAPI", "AppID", "", appBuf, sizeof(appBuf), iniPath.c_str());
    GetPrivateProfileStringA("BaiduAPI", "SecretKey", "", keyBuf, sizeof(keyBuf), iniPath.c_str());

    m_appId = appBuf;
    m_secretKey = keyBuf;

    if (m_appId.empty() || m_secretKey.empty()) {
        LOG_WARNING("Baidu API Configuration is currently unassigned in wt_config.ini");
    } else {
        LOG_INFO("Baidu API Credentials loaded into memory cache from INI");
    }
}

void TranslationClient::SaveConfig(const string& appId, const string& secretKey) {
    string iniPath = GetConfigPath();
    
    WritePrivateProfileStringA("BaiduAPI", "AppID", appId.c_str(), iniPath.c_str());
    WritePrivateProfileStringA("BaiduAPI", "SecretKey", secretKey.c_str(), iniPath.c_str());

    m_appId = appId;
    m_secretKey = secretKey;
    
    LOG_INFO("New Baidu API Credentials dynamically saved to disk INI");
}
