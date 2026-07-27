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

# --- Task 3: prereqs (unit tests via sourcing) ---
# all-missing, apt: every core tool prints its apt/special recipe
# shellcheck disable=SC1090  # Source path is dynamic in test harness
recipes="$(
    . "$SCRIPT"
    PKG=apt
    prereq_present() { return 1; }   # stub: nothing installed
    check_prereqs 2>&1
)"
echo "$recipes" | grep -q "perlbrew MISSING"; check "reports perlbrew missing" $?
echo "$recipes" | grep -q "install.perlbrew.pl"; check "prints perlbrew recipe" $?
echo "$recipes" | grep -q "cpanm Carton"; check "prints carton recipe" $?
echo "$recipes" | grep -q "apt-get install -y shellcheck"; \
    check "prints apt shellcheck recipe" $?

# all-missing, no package manager: no recipes, just MISSING
# shellcheck disable=SC1090  # Source path is dynamic in test harness
none="$(
    . "$SCRIPT"
    PKG=none
    prereq_present() { return 1; }
    check_prereqs 2>&1
)"
echo "$none" | grep -q "shellcheck MISSING"; check "pkg=none reports missing" $?
echo "$none" | grep -vq "apt-get install"; \
    check "pkg=none prints no apt recipe" $?

# detect_pkg_mgr picks apt when apt-get present
# shellcheck disable=SC1090  # Source path is dynamic in test harness
picked="$( . "$SCRIPT"; tool_present() { [ "$1" = apt-get ]; }; \
    detect_pkg_mgr; echo "$PKG" )"
[ "$picked" = apt ]; check "detect_pkg_mgr picks apt" $?

# --- Task 4: orchestration ---
th3="$(mktemp -d)"
out="$(bash "$SCRIPT" --deploy-only --home "$th3")"
echo "$out" | grep -vq "checking prereqs"; check "--deploy-only skips prereqs" $?
echo "$out" | grep -q "deploying dotfiles"; check "--deploy-only deploys" $?

th4="$(mktemp -d)"
out="$(bash "$SCRIPT" --check-only --home "$th4")"
echo "$out" | grep -q "checking prereqs"; check "--check-only checks" $?
{ echo "$out" | grep -vq "deploying dotfiles" && [ -z "$(ls -A "$th4")" ]; }
check "--check-only does not deploy" $?

# --- Final polish: added prereq coverage ---
# recipe_for honours PKG=brew for a pure-brew tool
# shellcheck disable=SC1090
brewrec="$( . "$SCRIPT"; PKG=brew; recipe_for shellcheck )"
echo "$brewrec" | grep -q "brew install shellcheck"; check "recipe_for brew branch" $?

# check_prereqs ok-path: everything present -> no MISSING, reports all present
# shellcheck disable=SC1090
okout="$( . "$SCRIPT"; prereq_present() { return 0; }; check_prereqs 2>&1 )"
echo "$okout" | grep -vq "MISSING"; check "check_prereqs ok-path has no MISSING" $?
echo "$okout" | grep -q "all core prereqs present"; check "check_prereqs ok-path summary" $?

# cpanm prints its special recipe plus the (or apt) alternative under PKG=apt
# shellcheck disable=SC1090
cpanmrec="$( . "$SCRIPT"; PKG=apt; recipe_for cpanm )"
echo "$cpanmrec" | grep -q "perlbrew install-cpanm"; check "cpanm special recipe" $?
echo "$cpanmrec" | grep -q "or sudo apt-get install -y cpanminus"; check "cpanm apt alternative" $?

echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
