#!/usr/bin/env bash
#
# cpython3/mayhem/build.sh — build CPython with ASan+UBSan, then compile each
# OSS-Fuzz harness from Modules/_xxtestfuzz/ as a libFuzzer target AND a
# standalone reproducer; also build the KAT oracle for test.sh.
#
# Build contract ENV (from ghcr.io/mayhemheroes/base):
#   CC / CXX / SANITIZER_FLAGS / LIB_FUZZING_ENGINE / STANDALONE_FUZZ_MAIN / SRC
#
# CPython-specific notes:
#   - CPython uses --with-address-sanitizer / --with-undefined-behavior-sanitizer
#     configure flags instead of raw CFLAGS — the configure system bakes the
#     sanitizer correctly into libpython.
#   - -pthread in CFLAGS trips up configure (makes it think pthreads need no flags)
#     so we strip it, per the upstream OSS-Fuzz recipe.
#   - ASAN_OPTIONS=detect_leaks=0 is required during build: Python helper scripts
#     invoked by the Makefile run with ASan and leak-detection would abort them.
#   - We bake __asan_default_options() = "detect_leaks=0" into every fuzzer binary
#     so it also holds at Mayhem run time (where Mayhem owns ASAN_OPTIONS env).
#   - --enable-shared so fuzz binaries link against libpython.so (dynamic) — this
#     lets LD_PRELOAD work in verify-repo's sabotage/oracle check.
#   - DWARF < 4: thread $DEBUG_FLAGS (-g -gdwarf-3) through every compile so
#     Mayhem's triage can read crash stacks (§6.2 item 10).

set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Contract defaults (= not := so an explicit --build-arg SANITIZER_FLAGS= stays empty)
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer -g}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}"
: "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
export CC CXX DEBUG_FLAGS MAYHEM_JOBS LIB_FUZZING_ENGINE

SRC="${SRC:-/mayhem}"
cd "$SRC"

CPYTHON_PREFIX="$SRC/cpython_install"
FUZZ_DIR="$SRC/Modules/_xxtestfuzz"
OBJ_DIR="/tmp/cpython3_build"
mkdir -p "$OBJ_DIR" "$CPYTHON_PREFIX"

# ── ASAN options for the BUILD PHASE ────────────────────────────────────────
# Python Makefile invokes the build-time interpreter; disable leaks so ASan
# doesn't abort those transient processes mid-build.
export ASAN_OPTIONS="detect_leaks=0"
export UBSAN_OPTIONS="print_stacktrace=0"

# ── CFLAGS for configure ─────────────────────────────────────────────────────
# Do NOT pass SANITIZER_FLAGS to configure: CPython uses --with-*-sanitizer
# configure flags to bake ASan/UBSan correctly.  We DO add:
#   -fsanitize=fuzzer-no-link  → SanitizerCoverage in libpython.so (REQUIRED
#                                for libFuzzer to see any edges; without this
#                                `cov:` stays at 0 and libFuzzer warns
#                                "Is the code instrumented for coverage?")
#   -fno-sanitize-recover=all  → sanitizer violations halt (SPEC §6.1)
#   -fno-omit-frame-pointer    → readable crash stacks
#   $DEBUG_FLAGS               → DWARF-3 (§6.2 item 10)
#   -UNDEBUG                   → keep assert() enabled
#   -IInclude/internal/        → CPython internal headers used by fuzzer.c
#
# NOTE: --with-address-sanitizer / --with-undefined-behavior-sanitizer handle
# ASan/UBSan; they do NOT enable SanitizerCoverage.  Coverage instrumentation
# MUST be passed explicitly via CFLAGS so libpython.so objects carry
# __sanitizer_cov_* callbacks that libFuzzer requires for edge counting.
#
# -pthread is stripped: configure tests for pthreads availability; if it's
# already in CFLAGS the check always succeeds and configure omits -lpthread
# from LDFLAGS, breaking the link.
CONF_CFLAGS="-fsanitize=fuzzer-no-link -fno-sanitize-recover=all -fno-omit-frame-pointer $DEBUG_FLAGS -UNDEBUG"
CONF_CFLAGS="$(echo "$CONF_CFLAGS" | sed 's/-pthread//g')"
export CONF_CFLAGS

# ── Step 1: configure + build CPython ───────────────────────────────────────
# Guard: skip configure if the Makefile is already present (idempotent re-run).
if [ ! -f Makefile ]; then
  ./configure \
    --with-address-sanitizer \
    --with-undefined-behavior-sanitizer \
    --enable-shared \
    --prefix "$CPYTHON_PREFIX" \
    CFLAGS="$CONF_CFLAGS" \
    CC="$CC" CXX="$CXX"
fi

make -j"$MAYHEM_JOBS" altinstall

# ── Locate python-config ─────────────────────────────────────────────────────
PYTHON_CONFIG="$(ls "$CPYTHON_PREFIX/bin/python3"*"-config" 2>/dev/null | head -1)"
if [ -z "$PYTHON_CONFIG" ]; then
  echo "ERROR: python-config not found in $CPYTHON_PREFIX/bin/" >&2; exit 1
fi
echo "python-config: $PYTHON_CONFIG"

# python-config output for harness compilation/linking
PY_CFLAGS="$($PYTHON_CONFIG --cflags)"
PY_LDFLAGS="$($PYTHON_CONFIG --ldflags --embed)"
# Strip -pthread from python-config output as well
PY_CFLAGS="$(echo "$PY_CFLAGS" | sed 's/-pthread//g')"

# Shared library path (rpath so binaries self-locate libpython.so)
LIB_PATH="$CPYTHON_PREFIX/lib"
RPATH_FLAG="-Wl,-rpath,$LIB_PATH"
export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:+$LD_LIBRARY_PATH:}$LIB_PATH"

# ── Step 2: Build standalone driver (run-once, no libFuzzer runtime) ─────────
STANDALONE_OBJ="$OBJ_DIR/standalone_main.o"
if [ -n "${STANDALONE_FUZZ_MAIN:-}" ] && [ -f "$STANDALONE_FUZZ_MAIN" ]; then
  case "$STANDALONE_FUZZ_MAIN" in
    *.c)
      $CC $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$STANDALONE_OBJ"
      ;;
    *.a|*.o)
      cp "$STANDALONE_FUZZ_MAIN" "$STANDALONE_OBJ"
      ;;
  esac
else
  # Fallback: minimal run-once driver
  cat > "$OBJ_DIR/standalone_main.c" << 'CEOF'
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size);
int main(int argc, char *argv[]) {
    for (int i = 1; i < argc; i++) {
        FILE *f = fopen(argv[i], "rb");
        if (!f) { perror(argv[i]); return 1; }
        fseek(f, 0, SEEK_END); long l = ftell(f); fseek(f, 0, SEEK_SET);
        if (l < 0) { fclose(f); continue; }
        uint8_t *b = (uint8_t*)malloc((size_t)(l < 0 ? 0 : l) + 1);
        if (!b) { fclose(f); return 1; }
        if (l > 0 && fread(b, 1, (size_t)l, f) != (size_t)l) { free(b); fclose(f); return 1; }
        fclose(f);
        LLVMFuzzerTestOneInput(b, (size_t)(l < 0 ? 0 : l));
        free(b);
    }
    return 0;
}
CEOF
  $CC $DEBUG_FLAGS -c "$OBJ_DIR/standalone_main.c" -o "$STANDALONE_OBJ"
fi

# ── Step 3: ASan default options object (bakes detect_leaks=0 into binaries) ─
# Mayhem owns ASAN_OPTIONS at run time; we CAN'T set it in the Mayhemfile.
# Baking __asan_default_options() is the approved way to set detect_leaks=0
# without conflicting with Mayhem's abort_on_error=1 / symbolize=0 settings.
cat > "$OBJ_DIR/asan_opts.c" << 'CEOF'
const char *__asan_default_options(void) { return "detect_leaks=0"; }
CEOF
$CC $DEBUG_FLAGS -c "$OBJ_DIR/asan_opts.c" -o "$OBJ_DIR/asan_opts.o"

# ── Step 4: Build each fuzz harness (libFuzzer target + standalone) ───────────
while IFS= read -r fuzz_test; do
  [ -z "$fuzz_test" ] && continue
  echo "--- building $fuzz_test ---"

  OBJ="$OBJ_DIR/${fuzz_test}.o"

  # Compile fuzzer.c (C code) with CPython internal includes + DWARF-3
  # Note: compile includes from CPython prefix AND from the source tree
  $CC $CONF_CFLAGS $PY_CFLAGS \
    -I"$SRC/Include" -I"$SRC/Include/internal" \
    "$FUZZ_DIR/fuzzer.c" \
    -D _Py_FUZZ_ONE "-D _Py_FUZZ_${fuzz_test}" \
    -c -Wno-unused-function \
    -o "$OBJ"

  # LibFuzzer target → /mayhem/<name>
  # $SANITIZER_FLAGS MUST be in the link step: libpython.so was built with
  # --with-address-sanitizer, so it references ASan runtime symbols (__asan_*).
  # Without -fsanitize=address in the link command the linker can't resolve them.
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS -rdynamic "$OBJ" "$OBJ_DIR/asan_opts.o" \
    -o "/mayhem/${fuzz_test}" \
    $LIB_FUZZING_ENGINE \
    $PY_LDFLAGS \
    $RPATH_FLAG

  # Standalone reproducer → /mayhem/<name>-standalone
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS -rdynamic "$OBJ" "$OBJ_DIR/standalone_main.o" "$OBJ_DIR/asan_opts.o" \
    -o "/mayhem/${fuzz_test}-standalone" \
    $PY_LDFLAGS \
    $RPATH_FLAG

  echo "  built $fuzz_test (+ standalone)"
done < "$FUZZ_DIR/fuzz_tests.txt"

# ── Step 5: Build the KAT oracle for test.sh ─────────────────────────────────
# SANITIZER_FLAGS in the link step: same reason as harnesses — libpython.so has
# ASan baked in and its __asan_* symbols must be resolved by the ASan runtime.
echo "--- building cpython3-test (KAT oracle) ---"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS $PY_CFLAGS -UNDEBUG \
  -I"$SRC/Include" -I"$SRC/Include/internal" \
  "$SRC/mayhem/harnesses/cpython3-test.c" \
  "$OBJ_DIR/asan_opts.o" \
  -o "/mayhem/cpython3-test" \
  $PY_LDFLAGS \
  $RPATH_FLAG

echo "build.sh complete."
ls -la /mayhem/fuzz_* /mayhem/cpython3-test 2>&1 | head -40
