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

# differing target + interactive + all-yes -> becomes the repo version
printf 'local change\n' > "$th/.bash_aliases"
ans="$(mktemp)"; yes y | head -n 40 > "$ans"
DOTFILES_INTERACTIVE=1 DOTFILES_INPUT="$ans" \
    bash "$SCRIPT" --deploy-only --home "$th" >/dev/null 2>&1
cmp -s "$HERE/bash_aliases" "$th/.bash_aliases"
check "differing target merges to repo version (per-hunk yes)" $?

# differing target + headless -> skipped, not clobbered
th2="$(mktemp -d)"
printf 'keep me\n' > "$th2/.bashrc"
DOTFILES_INTERACTIVE=0 bash "$SCRIPT" --deploy-only --home "$th2" >/dev/null
grep -q "keep me" "$th2/.bashrc"; check "headless differ is not clobbered" $?

# merge deps missing -> differ is skipped, not clobbered
th_np="$(mktemp -d)"; printf 'keep me\n' > "$th_np/.bashrc"
# shellcheck disable=SC1090,SC2034  # DEST_HOME consumed by sourced deploy_file
( . "$SCRIPT"
  DEST_HOME="$th_np"
  is_interactive() { return 0; }
  tool_present() { [ "$1" != patch ]; }   # pretend patch is absent
  deploy_file bashrc ) >/dev/null 2>&1
grep -q '^keep me$' "$th_np/.bashrc"
check "missing patch: differ is skipped not clobbered" $?

# nonexistent --home -> clean error, non-zero exit
bash "$SCRIPT" --deploy-only --home /no/such/dir-xyz >/dev/null 2>&1
check "nonexistent --home errors" "$([ $? -ne 0 ] && echo 0 || echo 1)"

# --- merge: $EDITOR fallback (_merge_editor) ---
# resolve stub: keep the repo (right) side, drop yours block + markers
resolve_ed="$(mktemp)"; chmod +x "$resolve_ed"
cat > "$resolve_ed" <<'ED'
#!/usr/bin/env bash
awk '
  /^<<<<<<< / { d=1; next }
  /^=======$/ { d=0; next }
  /^>>>>>>> / { next }
  !d { print }
' "$1" > "$1.tmp" && mv "$1.tmp" "$1"
ED
# noop stub: leave the file (and its markers) untouched
noop_ed="$(mktemp)"; chmod +x "$noop_ed"
printf '#!/usr/bin/env bash\nexit 0\n' > "$noop_ed"

# resolve -> target becomes the repo version, no markers left
de="$(mktemp -d)"
printf 'a\nOLD\nc\n' > "$de/target"; printf 'a\nNEW\nc\n' > "$de/repo"
# shellcheck disable=SC1090
( . "$SCRIPT"; EDITOR="$resolve_ed" \
    _merge_editor bashrc "$de/repo" "$de/target" ) >/dev/null 2>&1
cmp -s "$de/target" "$de/repo"; check "editor-resolve adopts repo side" $?
grep -q '<<<<<<<' "$de/target"
check "editor-resolve leaves no markers" \
    "$([ $? -ne 0 ] && echo 0 || echo 1)"

# unresolved markers -> target left exactly as it was
de2="$(mktemp -d)"
printf 'a\nOLD\nc\n' > "$de2/target"; cp "$de2/target" "$de2/orig"
printf 'a\nNEW\nc\n' > "$de2/repo"
# shellcheck disable=SC1090
( . "$SCRIPT"; EDITOR="$noop_ed" \
    _merge_editor bashrc "$de2/repo" "$de2/target" ) >/dev/null 2>&1
cmp -s "$de2/target" "$de2/orig"; check "editor-unresolved keeps original" $?

# --- merge: per-hunk apply (merge_file) ---
# 2-hunk fixture: changes at line 2 and line 12 (far enough apart that
# the default 3-line diff context does not merge them into one hunk).
mk_pair() {
    { echo l1; echo OLD2; for i in $(seq 3 11); do echo "l$i"; done
      echo OLD12; echo l13; echo l14; } > "$1/target"
    { echo l1; echo NEW2; for i in $(seq 3 11); do echo "l$i"; done
      echo NEW12; echo l13; echo l14; } > "$1/repo"
}
ans_file() { local f="$1"; shift; printf '%s\n' "$@" > "$f"; }

# all yes -> target becomes byte-identical to repo
d="$(mktemp -d)"; mk_pair "$d"; ans_file "$d/ans" y y
# shellcheck disable=SC1090
( . "$SCRIPT"; DOTFILES_INPUT="$d/ans" \
    merge_file bashrc "$d/repo" "$d/target" ) >/dev/null 2>&1
cmp -s "$d/target" "$d/repo"; check "merge all-yes yields repo version" $?

# all no -> unchanged
d="$(mktemp -d)"; mk_pair "$d"; cp "$d/target" "$d/orig"; ans_file "$d/ans" n n
# shellcheck disable=SC1090
( . "$SCRIPT"; DOTFILES_INPUT="$d/ans" \
    merge_file bashrc "$d/repo" "$d/target" ) >/dev/null 2>&1
cmp -s "$d/target" "$d/orig"; check "merge all-no leaves file unchanged" $?

# mixed: accept hunk 1, skip hunk 2 -> NEW2 but OLD12
d="$(mktemp -d)"; mk_pair "$d"; ans_file "$d/ans" y n
# shellcheck disable=SC1090
( . "$SCRIPT"; DOTFILES_INPUT="$d/ans" \
    merge_file bashrc "$d/repo" "$d/target" ) >/dev/null 2>&1
{ grep -q '^NEW2$' "$d/target" && grep -q '^OLD12$' "$d/target"; }
check "merge mixed applies only accepted hunk" $?

# quit before any accept -> unchanged
d="$(mktemp -d)"; mk_pair "$d"; cp "$d/target" "$d/orig"; ans_file "$d/ans" q
# shellcheck disable=SC1090
( . "$SCRIPT"; DOTFILES_INPUT="$d/ans" \
    merge_file bashrc "$d/repo" "$d/target" ) >/dev/null 2>&1
cmp -s "$d/target" "$d/orig"; check "merge quit-first leaves file unchanged" $?

# edit path: e hands off to $EDITOR (resolve stub -> repo side)
d="$(mktemp -d)"; mk_pair "$d"; ans_file "$d/ans" e
# shellcheck disable=SC1090
( . "$SCRIPT"; EDITOR="$resolve_ed" DOTFILES_INPUT="$d/ans" \
    merge_file bashrc "$d/repo" "$d/target" ) >/dev/null 2>&1
cmp -s "$d/target" "$d/repo"; check "merge edit-path resolves via \$EDITOR" $?

# accept hunk 1 then quit -> the accepted hunk lands, the rest does not
d="$(mktemp -d)"; mk_pair "$d"; ans_file "$d/ans" y q
# shellcheck disable=SC1090
( . "$SCRIPT"; DOTFILES_INPUT="$d/ans" \
    merge_file bashrc "$d/repo" "$d/target" ) >/dev/null 2>&1
{ grep -q '^NEW2$' "$d/target" && grep -q '^OLD12$' "$d/target"; }
check "merge accept-then-quit applies accepted hunk only" $?

# accept hunk 1 then edit -> $EDITOR resolves the whole file, the y is dropped
d="$(mktemp -d)"; mk_pair "$d"; ans_file "$d/ans" y e
# shellcheck disable=SC1090
( . "$SCRIPT"; EDITOR="$resolve_ed" DOTFILES_INPUT="$d/ans" \
    merge_file bashrc "$d/repo" "$d/target" ) >/dev/null 2>&1
cmp -s "$d/target" "$d/repo"
check "merge edit-after-accept resolves whole file" $?

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

# --- perlenv_hook is deployed ---
th5="$(mktemp -d)"
bash "$SCRIPT" --deploy-only --home "$th5" >/dev/null
[ -f "$th5/.perlenv_hook" ] && cmp -s "$HERE/perlenv_hook" "$th5/.perlenv_hook"
check "install deploys perlenv_hook" $?

echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
