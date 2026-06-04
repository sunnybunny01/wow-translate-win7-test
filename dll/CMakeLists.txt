cmake_minimum_required(VERSION 3.20)
project(WoWTranslate VERSION 0.1.0)

# ==============================================================================
# 安全检查：魔兽 1.12.1 是纯 32 位程序，强制要求必须以 Win32 (x86) 架构配置编译
# ==============================================================================
if(CMAKE_SIZEOF_VOID_P EQUAL 8)
    message(FATAL_ERROR "错误：魔兽世界 1.12 客户端是 32 位程序，无法加载 64 位 DLL！请重新配置 CMake 为 Win32 (x86) 编译。例如使用命令: cmake -A Win32 ..")
endif()

# Set C++ standard
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Set output directory
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)
set(CMAKE_LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)

# Create the WoWTranslate DLL
add_library(WoWTranslate SHARED
    src/dllmain.cpp
    src/lua_interface.cpp
    src/translator_core.cpp
    src/logging.cpp
    src/utils.cpp
    src/WoWTranslate.def
)

# Include directories
target_include_directories(WoWTranslate PRIVATE
    include
    third_party
)

# MinHook library setup - Force 32-bit for WoW compatibility
set(MINHOOK_LIB "${CMAKE_CURRENT_SOURCE_DIR}/third_party/MinHook.x86.lib")

# Link libraries - 联动修改：新增 advapi32 以支持 Windows 原生加密 MD5 算法
target_link_libraries(WoWTranslate PRIVATE
    kernel32
    user32
    shell32
    wininet   # 用于百度翻译 API 的网络请求发送
    advapi32  # 核心新增：用于 utils.cpp 中的 Windows CryptoAPI (MD5计算)
)

# Add MinHook if available
if(EXISTS ${MINHOOK_LIB})
    target_link_libraries(WoWTranslate PRIVATE ${MINHOOK_LIB})
    message(STATUS "Using MinHook library: ${MINHOOK_LIB}")
    add_compile_definitions(MINHOOK_AVAILABLE)
else()
    message(WARNING "MinHook library not found: ${MINHOOK_LIB}")
    message(WARNING "Download from: https://github.com/TsudaKageyu/minhook/releases")
endif()

# Compiler-specific settings
if(MSVC)
    # Set static runtime library for release builds (/MT 和 /MTd)，确保生成的 DLL 彻底脱离 VS 运行库依赖，直接在 Win7 裸机运行
    set_property(TARGET WoWTranslate PROPERTY
        MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")

    # Additional MSVC settings
    target_compile_options(WoWTranslate PRIVATE
        /W4
        /permissive-
    )

    # Enable larger object files for complex translation logic
    target_compile_options(WoWTranslate PRIVATE /bigobj)
endif()

# Debug configurations
set_target_properties(WoWTranslate PROPERTIES
    DEBUG_POSTFIX "_d"
)

# Install rules
install(TARGETS WoWTranslate
    RUNTIME DESTINATION bin
    LIBRARY DESTINATION lib
)
