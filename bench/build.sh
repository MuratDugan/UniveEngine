#!/bin/bash
# Builds the bench programs into bench/out: Windows x86_64 (mingw, static) and native macOS (arm64 + x86_64).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
src="$here/src"; out="$here/out"
mkdir -p "$out/win" "$out/mac"
CC="${MINGW_CC:-x86_64-w64-mingw32-gcc}"
command -v "$CC" >/dev/null || { echo "missing $CC: brew install mingw-w64" >&2; exit 1; }
WFLAGS=(-O2 -static -s -Wall -Wno-unused-function)
"$CC" "${WFLAGS[@]}" -o "$out/win/cpu.exe"   "$src/cpu.c"
"$CC" "${WFLAGS[@]}" -o "$out/win/files.exe" "$src/files.c"
"$CC" "${WFLAGS[@]}" -mwindows -mconsole -o "$out/win/d3d11.exe" "$src/d3d11.c" -ld3d11 -ldxgi -luuid
"$CC" "${WFLAGS[@]}" -mwindows -mconsole -o "$out/win/d3d9.exe"  "$src/d3d9.c"  -ld3d9 -luuid
MFLAGS=(-O2 -Wall -Wno-unused-function)
clang "${MFLAGS[@]}" -arch arm64 -o "$out/mac/cpu-arm64"  "$src/cpu.c"
clang "${MFLAGS[@]}" -arch x86_64 -march=x86-64 -o "$out/mac/cpu-x86_64" "$src/cpu.c"
clang "${MFLAGS[@]}" -arch arm64 -o "$out/mac/files-arm64" "$src/files.c"
echo "built: $(ls "$out/win" "$out/mac" | tr '\n' ' ')"
