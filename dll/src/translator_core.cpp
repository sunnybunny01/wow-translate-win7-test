// translator_core.cpp - Translation functionality for WoWTranslate
// Sends requests to cn.bing.com — Microsoft Bing Free Translation (Domestic & Cookie Optimized)

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

#include "../include/translator_core.h"
#include "../include/logging.h"
#include "../include/utils.h"

#pragma comment(lib, "wininet.lib")

// 【关键修复】确保老旧编译环境下也能识别 Win7 的 TLS 1.2 标记与 WinINet 选项
#ifndef FLAG_SECURE_PROTOCOL_TLS1_2
#define FLAG_SECURE_PROTOCOL_TLS1_2 0x00000800
#endif

#ifndef INTERNET_OPTION_SECURE_PROTOCOLS
#define INTERNET_OPTION_SECURE_PROTOCOLS 31
#endif

using namespace std;

// 提取字符串中间内容的辅助函数 (用于提取Token和Cookie)
static string ExtractBetween(const string& str, const string& start, const string& end) {
    size_t s = str.find(start);
    if (s == string::npos) return "";
    s += start.length();
    size_t e = str.find(end, s);
    if (e == string::npos) return "";
    return str.substr(s, e - s);
}

// UTF-8 codepoint encoder
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

// Simple JSON parser
class SimpleJsonParser {
public:
    static string unescapeJson(const string& input) {
        string result = input;
        size_t pos = 0;

        // Unescape basic characters
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

        // Handle Unicode escape sequences \uXXXX
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

// Global variables
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

    // 【方案核心】回归中国直连域名，避免被加速器漏掉后无法解析或乱跳
    const std::string host = "cn.bing.com";
    const int port = 443;

    LOG_INFO("Initializing Microsoft Bing Free translation client (WinINet mode - Domestic Optimized)");

    // 伪装成真实的现代浏览器 User-Agent
    hSession = InternetOpenW(L"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36",
                             INTERNET_OPEN_TYPE_PRECONFIG,
                             NULL,
                             NULL,
                             0);
    if (!hSession) {
        LOG_ERROR("Failed to initialize WinINet session");
        return false;
    }

    // 强开 Windows 7 底层的 TLS 1.2 协议支持
    DWORD protocols = FLAG_SECURE_PROTOCOL_TLS1_2;
    InternetSetOptionW(hSession, INTERNET_OPTION_SECURE_PROTOCOLS, &protocols, sizeof(protocols));

    // Set 8-second timeouts for WinINet
    DWORD timeout = 8000;
    InternetSetOptionW(hSession, INTERNET_OPTION_CONNECT_TIMEOUT, &timeout, sizeof(timeout));
    InternetSetOptionW(hSession, INTERNET_OPTION_RECEIVE_TIMEOUT, &timeout, sizeof(timeout));
    InternetSetOptionW(hSession, INTERNET_OPTION_SEND_TIMEOUT, &timeout, sizeof(timeout));

    wstring wHost(host.begin(), host.end());
    hConnect = InternetConnectW(hSession, wHost.c_str(),
                                static_cast<INTERNET_PORT>(port),
                                NULL, NULL, INTERNET_SERVICE_HTTP, 0, 0);
    if (!hConnect) {
        LOG_ERROR("Failed to connect to cn.bing.com via WinINet");
        InternetCloseHandle(hSession);
        hSession = nullptr;
        return false;
    }

    running = true;
    workerThread = thread(&TranslationClient::WorkerThreadFunc, this);
    initialized = true;
    LOG_INFO("Microsoft Bing Free translation client initialized successfully");
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
    LOG_INFO("Translation client cleanup complete");
}

string TranslationClient::UrlEncode(const string& text) {
    ostringstream encoded;
    encoded.fill('0');
    encoded << hex;

    for (unsigned char c : text) {
        if (isalnum(c) || c == '-' || c == '_' || c == '.' || c == '~') {
            encoded << c;
        } else {
            encoded << uppercase;
            encoded << '%' << setw(2) << static_cast<int>(c);
            encoded << nouppercase;
        }
    }

    return encoded.str();
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

string TranslationClient::MapLangCode(const string& lang) {
    if (lang == "zh" || lang == "zh-CN") return "zh-Hans";
    if (lang == "zh-TW") return "zh-Hant";
    return lang;
}

string TranslationClient::HttpsPost(const string& path, const string& postData) {
    return "";
}

string TranslationClient::ParseBingResponse(const string& json) {
    size_t transPos = json.find("\"translations\"");
    if (transPos == string::npos) return "";

    size_t textKeyPos = json.find("\"text\"", transPos);
    if (textKeyPos == string::npos) return "";

    size_t colonPos = json.find(":", textKeyPos);
    if (colonPos == string::npos) return "";

    size_t quoteStart = json.find("\"", colonPos);
    if (quoteStart == string::npos) return "";

    size_t quoteEnd = quoteStart + 1;
    while (quoteEnd < json.length()) {
        if (json[quoteEnd] == '"' && json[quoteEnd - 1] != '\\') {
            break;
        }
        quoteEnd++;
    }

    if (quoteEnd >= json.length()) return "";

    string extracted = json.substr(quoteStart + 1, quoteEnd - quoteStart - 1);
    return SimpleJsonParser::unescapeJson(extracted);
}

// 核心流程：GET获取Token及Cookie -> 携带凭据POST实现零封锁翻译
TranslationResult TranslationClient::TranslateText(const string& text, string& result,
                                                   const string& sourceLang,
                                                   const string& targetLang) {
    if (!initialized) return TranslationResult::INVALID_PARAMS;
    if (text.empty())  return TranslationResult::INVALID_PARAMS;

    string cacheKey = GenerateCacheKey(text, sourceLang, targetLang);
    auto cacheIt = cache.find(cacheKey);
    if (cacheIt != cache.end() &&
        (GetTickCount() - cacheIt->second.timestamp) < CACHE_EXPIRY_MS) {
        result = cacheIt->second.translation;
        return TranslationResult::SUCCESS;
    }

    CleanExpiredCache();

    string sl = MapLangCode(sourceLang);
    string tl = MapLangCode(targetLang);
    
    // === 第一步：GET 首页获取动态防爬虫 Token 并捞取验证 Cookie ===
    string ig, key, token, cookiesReceived;
    HINTERNET hGetReq = HttpOpenRequestW(hConnect, L"GET", L"/translator", nullptr, nullptr, nullptr, INTERNET_FLAG_SECURE | INTERNET_FLAG_RELOAD, 0);
    if (hGetReq) {
        DWORD flags = SECURITY_FLAG_IGNORE_UNKNOWN_CA | SECURITY_FLAG_IGNORE_CERT_CN_INVALID | SECURITY_FLAG_IGNORE_CERT_DATE_INVALID;
        InternetSetOptionW(hGetReq, INTERNET_OPTION_SECURITY_FLAGS, &flags, sizeof(flags));

        if (HttpSendRequestW(hGetReq, nullptr, 0, nullptr, 0)) {
            // 【方案一杀手锏】手动从国内响应头中提取 MUID 等追踪 Cookie，用来绕过微软 205 校验
            char headerBuf[4096] = {0};
            DWORD headerLen = sizeof(headerBuf);
            if (HttpQueryInfoA(hGetReq, HTTP_QUERY_SET_COOKIE, headerBuf, &headerLen, NULL)) {
                string rawCookies(headerBuf, headerLen);
                // 简单的 Cookie 裁剪，组合成给 POST 使用的规范格式
                size_t cPos = 0;
                while ((cPos = rawCookies.find("MUID=", cPos)) != string::npos) {
                    size_t endPos = rawCookies.find(";", cPos);
                    if (endPos != string::npos) {
                        cookiesReceived += rawCookies.substr(cPos, endPos - cPos) + "; ";
                    }
                    cPos = (endPos == string::npos) ? rawCookies.length() : endPos;
                }
            }

            string html;
            char buffer[4096];
            DWORD bytesRead = 0;
            while (InternetReadFile(hGetReq, buffer, sizeof(buffer), &bytesRead) && bytesRead > 0) {
                html.append(buffer, bytesRead);
            }
            
            ig = ExtractBetween(html, "IG:\"", "\"");
            string params = ExtractBetween(html, "params_RichTranslateHelper = [", "]");
            if (!params.empty()) {
                size_t commaPos = params.find(",");
                if (commaPos != string::npos) {
                    key = params.substr(0, commaPos);
                    token = ExtractBetween(params, "\"", "\"");
                }
            }
        }
        InternetCloseHandle(hGetReq);
    }

    // === 第二步：拼接全套凭据并 POST 获取翻译 ===
    string path = "/ttranslatev3?isVertical=1";
    if (!ig.empty()) {
        path += "&IG=" + ig + "&IID=translator.5024.1";
    }
    wstring wPath(path.begin(), path.end());

    HINTERNET hPostReq = HttpOpenRequestW(hConnect, L"POST", wPath.c_str(), nullptr, nullptr, nullptr, INTERNET_FLAG_SECURE | INTERNET_FLAG_RELOAD | INTERNET_FLAG_NO_CACHE_WRITE, 0);
    if (!hPostReq) {
        LOG_ERROR("Failed to open POST request via WinINet");
        return TranslationResult::NETWORK_ERROR;
    }

    DWORD flags = SECURITY_FLAG_IGNORE_UNKNOWN_CA | SECURITY_FLAG_IGNORE_CERT_CN_INVALID | SECURITY_FLAG_IGNORE_CERT_DATE_INVALID;
    InternetSetOptionW(hPostReq, INTERNET_OPTION_SECURITY_FLAGS, &flags, sizeof(flags));

    // 【深度伪装】全面校准为 cn.bing.com 的请求特征
    wstring headers = L"Content-Type: application/x-www-form-urlencoded\r\n"
                      L"User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36\r\n"
                      L"Referer: https://cn.bing.com/translator\r\n";

    // 如果成功提取到了内部 Cookie，动态注入到 POST 请求头中
    if (!cookiesReceived.empty()) {
        wstring wCookies(cookiesReceived.begin(), cookiesReceived.end());
        headers += L"Cookie: " + wCookies + L"\r\n";
    }

    // 【优化方案 4】严格校准 POST 边界
    string postData = "text=" + UrlEncode(text) + "&fromLang=" + sl + "&to=" + tl;
    if (!token.empty() && !key.empty()) {
        postData += "&token=" + UrlEncode(token) + "&key=" + key;
    }

    LOG_DEBUG("POST " + path + " | Data Length: " + to_string(postData.length()));

    string response;
    BOOL res = HttpSendRequestW(hPostReq, headers.c_str(), (DWORD)-1, (LPVOID)postData.c_str(), (DWORD)postData.length());
    
    if (res) {
        DWORD statusCode = 0;
        DWORD statusLen  = sizeof(DWORD);
        HttpQueryInfoW(hPostReq, HTTP_QUERY_STATUS_CODE | HTTP_QUERY_FLAG_NUMBER, &statusCode, &statusLen, NULL);
            
        if (statusCode == 429) {
            LOG_WARNING("Rate limited by Bing (HTTP 429)");
            InternetCloseHandle(hPostReq);
            return TranslationResult::RATE_LIMITED;
        }

        char buffer[8192];
        DWORD bytesRead = 0;
        while (InternetReadFile(hPostReq, buffer, sizeof(buffer) - 1, &bytesRead) && bytesRead > 0) {
            response.append(buffer, bytesRead);
        }
    } else {
        LOG_ERROR("POST request failed: " + to_string(GetLastError()));
    }
    InternetCloseHandle(hPostReq);

    if (response.empty()) {
        LOG_ERROR("Empty response from Bing Free (Blocked by Firewall or Token Failed)");
        return TranslationResult::NETWORK_ERROR;
    }

    string translation = ParseBingResponse(response);

    if (translation.empty()) {
        LOG_ERROR("Failed to parse Bing Free response. Raw JSON: " + response.substr(0, 100));
        return TranslationResult::API_ERROR;
    }

    cache[cacheKey] = CacheEntry(translation);
    result = translation;
    LOG_DEBUG("Translated: " + text.substr(0, 30) + " -> " + translation.substr(0, 50));
    return TranslationResult::SUCCESS;
}

// Queue async translation request
bool TranslationClient::TranslateAsync(const string& requestId, const string& text,
                                       const string& sourceLang, const string& targetLang) {
    if (!initialized || !running) {
        return false;
    }

    lock_guard<mutex> lock(requestMutex);
    requestQueue.push(AsyncRequest(requestId, text, sourceLang, targetLang));
    LOG_DEBUG("Async request queued: " + requestId + " (" + sourceLang + " -> " + targetLang + ")");
    return true;
}

// Poll for completed translation
bool TranslationClient::PollResult(string& requestId, string& translation, string& error) {
    lock_guard<mutex> lock(resultMutex);

    if (resultQueue.empty()) {
        return false;
    }

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

// Worker thread for async translations
void TranslationClient::WorkerThreadFunc() {
    LOG_INFO("Worker thread started");

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
            LOG_DEBUG("Processing async request: " + request.requestId);

            string translation;
            string error;

            TranslationResult tr = TranslateText(request.text, translation,
                                                 request.sourceLang, request.targetLang);

            if (tr != TranslationResult::SUCCESS) {
                switch (tr) {
                    case TranslationResult::NETWORK_ERROR:  error = "network error"; break;
                    case TranslationResult::API_ERROR:      error = "API error";     break;
                    case TranslationResult::ENCODING_ERROR: error = "encoding error"; break;
                    case TranslationResult::TIMEOUT_ERROR:  error = "timeout";       break;
                    case TranslationResult::RATE_LIMITED:   error = "rate limited";  break;
                    default:                                error = "unknown error";  break;
                }
                translation = "";
            }

            {
                lock_guard<mutex> lock(resultMutex);
                resultQueue.push(AsyncResult(request.requestId, translation, error));
            }

            LOG_DEBUG("Async request completed: " + request.requestId);
        } else {
            Sleep(50);
        }
    }

    LOG_INFO("Worker thread stopped");
}

// 新增函数：动态获取当前 DLL 同级目录下的 wt_config.ini 绝对路径
string TranslationClient::GetConfigPath() {
    char dllPath[MAX_PATH] = {0};
    // 获取当前 DLL 的模块句柄并转换为路径
    GetModuleFileNameA(GetModuleHandleA("WoWTranslate.dll"), dllPath, MAX_PATH);
    string path(dllPath);
    size_t pos = path.find_last_of("\\/");
    if (pos != string::npos) {
        // 将 WoWTranslate.dll 替换为 wt_config.ini
        path = path.substr(0, pos + 1) + "wt_config.ini";
    } else {
        path = "wt_config.ini";
    }
    return path;
}

// 新增函数：从 INI 文件读取配置
void TranslationClient::LoadConfig() {
    string iniPath = GetConfigPath();
    char appBuf[256] = {0};
    char keyBuf[256] = {0};

    // 利用 Windows API 读取 [BaiduAPI] 节点下的配置
    GetPrivateProfileStringA("BaiduAPI", "AppID", "", appBuf, sizeof(appBuf), iniPath.c_str());
    GetPrivateProfileStringA("BaiduAPI", "SecretKey", "", keyBuf, sizeof(keyBuf), iniPath.c_str());

    m_appId = appBuf;
    m_secretKey = keyBuf;

    if (m_appId.empty() || m_secretKey.empty()) {
        LOG_WARNING("Baidu API Key is missing or incomplete in wt_config.ini");
    } else {
        LOG_INFO("Baidu API Key loaded successfully from INI");
    }
}

// 新增函数：将配置写入 INI 文件
void TranslationClient::SaveConfig(const string& appId, const string& secretKey) {
    string iniPath = GetConfigPath();
    
    // 利用 Windows API 写入配置
    WritePrivateProfileStringA("BaiduAPI", "AppID", appId.c_str(), iniPath.c_str());
    WritePrivateProfileStringA("BaiduAPI", "SecretKey", secretKey.c_str(), iniPath.c_str());

    // 写入成功后刷新当前内存中的值
    m_appId = appId;
    m_secretKey = secretKey;
    
    LOG_INFO("Baidu API Key updated and saved to INI");
}
