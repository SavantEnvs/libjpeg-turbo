#!/usr/bin/env bash
#
# mayhem/test.sh — RUN libjpeg-turbo's own regression suite (built by mayhem/build.sh).
# The ctest suite compresses/decompresses/transforms the bundled test images with every option
# combination and compares MD5 sums of the output against known-good values, so a program that is
# neutered to a no-op fails it; the MD5 expectations are additionally re-verified with md5sum.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"
: "${SRC:=/mayhem}"
cd "$SRC"

emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

BT="$SRC/mayhem/_build/tests"
[ -f "$BT/CTestTestfile.cmake" ] || { echo "test build missing: run mayhem/build.sh first" >&2; emit_ctrf cmake-ctest 0 1 0; exit 1; }

# The ctest md5cmp steps are project binaries that only signal pass/fail through their exit status.
# Re-check every expected MD5 independently with the system md5sum, after deleting the files first so a
# stale output (or a program that does nothing) cannot satisfy it.
pairs=$(cd "$BT" && ctest -N -V 2>&1 | sed -nE 's/^[0-9]+: Test command: .*md5cmp "([0-9a-f]{32})" "([^"]+)"$/\1 \2/p')
npairs=$(printf '%s\n' "$pairs" | grep -c .)
if [ "$npairs" -lt 100 ]; then
  echo "expected >=100 md5cmp checks, found $npairs" >&2
  emit_ctrf cmake-ctest 0 1 0
  exit 1
fi
while read -r _ f; do rm -f "$BT/$f"; done <<<"$pairs"

out=$(cd "$BT" && ctest -j"$MAYHEM_JOBS" 2>&1); echo "$out" | tail -15
line=$(echo "$out" | grep -E 'tests passed, [0-9]+ tests failed out of [0-9]+' | tail -1)
if [ -z "$line" ]; then
  echo "could not find the ctest summary line" >&2
  emit_ctrf cmake-ctest 0 1 0
  exit 1
fi
failed=$(echo "$line" | sed -E 's/.*, ([0-9]+) tests failed out of.*/\1/')
total=$(echo "$line" | sed -E 's/.*out of ([0-9]+).*/\1/')
passed=$(( total - failed ))

md5ok=0; md5bad=0
while read -r want f; do
  got=$(md5sum "$BT/$f" 2>/dev/null | cut -d' ' -f1)
  if [ "$got" = "$want" ]; then md5ok=$((md5ok+1)); else md5bad=$((md5bad+1)); echo "MD5 MISMATCH $f: want $want got ${got:-<missing>}" >&2; fi
done <<<"$pairs"
echo "independent md5sum verification: $md5ok ok, $md5bad bad"
emit_ctrf cmake-ctest $(( passed + md5ok )) $(( failed + md5bad )) 0
