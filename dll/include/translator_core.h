#pragma once

#include <windows.h>
#include <wininet.h>
#include <string>
#include <unordered_map>
#include <memory>
#include <queue>
#include <mutex>
#include <thread>
#include <atomic>

enum class TranslationResult {
    SUCCESS = 0,
    NETWORK_ERROR = 1,
    API_ERROR = 2,
    ENCODING_ERROR = 3,
    TIMEOUT_ERROR = 4,
    INVALID_PARAMS = 5,
    PENDING = 6,
    RATE_LIMITED = 7
};

struct AsyncRequest {
    std::string requestId;
    std::string text;
    std::string sourceLang;
    std::string targetLang;
    DWORD timestamp;

    AsyncRequest() : sourceLang("zh"), targetLang("en"), timestamp(0) {}
    AsyncRequest(const std::string& id, const std::string& t,
                 const std::string& src = "zh", const std::string& tgt = "en")
        : requestId(id), text(t), sourceLang(src), targetLang(tgt),
          timestamp(GetTickCount()) {}
};

struct AsyncResult {
    std::string requestId;
    std::string translation;
    std::string error;
    bool ready;

    AsyncResult() : ready(false) {}
    AsyncResult(const std::string& id, const std::string& trans,
                const std::string& err)
        : requestId(id), translation(trans), error(err), ready(true) {}
};

struct CacheEntry {
    std::string translation;
    DWORD timestamp;

    CacheEntry() : translation(""), timestamp(0) {}
    CacheEntry(const std::string& trans)
        : translation(trans), timestamp(GetTickCount()) {}
};

class TranslationClient {
private:
    // 新增：成员变量，存储从 INI 读取的密钥
    std::string m_appId;
    std::string m_secretKey;

    // 新增：内部获取 INI 绝对路径和加载配置的函数
    std::string GetConfigPath();
    void LoadConfig();

    HINTERNET hSession;
    HINTERNET hConnect;
    std::unordered_map<std::string, CacheEntry> cache;
    bool initialized;

    std::queue<AsyncRequest> requestQueue;
    std::queue<AsyncResult> resultQueue;
    std::mutex requestMutex;
    std::mutex resultMutex;
    std::thread workerThread;
    std::atomic<bool> running;

    static const DWORD CACHE_EXPIRY_MS = 3600000;
    static const size_t MAX_CACHE_SIZE = 500;

    std::string UrlEncode(const std::string& text);
    // Changed from HttpsGet to HttpsPost to support Bing Translate API
    std::string HttpsPost(const std::string& path, const std::string& postData);
    std::string MapLangCode(const std::string& lang);
    // Changed from ParseGoogleFreeResponse to ParseBingResponse
    std::string ParseBingResponse(const std::string& json);
    std::string GenerateCacheKey(const std::string& text,
                                 const std::string& sourceLang,
                                 const std::string& targetLang);
    void CleanExpiredCache();
    void WorkerThreadFunc();

public:
    // 新增：允许外部（如 Lua 接口）调用保存配置
    void SaveConfig(const std::string& appId, const std::string& secretKey);
    
    // 新增：获取当前的配置（供后面翻译引擎使用）
    std::string GetAppID() const { return m_appId; }
    std::string GetSecretKey() const { return m_secretKey; }

    TranslationClient();
    ~TranslationClient();

    bool Initialize();
    void Cleanup();
    bool IsInitialized() const { return initialized; }

    TranslationResult TranslateText(const std::string& text, std::string& result,
                                    const std::string& sourceLang = "zh",
                                    const std::string& targetLang = "en");

    bool TranslateAsync(const std::string& requestId, const std::string& text,
                        const std::string& sourceLang = "zh",
                        const std::string& targetLang = "en");
    bool PollResult(std::string& requestId, std::string& translation,
                    std::string& error);
    size_t GetPendingCount();
};

extern std::unique_ptr<TranslationClient> g_translator;
extern char g_translation_buffer[4096];
extern char g_error_buffer[256];
