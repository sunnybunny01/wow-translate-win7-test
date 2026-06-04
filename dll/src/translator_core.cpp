// translator_core.cpp - Translation functionality for WoWTranslate
// Sends POST requests to cn.bing.com — Microsoft Bing Free Translation

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

using namespace std;

// UTF-8 codepoint encoder (file-scope for use in multiple places)
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

    // Changed to Bing's China-friendly endpoint
    const std::string host = "cn.bing.com";
    const int port = 443;

    LOG_INFO("Initializing Microsoft Bing Free translation client (WinINet mode)");

    hSession = InternetOpenW(L"WoWTranslate/0.14",
                             INTERNET_OPEN_TYPE_PRECONFIG,
                             NULL,
                             NULL,
                             0);
    if (!hSession) {
        LOG_ERROR("Failed to initialize WinINet session");
        return false;
    }

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

// Map Google Lang Codes to Microsoft Bing Lang Codes
string TranslationClient::MapLangCode(const string& lang) {
    if (lang == "zh" || lang == "zh-CN") return "zh-Hans"; // Simplified Chinese
    if (lang == "zh-TW") return "zh-Hant"; // Traditional Chinese
    return lang;
}

// Changed to POST for Bing Translate API
string TranslationClient::HttpsPost(const string& path, const string& postData) {
    if (!hConnect) return "";

    wstring wPath(path.begin(), path.end());

    HINTERNET hRequest = HttpOpenRequestW(
        hConnect, L"POST", wPath.c_str(), nullptr,
        nullptr, nullptr,
        INTERNET_FLAG_SECURE | INTERNET_FLAG_RELOAD, 0);

    if (!hRequest) {
        LOG_ERROR("Failed to open POST request via WinINet");
        return "";
    }

    // Bing requires a valid User-Agent and proper Content-Type for POST body
    wstring headers = L"Content-Type: application/x-www-form-urlencoded\r\n"
                      L"User-Agent: Mozilla/5.0 (Windows NT 6.1; Win64; x64) AppleWebKit/537.36\r\n";
    
    BOOL result = HttpSendRequestW(hRequest, headers.c_str(), (DWORD)-1, 
                                   (LPVOID)postData.c_str(), (DWORD)postData.length());

    string response;
    if (result) {
        DWORD statusCode = 0;
        DWORD statusLen  = sizeof(DWORD);
        HttpQueryInfoW(hRequest,
            HTTP_QUERY_STATUS_CODE | HTTP_QUERY_FLAG_NUMBER,
            &statusCode, &statusLen, NULL);
            
        if (statusCode == 429) {
            LOG_WARNING("Rate limited by Bing (HTTP 429)");
            InternetCloseHandle(hRequest);
            return "HTTP_429";
        }

        char buffer[8192];
        DWORD bytesRead = 0;
        while (InternetReadFile(hRequest, buffer, sizeof(buffer) - 1, &bytesRead) && bytesRead > 0) {
            response.append(buffer, bytesRead);
        }
    } else {
        LOG_ERROR("POST request failed: " + to_string(GetLastError()));
    }

    InternetCloseHandle(hRequest);
    return response;
}

// New JSON Parser specifically for Bing's response
string TranslationClient::ParseBingResponse(const string& json) {
    // Bing format: [{"detectedLanguage":{...},"translations":[{"text":"translated_result","to":"zh-Hans"}]}]
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
    
    // Bing POST path
    string path = "/ttranslatev3?isVertical=1";
    // Bing POST data body
    string postData = "&text=" + UrlEncode(text) + "&fromLang=" + sl + "&to=" + tl;

    LOG_DEBUG("POST " + path + " | Data: " + postData.substr(0, 100));

    string response = HttpsPost(path, postData);

    if (response == "HTTP_429") {
        return TranslationResult::RATE_LIMITED;
    }

    if (response.empty()) {
        LOG_ERROR("Empty response from Bing Free");
        return TranslationResult::NETWORK_ERROR;
    }

    string translation = ParseBingResponse(response);

    if (translation.empty()) {
        LOG_ERROR("Failed to parse Bing Free response");
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
