cmake_minimum_required(VERSION 3.25)

project(BasaltOpenXRRuntime VERSION 0.1.0 LANGUAGES C CXX)

if(NOT WIN32)
    message(FATAL_ERROR "The M3 runtime is a Windows PE DLL. Configure with cmake/toolchains/mingw-x86_64.cmake.")
endif()

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin")
set(CMAKE_LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin")
set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/lib")

include(FetchContent)

# Khronos OpenXR-SDK release-1.1.61, peeled commit 5267613edf3d937e3d77556a106a65c2f82b25c6.
# The hash makes dependency changes fail closed instead of silently changing the ABI.
FetchContent_Declare(
    openxr_sdk
    URL https://github.com/KhronosGroup/OpenXR-SDK/archive/5267613edf3d937e3d77556a106a65c2f82b25c6.tar.gz
    URL_HASH SHA256=c590035e04ebfbab9dce641039d222ccd3cf413c2be06d8a202b5bb6ffcb2872
    DOWNLOAD_EXTRACT_TIMESTAMP FALSE
)

set(BUILD_LOADER ON CACHE BOOL "" FORCE)
set(DYNAMIC_LOADER OFF CACHE BOOL "" FORCE)
set(BUILD_API_LAYERS OFF CACHE BOOL "" FORCE)
set(BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(BUILD_CONFORMANCE_TESTS OFF CACHE BOOL "" FORCE)
set(BUILD_ALL_EXTENSIONS OFF CACHE BOOL "" FORCE)
set(BUILD_WITH_SYSTEM_JSONCPP OFF CACHE BOOL "" FORCE)
set(INSTALL_TO_ARCHITECTURE_PREFIXES OFF CACHE BOOL "" FORCE)

FetchContent_MakeAvailable(openxr_sdk)

# OpenXR-SDK 1.1.61 uses this Windows partition macro in a preprocessor test.
# MinGW does not define it, while the SDK enables -Werror=undef.
if(MINGW)
    target_compile_definitions(openxr_loader PRIVATE WINAPI_PARTITION_SYSTEM=0)
endif()

add_subdirectory(pe)
add_subdirectory(tests)
