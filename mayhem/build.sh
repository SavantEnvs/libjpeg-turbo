#!/usr/bin/env bash
#
# mayhem/build.sh — build libjpeg-turbo's upstream fuzz targets (fuzz/*.cc, the OSS-Fuzz set) plus the
# project's own regression suite. Runs in the commit image as `mayhem` in /mayhem; re-runnable and
# air-gapped (everything comes from the tree and from apt packages baked into the image).
#   fuzz binaries        -> /mayhem/mayhem/bin/<name>_fuzzer   (libFuzzer, sanitized project)
#   standalone repro     -> /mayhem/mayhem/bin/<name>_fuzzer-standalone
#   test suite (normal)  -> /mayhem/mayhem/_build/tests        (run by mayhem/test.sh via ctest)
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"
B="$SRC/mayhem/_build"
BIN="$SRC/mayhem/bin"
mkdir -p "$B" "$BIN"

TARGETS="cjpeg compress compress_yuv compress_lossless compress12 compress12_lossless compress16_lossless libjpeg_turbo decompress_libjpeg decompress_yuv transform"

# Objects linked into every fuzz and standalone binary: LeakSanitizer off, and the run-once driver
# (compiled as C so clang++ does not mangle its LLVMFuzzerTestOneInput reference).
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$B/lsan_off.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -x c -c "$STANDALONE_FUZZ_MAIN" -o "$B/standalone_main.o"

# 1) Sanitized + SanCov-instrumented project with the upstream fuzz targets linked to libFuzzer.
#    The library itself needs -fsanitize=fuzzer-no-link or Mayhem records 0 edges.
cmake -S . -B "$B/fuzz" -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_C_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link" \
  -DCMAKE_CXX_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link" \
  -DCMAKE_C_FLAGS_RELWITHDEBINFO="-O2 -DNDEBUG" -DCMAKE_CXX_FLAGS_RELWITHDEBINFO="-O2 -DNDEBUG" \
  -DENABLE_STATIC=1 -DENABLE_SHARED=0 -DWITH_JAVA=0 -DWITH_TESTS=0 \
  -DWITH_FUZZ=1 -DFUZZ_BINDIR="$B/fuzz/out" \
  -DFUZZ_LIBRARY="$B/lsan_off.o;$LIB_FUZZING_ENGINE"
cmake --build "$B/fuzz" -j"$MAYHEM_JOBS"
for t in $TARGETS; do cp "$B/fuzz/fuzz/${t}_fuzzer" "$BIN/${t}_fuzzer"; done

# 2) Same project, uninstrumented for coverage, with the harnesses linked to the run-once driver.
cmake -S . -B "$B/standalone" -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_C_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" \
  -DCMAKE_CXX_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" \
  -DCMAKE_C_FLAGS_RELWITHDEBINFO="-O2 -DNDEBUG" -DCMAKE_CXX_FLAGS_RELWITHDEBINFO="-O2 -DNDEBUG" \
  -DENABLE_STATIC=1 -DENABLE_SHARED=0 -DWITH_JAVA=0 -DWITH_TESTS=0 \
  -DWITH_FUZZ=1 -DFUZZ_BINDIR="$B/standalone/out" \
  -DFUZZ_LIBRARY="$B/lsan_off.o;$B/standalone_main.o"
cmake --build "$B/standalone" -j"$MAYHEM_JOBS"
for t in $TARGETS; do cp "$B/standalone/fuzz/${t}_fuzzer" "$BIN/${t}_fuzzer-standalone"; done

# 3) The project's regression suite, built with its NORMAL flags (no sanitizers, no -gdwarf-3).
cmake -S . -B "$B/tests" -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS" \
  -DENABLE_SHARED=0 -DWITH_JAVA=0 -DWITH_TESTS=1
cmake --build "$B/tests" -j"$MAYHEM_JOBS"
