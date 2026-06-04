// utils.cpp - Utility functions for WoWTranslate (Baidu API Version)

#include <windows.h>
#include <wincrypt.h> // 需要引入此头文件以使用 Windows 原生 MD5
#include <string>
#include <vector>
#include <sstream>
#include <algorithm>
#include <iomanip>
#include <ctime>
#include <cctype>

#include "../include/utils.h"

using namespace std;

string GetCurrentTimestamp() {
    time_t now = time(0);
    tm timeinfo;
    localtime_s(&timeinfo, &now);

    ostringstream oss;
    oss << put_time(&timeinfo, "%Y-%m-%d %H:%M:%S");
    return oss.str();
}

string GetDllPath() {
    char path[MAX_PATH];
    HMODULE hModule = nullptr;

    // Get handle to this DLL
    if (GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                          GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                          (LPCSTR)&GetDllPath, &hModule) == 0) {
        return "";
    }

    // Get the full path
    if (GetModuleFileNameA(hModule, path, MAX_PATH) == 0) {
        return "";
    }

    return string(path);
}

vector<string> SplitString(const string& str, char delimiter) {
    vector<string> tokens;
    stringstream ss(str);
    string token;

    while (getline(ss, token, delimiter)) {
        tokens.push_back(token);
    }

    return tokens;
}

string TrimString(const string& str) {
    size_t start = str.find_first_not_of(" \t\n\r\f\v");
    if (start == string::npos) {
        return "";
    }

    size_t end = str.find_last_not_of(" \t\n\r\f\v");
    return str.substr(start, end - start + 1);
}

// --- 新增：百度翻译 API 核心支撑函数 ---

// 1. URL 编码 (UrlEncode)
string UrlEncode(const string& str) {
    ostringstream escaped;
    escaped.fill('0');
    escaped << hex;

    for (char c : str) {
        // 保留字母、数字及常见的 URL 安全字符
        if (isalnum((unsigned char)c) || c == '-' || c == '_' || c == '.' || c == '~') {
            escaped << c;
        } else {
            // 其他字符进行 %XX 编码 (百度 API 偏好大写十六进制)
            escaped << uppercase;
            escaped << '%' << setw(2) << int((unsigned char)c);
            escaped << nouppercase;
        }
    }
    return escaped.str();
}

// 2. MD5 散列算法 (利用 Windows 原生 CryptoAPI)
string CalculateMD5(const string& str) {
    HCRYPTPROV hProv = 0;
    HCRYPTHASH hHash = 0;
    string md5str = "";

    // 获取加密上下文
    if (CryptAcquireContext(&hProv, NULL, NULL, PROV_RSA_FULL, CRYPT_VERIFYCONTEXT)) {
        // 创建 MD5 哈希对象
        if (CryptCreateHash(hProv, CALG_MD5, 0, 0, &hHash)) {
            // 压入需要散列的数据
            if (CryptHashData(hHash, (const BYTE*)str.c_str(), str.length(), 0)) {
                DWORD cbHashSize = 16; // MD5 固定 16 字节
                BYTE rgbHash[16];
                
                // 获取哈希结果
                if (CryptGetHashParam(hHash, HP_HASHVAL, rgbHash, &cbHashSize, 0)) {
                    ostringstream oss;
                    oss << hex << setfill('0');
                    for (DWORD i = 0; i < cbHashSize; i++) {
                        // 转换成 32 位小写字符串
                        oss << setw(2) << (int)rgbHash[i];
                    }
                    md5str = oss.str();
                }
            }
            CryptDestroyHash(hHash);
        }
        CryptReleaseContext(hProv, 0);
    }
    return md5str;
}

// 3. 游戏客户端编码 (ANSI) 转 百度API编码 (UTF-8)
string AnsiToUtf8(const string& str) {
    if (str.empty()) return "";
    
    // Step 1: ANSI -> UTF-16
    int wlen = MultiByteToWideChar(CP_ACP, 0, str.data(), str.length(), NULL, 0);
    if (wlen == 0) return "";
    wstring wstr(wlen, 0);
    MultiByteToWideChar(CP_ACP, 0, str.data(), str.length(), &wstr[0], wlen);

    // Step 2: UTF-16 -> UTF-8
    int utf8len = WideCharToMultiByte(CP_UTF8, 0, wstr.data(), wstr.length(), NULL, 0, NULL, NULL);
    if (utf8len == 0) return "";
    string utf8str(utf8len, 0);
    WideCharToMultiByte(CP_UTF8, 0, wstr.data(), wstr.length(), &utf8str[0], utf8len, NULL, NULL);

    return utf8str;
}

// 4. 百度API编码 (UTF-8) 转 游戏客户端编码 (ANSI)
string Utf8ToAnsi(const string& str) {
    if (str.empty()) return "";
    
    // Step 1: UTF-8 -> UTF-16
    int wlen = MultiByteToWideChar(CP_UTF8, 0, str.data(), str.length(), NULL, 0);
    if (wlen == 0) return "";
    wstring wstr(wlen, 0);
    MultiByteToWideChar(CP_UTF8, 0, str.data(), str.length(), &wstr[0], wlen);

    // Step 2: UTF-16 -> ANSI
    int ansilen = WideCharToMultiByte(CP_ACP, 0, wstr.data(), wstr.length(), NULL, 0, NULL, NULL);
    if (ansilen == 0) return "";
    string ansistr(ansilen, 0);
    WideCharToMultiByte(CP_ACP, 0, wstr.data(), wstr.length(), &ansistr[0], ansilen, NULL, NULL);

    return ansistr;
}
// ----------------------------------------------

bool IsValidMemoryAddress(void* addr) {
    if (addr == nullptr) {
        return false;
    }

    MEMORY_BASIC_INFORMATION mbi;
    if (VirtualQuery(addr, &mbi, sizeof(mbi)) == 0) {
        return false;
    }

    return (mbi.State == MEM_COMMIT) &&
           (mbi.Protect & (PAGE_EXECUTE | PAGE_EXECUTE_READ | PAGE_EXECUTE_READWRITE |
                          PAGE_READONLY | PAGE_READWRITE));
}

void* SafeGetProcAddress(HMODULE hModule, const char* procName) {
    if (!hModule || !procName) {
        return nullptr;
    }

    __try {
        return GetProcAddress(hModule, procName);
    } __except(EXCEPTION_EXECUTE_HANDLER) {
        return nullptr;
    }
}
