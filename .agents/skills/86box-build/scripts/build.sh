#!/usr/bin/env bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

usage() {
  cat <<EOF
Usage: $0 [mode] [options]

Incremental build by default; optional full clean configure for 86Box.

Modes:
  --qt                  Qt build in build/ (default)
  --sdl-gl              SDL OSD build with shaders in build/unix-osd-build
  --sdl-sw              SDL OSD build without shaders in build/unix-osd-noshader-build
  --unix-osd            Alias for --sdl-gl
  --unix-osd-gl         Alias for --sdl-gl
  --unix-osd-sw         Alias for --sdl-sw

Options:
  --clean               Full reconfigure + compile
  --clang               Use Clang + ThinLTO (Qt build only)
  --target <ninja>      Focused incremental target build
  --build-dir <dir>     Use an alternate build directory
  --clean [cmake args]  Pass extra CMake args during a clean configure
EOF
}

GCC_LIB=$(dirname "$(gcc -print-file-name=libstdc++.so)")

# Ensure NIX_CFLAGS_COMPILE is populated (both gcc and clang wrappers need it).
# After container restart / in fresh terminals it can be empty.
if [[ -z "${NIX_CFLAGS_COMPILE_x86_64_unknown_linux_gnu:-}" && -n "${CMAKE_PREFIX_PATH:-}" ]]; then
  NIX_INC=""
  for p in $(echo "$CMAKE_PREFIX_PATH" | tr ':' '\n'); do
    [[ -d "$p/include" ]] && NIX_INC="$NIX_INC -isystem $p/include"
  done
  export NIX_CFLAGS_COMPILE_x86_64_unknown_linux_gnu="$NIX_INC"
fi

build_mode=qt
build_dir=
build_dir_override=0
do_clean_configure=0
use_clang=0
user_cmake_args=()
mode_cmake_args=()
ninja_targets=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --clean)
      do_clean_configure=1
      ;;
    --clang)
      use_clang=1
      ;;
    --qt)
      build_mode=qt
      ;;
    --sdl|--sdl-gl|--unix-osd)
      build_mode=sdl-gl
      ;;
    --unix-osd-gl)
      build_mode=sdl-gl
      ;;
    --sdl-sw|--sdl-software|--unix-osd-sw|--unix-osd-software)
      build_mode=sdl-sw
      ;;
    --build-dir)
      shift
      if [[ $# -eq 0 ]]; then
        echo "ERROR: --build-dir requires a path" >&2
        exit 1
      fi
      build_dir="$1"
      build_dir_override=1
      ;;
    --target)
      shift
      if [[ $# -eq 0 ]]; then
        echo "ERROR: --target requires a ninja target" >&2
        exit 1
      fi
      ninja_targets+=("$1")
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      user_cmake_args+=("$1")
      ;;
  esac
  shift
done

if [[ "$build_mode" != qt && $use_clang -eq 1 ]]; then
  echo "ERROR: Clang builds are only wired for the Qt build right now" >&2
  exit 1
fi

if [[ $build_dir_override -eq 0 ]]; then
  case "$build_mode" in
    qt)
      build_dir=build
      ;;
    sdl-gl)
      build_dir=build/unix-osd-build
      ;;
    sdl-sw)
      build_dir=build/unix-osd-noshader-build
      ;;
    *)
      echo "ERROR: unsupported build mode: $build_mode" >&2
      exit 1
      ;;
  esac
fi

case "$build_mode" in
  qt)
    mode_cmake_args+=("-DQT=ON" "-DUSE_QT6=ON" "-DUSE_SDL_SHADER=ON" "-DAUTOMATION=ON")
    ;;
  sdl-gl)
    mode_cmake_args+=("-DQT=OFF" "-DUSE_SDL_SHADER=ON" "-DAUTOMATION=ON")
    ;;
  sdl-sw)
    mode_cmake_args+=("-DQT=OFF" "-DUSE_SDL_SHADER=OFF" "-DAUTOMATION=ON")
    ;;
  *)
    echo "ERROR: unsupported build mode: $build_mode" >&2
    exit 1
    ;;
esac

if [[ "$build_dir" = /* ]]; then
  BUILDDIR="$build_dir"
else
  BUILDDIR="$REPO_ROOT/$build_dir"
fi

mkdir -p "$BUILDDIR"

if [[ ${#user_cmake_args[@]} -gt 0 && $do_clean_configure -eq 0 ]]; then
  echo "ERROR: extra CMake arguments require --clean" >&2
  exit 1
fi

if [[ $do_clean_configure -eq 1 || ! -f "$BUILDDIR/CMakeCache.txt" ]]; then
  rm -f "$BUILDDIR/CMakeCache.txt"

  #COMMON_CFLAGS="-march=znver4 -mtune=znver4 -O2 -DNDEBUG -ffp-contract=fast"
  COMMON_CFLAGS="-march=znver4 -mtune=znver4 -ffp-contract=fast"
  cmake_args=(
    -G Ninja
    -DCMAKE_BUILD_TYPE=Optimized
    -DNEW_DYNAREC=ON
    -S "$REPO_ROOT"
    -B "$BUILDDIR"
    "${mode_cmake_args[@]}"
    "${user_cmake_args[@]}"
  )

  if [[ $use_clang -eq 1 ]]; then
    echo "=== Configuring with Clang + ThinLTO ==="
    cmake_args+=(
      -DCMAKE_C_COMPILER=clang
      -DCMAKE_CXX_COMPILER=clang++
      -DCMAKE_C_FLAGS_OPTIMIZED="$COMMON_CFLAGS -flto=thin"
      -DCMAKE_CXX_FLAGS_OPTIMIZED="$COMMON_CFLAGS -flto=thin"
      "-DCMAKE_EXE_LINKER_FLAGS=-fuse-ld=lld -flto=thin -Wl,-rpath,$GCC_LIB"
    )
  else
    echo "=== Configuring with GCC + LTO ==="
    cmake_args+=(
      -DCMAKE_C_COMPILER=gcc
      -DCMAKE_CXX_COMPILER=g++
      -DCMAKE_C_FLAGS_OPTIMIZED="$COMMON_CFLAGS -O2 -g -flto=auto -ffat-lto-objects"
      -DCMAKE_CXX_FLAGS_OPTIMIZED="$COMMON_CFLAGS -O2 -g -DNDEBUG"
      "-DCMAKE_EXE_LINKER_FLAGS=-g -flto=auto -Wl,-O2,--as-needed,-rpath,$GCC_LIB"
    )
  fi

  cmake "${cmake_args[@]}"
fi

ninja -C "$BUILDDIR" -j16 "${ninja_targets[@]}"
echo "=== Built: $BUILDDIR/src/86Box ==="
if [[ ${#ninja_targets[@]} -eq 0 ]]; then
  ls -lh "$BUILDDIR/src/86Box"
fi
