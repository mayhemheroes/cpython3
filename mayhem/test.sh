#!/usr/bin/env bash
#
# cpython3/mayhem/test.sh — functional KAT oracle for the CPython integration.
#
# Runs the pre-built cpython3-test binary (built by mayhem/build.sh against the
# installed libpython3.X.so). The binary calls Python's json and struct modules
# via the C API and verifies known-answer results.
#
# PATCH-grade oracle: the test binary is dynamically linked against libpython.so,
# so verify-repo's sabotage check (LD_PRELOAD exit(0)) neuters it — the process
# returns without printing "KAT_PASS", and this script detects the failure.
# An exit(0) no-op PATCH to CPython cannot pass this test.
#
# This script only RUNS the pre-built binary; it never compiles. If the binary
# is missing (build.sh didn't run), it fails loudly.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

SRC="${SRC:-/mayhem}"
cd "$SRC"

KAT_BIN="/mayhem/cpython3-test"

# emit_ctrf <tool> <passed> <failed> [skipped]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}"
  local tests=$(( passed + failed + skipped ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" << JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": 0,
      "skipped": $skipped,
      "other": 0
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":0,"skipped":%d,"other":0}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$skipped"
  [ "$failed" -eq 0 ]
}

# Guard: fail loudly if the oracle binary is missing (build.sh didn't run)
if [ ! -x "$KAT_BIN" ]; then
  echo "ERROR: $KAT_BIN not found — run mayhem/build.sh first" >&2
  emit_ctrf "cpython3-kat" 0 1
  exit 1
fi

# Ensure libpython.so is discoverable at runtime
CPYTHON_LIBDIR="$SRC/cpython_install/lib"
if [ -d "$CPYTHON_LIBDIR" ]; then
  export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:+$LD_LIBRARY_PATH:}$CPYTHON_LIBDIR"
fi

echo "=== running cpython3 KAT oracle ==="
rc=0
OUTPUT="$("$KAT_BIN" 2>&1)" || rc=$?
echo "$OUTPUT"

# Check for the known-answer pass marker
PASSED=0; FAILED=0
if echo "$OUTPUT" | grep -q "^KAT_PASS:"; then
  echo "KAT: PASS — oracle output verified"
  PASSED=1
else
  echo "KAT: FAIL — expected 'KAT_PASS:' in output, got: $OUTPUT" >&2
  FAILED=1
fi

# Also fail if the binary returned non-zero
if [ "$rc" -ne 0 ] && [ "$PASSED" -eq 1 ]; then
  echo "KAT: FAIL — binary exited $rc despite printing KAT_PASS (unexpected)" >&2
  PASSED=0; FAILED=1
fi

emit_ctrf "cpython3-kat" "$PASSED" "$FAILED"
