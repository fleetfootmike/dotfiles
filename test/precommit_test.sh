#!/usr/bin/env bash
# Test harness for git/hooks/pre-commit. Run: bash test/precommit_test.sh
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$HERE/git/hooks/pre-commit"
pass=0; fail=0
check() { # check <desc> <0-for-pass>
    if [ "$2" -eq 0 ]; then echo "ok   - $1"; pass=$((pass+1))
    else echo "FAIL - $1"; fail=$((fail+1)); fi
}

# scratch repo on a feature branch (the hook refuses main/master)
mkrepo() {
    local r; r="$(mktemp -d)"
    ( cd "$r" && git init -q && git checkout -q -b feature )
    echo "$r"
}
# run the hook in repo $1, headless so a lint finding fails closed rather
# than prompting; setsid drops the controlling tty the hook probes for
run_hook() {
    if command -v setsid >/dev/null 2>&1; then
        ( cd "$1" && setsid -w bash "$HOOK" ) 2>&1
    else
        ( cd "$1" && bash "$HOOK" < /dev/null ) 2>&1
    fi
}

# --- extensionless bash files are recognised by the shellcheck directive ---
r="$(mkrepo)"
printf '# shellcheck shell=bash\necho "hi"\n' > "$r/clean"
( cd "$r" && git add clean )
out="$(run_hook "$r")"; rc=$?
echo "$out" | grep -q "checking bash file clean"
check "directive file is checked as bash" $?
check "clean directive file passes" "$rc"

r="$(mkrepo)"
printf '# shellcheck shell=bash\nif [ -n "$1" -a -n "$2" ]; then :; fi\n' \
    > "$r/dirty"
( cd "$r" && git add dirty )
out="$(run_hook "$r")"; rc=$?
[ "$rc" -ne 0 ]; check "directive file with a shellcheck warning fails" $?

r="$(mkrepo)"
printf '# shellcheck shell=bash disable=SC2034\nunused=1\n' > "$r/more"
( cd "$r" && git add more )
out="$(run_hook "$r")"
echo "$out" | grep -q "checking bash file more"
check "directive with extra settings is still bash" $?

r="$(mkrepo)"
printf '# just notes\nnot a script\n' > "$r/notes"
( cd "$r" && git add notes )
out="$(run_hook "$r")"
echo "$out" | grep -q "skipping unhandled file notes"
check "extensionless file without directive stays unhandled" $?

r="$(mkrepo)"
printf '# shellcheck shell=bashful\necho hi\n' > "$r/nope"
( cd "$r" && git add nope )
out="$(run_hook "$r")"
echo "$out" | grep -q "skipping unhandled file nope"
check "shell=bashful is not bash" $?

# --- this repo's own extensionless shell files pass the hook ---
for f in bashrc bash_profile bash_aliases perlenv_hook; do
    r="$(mkrepo)"
    cp "$HERE/$f" "$r/$f"
    ( cd "$r" && git add "$f" )
    out="$(run_hook "$r")"; rc=$?
    echo "$out" | grep -q "checking bash file $f"
    check "$f is checked as bash" $?
    check "$f passes the hook" "$rc"
done

echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
