#pragma once

#include <windows.h>
#include <string>
#include <vector>

// utils.h - Utility functions for WoWTranslate (Baidu API Version)
// Provides string manipulation, encoding, cryptography, and memory helpers

// Basic Utility functions
std::string GetCurrentTimestamp();
std::string GetDllPath();
std::vector<std::string> SplitString(const std::string& str, char delimiter);
std::string TrimString(const std::string& str);

// --- 新增：专门为百度翻译 API 扩展的工具函数 ---
// 1. URL 编码 (用于处理百度请求中的 q 参数)
std::string UrlEncode(const std::string& str);

// 2. MD5 散列算法 (用于生成百度 API 所需的 sign 签名)
std::string CalculateMD5(const std::string& str);

// 3. 编码转换 (WoW 1.12 客户端使用 GBK/ANSI，百度 API 强制要求 UTF-8)
std::string AnsiToUtf8(const std::string& str);
std::string Utf8ToAnsi(const std::string& str);
// ----------------------------------------------

// Memory utility functions
bool IsValidMemoryAddress(void* addr);
void* SafeGetProcAddress(HMODULE hModule, const char* procName);
