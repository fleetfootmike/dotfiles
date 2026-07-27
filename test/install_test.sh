#!/usr/bin/env bash
# Test harness for install.sh. Run: bash test/install_test.sh
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$HERE/install.sh"
pass=0; fail=0
check() { # check <desc> <0-for-pass>
    if [ "$2" -eq 0 ]; then echo "ok   - $1"; pass=$((pass+1))
    else echo "FAIL - $1"; fail=$((fail+1)); fi
}

# --- Task 1: skeleton ---
out="$(bash "$SCRIPT" --help)"; rc=$?
check "--help exits 0" "$rc"
echo "$out" | grep -q -- "--deploy-only"; check "--help lists --deploy-only" $?
bash "$SCRIPT" --bogus >/dev/null 2>&1; check "unknown flag exits non-zero" \
    "$([ $? -ne 0 ] && echo 0 || echo 1)"
# sourcing must NOT run main: with the guard intact, args are ignored
# and the defaults stand; a broken guard would run main and flip DO_DEPLOY.
# shellcheck disable=SC1090  # Source path is dynamic in test harness
srcout="$( . "$SCRIPT" --check-only 2>&1; echo "DO_DEPLOY=$DO_DEPLOY" )"
echo "$srcout" | grep -q "DO_DEPLOY=1"; check "sourcing does not run main" $?

echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
