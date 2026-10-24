#!/usr/bin/env bash
# Build blinx_recomp.exe (Windows x86-64, SDL2 + Vulkan) with llvm-mingw, natively
# from Git Bash or cross from macOS/Linux (taken from Takedawn). Runs
# tools/win/fetch-deps.sh first when the deps are missing.
#
#   tools/win/build-mingw.sh [extra cmake -D options]
#
# Environment: BLINX_WINDEPS (deps prefix, default ../deps),
# XBOXRECOMP_DIR (toolkit checkout, default ../xboxrecomp), BUILD_DIR
# (default build/mingw), JOBS (default half the cores: each clang holds a
# whole generated chunk).
# Output: build/mingw/blinx_recomp.exe, and SDL2.dll beside it.
set -euo pipefail
# Ninja: the copy that ships with Visual Studio, when none is on PATH.
VS_NINJA="/c/Program Files/Microsoft Visual Studio/18/Enterprise/Common7/IDE/CommonExtensions/Microsoft/CMake/Ninja"
command -v ninja >/dev/null 2>&1 || { [ -x "$VS_NINJA/ninja.exe" ] && export PATH="$VS_NINJA:$PATH"; }
HERE="$(cd "$(dirname "$0")/../.." && pwd)"
D="${BLINX_WINDEPS:-$HERE/../deps}"
TK="${XBOXRECOMP_DIR:-$HERE/../xboxrecomp}"
[ -d "$TK" ] || { echo "toolkit checkout not found; set XBOXRECOMP_DIR" >&2; exit 1; }
[ -x "$D/llvm-mingw/bin/x86_64-w64-mingw32-clang" ] || "$HERE/tools/win/fetch-deps.sh"
B="${BUILD_DIR:-$HERE/build/mingw}"

# On a Windows host (Git Bash/MSYS) CMake is a native program: give it C:/...
# paths, which MSYS leaves alone, rather than /c/... ones it may not rewrite
# inside a ;-separated list.
wp() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

cmake -S "$(wp "$HERE")" -B "$(wp "$B")" -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_TOOLCHAIN_FILE="$(wp "$HERE/cmake/llvm-mingw-x86_64.cmake")" \
  -DLLVM_MINGW_ROOT="$(wp "$D/llvm-mingw")" \
  -DXBOXRECOMP_DIR="$(wp "$TK")" \
  -DBLINX_WIN_VULKAN=ON \
  -DCMAKE_PREFIX_PATH="$(wp "$D/SDL2/x86_64-w64-mingw32");$(wp "$D/glslang")" \
  -DVulkan_INCLUDE_DIR="$(wp "$D/vulkan/include")" \
  -DVulkan_LIBRARY="$(wp "$D/vulkan/lib/libvulkan-1.dll.a")" \
  "$@"
cmake --build "$B" --target blinx_recomp -j"${JOBS:-$(( $(nproc) / 2 ))}"
cp -f "$D/SDL2/x86_64-w64-mingw32/bin/SDL2.dll" "$B/"
ls -l "$B/blinx_recomp.exe"
