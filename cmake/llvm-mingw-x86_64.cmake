# From apexJCL/xboxrecomp-cli @ 04d491f,
# src/xboxrecomp_cli/cmake/llvm-mingw-x86_64.cmake (unchanged below).
# Pinned toolchain: llvm-mingw 20260922 (blinx2-recomp config/setup-pins.json),
# macOS host asset llvm-mingw-20260922-ucrt-macos-universal.tar.xz,
# sha256 52e5f5a7b131021d0c39a37a38fa380a1da7885cd04bd61afd0cd4ecfb8bc1f3.
#
# Cross-compile the game for Windows x86-64 (run under Proton/Wine or on
# Windows) with llvm-mingw: clang + lld + mingw-w64 headers, UCRT runtime.
#
# Why llvm-mingw and not GCC MinGW: GCC on mingw implements __thread through
# emutls, a function call per access, and the RECOMP_TLS guest registers are
# touched by nearly every lifted instruction. Clang uses native TLS.
#
# Locating the toolchain, first match wins:
#   -DLLVM_MINGW_ROOT=<dir>  or  env LLVM_MINGW_ROOT=<dir>   (<dir>/bin/x86_64-w64-mingw32-clang)
#   x86_64-w64-mingw32-clang on PATH
#
#   cmake -S . -B build-mingw -DCMAKE_TOOLCHAIN_FILE=cmake/llvm-mingw-x86_64.cmake
#   cmake --build build-mingw -j N

set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_PROCESSOR x86_64)

set(_triple x86_64-w64-mingw32)

if(NOT LLVM_MINGW_ROOT AND DEFINED ENV{LLVM_MINGW_ROOT})
    set(LLVM_MINGW_ROOT "$ENV{LLVM_MINGW_ROOT}")
endif()
set(LLVM_MINGW_ROOT "${LLVM_MINGW_ROOT}" CACHE PATH "llvm-mingw install root (empty: search PATH)")
# try_compile projects re-read this file; pass the root down to them.
list(APPEND CMAKE_TRY_COMPILE_PLATFORM_VARIABLES LLVM_MINGW_ROOT)

if(LLVM_MINGW_ROOT)
    set(_hints HINTS "${LLVM_MINGW_ROOT}/bin" NO_DEFAULT_PATH)
endif()
find_program(_mingw_cc  ${_triple}-clang   ${_hints} REQUIRED)
find_program(_mingw_cxx ${_triple}-clang++ ${_hints} REQUIRED)
find_program(_mingw_rc  ${_triple}-windres ${_hints})

set(CMAKE_C_COMPILER   "${_mingw_cc}")
set(CMAKE_CXX_COMPILER "${_mingw_cxx}")
if(_mingw_rc)
    set(CMAKE_RC_COMPILER "${_mingw_rc}")
endif()

get_filename_component(_bin "${_mingw_cc}" DIRECTORY)
set(CMAKE_FIND_ROOT_PATH "${_bin}/../${_triple}")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)

# Dependency prefixes (SDL2, glslang: tools/win/fetch-deps.sh) named in
# CMAKE_PREFIX_PATH stay findable under the ONLY modes above.
list(APPEND CMAKE_FIND_ROOT_PATH ${CMAKE_PREFIX_PATH})
