#!/usr/bin/env bash
# Test harness for perlenv_hook. Run: bash test/perlenv_hook_test.sh
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$HERE/perlenv_hook"
pass=0; fail=0
check() {
    if [ "$2" -eq 0 ]; then echo "ok   - $1"; pass=$((pass + 1))
    else echo "FAIL - $1"; fail=$((fail + 1)); fi
}
eq() { [ "$1" = "$2" ]; check "$3 (got '$1')" $?; }

# shellcheck source=/dev/null
. "$HOOK"   # non-interactive: defines functions, wires nothing

# --- Task 1: normalize ---
eq "$(_perlenv_normalize_version 5.034)"     perl-5.34.0 "normalize 5.034"
eq "$(_perlenv_normalize_version 5.34)"      perl-5.34.0 "normalize 5.34"
eq "$(_perlenv_normalize_version 5.034002)"  perl-5.34.2 "normalize 5.034002"
eq "$(_perlenv_normalize_version v5.36.1)"   perl-5.36.1 "normalize v5.36.1"
eq "$(_perlenv_normalize_version perl-5.36.0)" perl-5.36.0 "normalize idempotent"
_perlenv_normalize_version "nonsense" >/dev/null 2>&1
check "normalize rejects junk" "$([ $? -ne 0 ] && echo 0 || echo 1)"

# --- Task 1: is-perl-repo ---
t=$(mktemp -d); touch "$t/cpanfile"
_perlenv_is_perl_repo "$t"; check "cpanfile -> perl repo" $?
t2=$(mktemp -d); mkdir -p "$t2/lib/Foo"; touch "$t2/lib/Foo/Bar.pm"
_perlenv_is_perl_repo "$t2"; check "lib/*.pm -> perl repo" $?
t3=$(mktemp -d); touch "$t3/package.json"
_perlenv_is_perl_repo "$t3"; check "non-perl -> not a perl repo" \
    "$([ $? -ne 0 ] && echo 0 || echo 1)"

# --- Task 1: parse PERL_VERSION ---
t4=$(mktemp -d)
printf 'export CARTON="carton exec "\nexport PERL_VERSION=perl-5.36.0\n' > "$t4/.perlenv"
eq "$(_perlenv_parse_version "$t4/.perlenv")" perl-5.36.0 "parse PERL_VERSION"
printf '# export PERL_VERSION=perl-5.10.0\n' > "$t4/commented"
_perlenv_parse_version "$t4/commented" >/dev/null 2>&1
check "parse ignores commented PERL_VERSION" \
    "$([ $? -ne 0 ] && echo 0 || echo 1)"

echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
