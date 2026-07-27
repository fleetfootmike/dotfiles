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

# --- Task 2: deploy ---
stub_merge="$(mktemp)"; chmod +x "$stub_merge"
cat > "$stub_merge" <<'STUB'
#!/usr/bin/env bash
echo "MERGED $1 <- $2" >> "$1"
STUB

# missing target -> installed
th="$(mktemp -d)"
bash "$SCRIPT" --deploy-only --home "$th" >/dev/null
{ [ -f "$th/.bashrc" ] && cmp -s "$HERE/bashrc" "$th/.bashrc"; }
check "missing target is installed" $?
[ ! -e "$th/.perlenv" ]; check "perlenv is never deployed" $?

# identical target -> untouched, reported up to date
cp "$HERE/screenrc" "$th/.screenrc"
out="$(bash "$SCRIPT" --deploy-only --home "$th")"
echo "$out" | grep -q ".screenrc up to date"; check "identical is up to date" $?

# differing target + interactive + stub merge -> merge invoked
printf 'local change\n' > "$th/.bash_aliases"
DOTFILES_INTERACTIVE=1 DOTFILES_MERGE="$stub_merge" \
    bash "$SCRIPT" --deploy-only --home "$th" >/dev/null
grep -q "^MERGED" "$th/.bash_aliases"; check "differing target invokes merge" $?

# differing target + headless -> skipped, not clobbered
th2="$(mktemp -d)"
printf 'keep me\n' > "$th2/.bashrc"
DOTFILES_INTERACTIVE=0 bash "$SCRIPT" --deploy-only --home "$th2" >/dev/null
grep -q "keep me" "$th2/.bashrc"; check "headless differ is not clobbered" $?

# nonexistent --home -> clean error, non-zero exit
bash "$SCRIPT" --deploy-only --home /no/such/dir-xyz >/dev/null 2>&1
check "nonexistent --home errors" "$([ $? -ne 0 ] && echo 0 || echo 1)"

echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
