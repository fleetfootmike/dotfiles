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

# --- Task 2: detector ---
d=$(mktemp -d); mkdir -p "$d/lib"
printf 'package X;\nuse 5.010;\n1;\n' > "$d/lib/X.pm"
eq "$(_perlenv_detect_min_version "$d")" perl-5.10.0 "detect use 5.010"

d=$(mktemp -d)
printf "requires 'perl', '5.034';\nrequires 'Moo';\n" > "$d/cpanfile"
eq "$(_perlenv_detect_min_version "$d")" perl-5.34.0 "detect cpanfile perl"

d=$(mktemp -d)
printf "use ExtUtils::MakeMaker;\nWriteMakefile(MIN_PERL_VERSION => '5.020');\n" \
    > "$d/Makefile.PL"
eq "$(_perlenv_detect_min_version "$d")" perl-5.20.0 "detect Makefile.PL"

d=$(mktemp -d)
printf '[Prereqs]\nperl = 5.028\n' > "$d/dist.ini"
eq "$(_perlenv_detect_min_version "$d")" perl-5.28.0 "detect dist.ini"

# highest wins across sources
d=$(mktemp -d); mkdir -p "$d/lib"
printf 'use 5.010;\n' > "$d/lib/A.pm"
printf "requires 'perl', '5.036';\n" > "$d/cpanfile"
eq "$(_perlenv_detect_min_version "$d")" perl-5.36.0 "detect highest wins"

# nothing detected -> empty
d=$(mktemp -d); touch "$d/README"
eq "$(_perlenv_detect_min_version "$d")" "" "detect none -> empty"

# carton local/ deps DO raise the floor (a dep needing 5.38 => repo needs 5.38)
d=$(mktemp -d); mkdir -p "$d/lib" "$d/local/lib/perl5/Dep"
printf 'use 5.010;\n' > "$d/lib/App.pm"
printf 'use 5.038;\n' > "$d/local/lib/perl5/Dep/Mod.pm"
eq "$(_perlenv_detect_min_version "$d")" perl-5.38.0 "detect counts local/ deps"

# blib/ build artifacts (copies of own lib) are skipped
d=$(mktemp -d); mkdir -p "$d/lib" "$d/blib/lib"
printf 'use 5.010;\n' > "$d/lib/App.pm"
printf 'use 5.040;\n' > "$d/blib/lib/App.pm"
eq "$(_perlenv_detect_min_version "$d")" perl-5.10.0 "detect skips blib build artifact"

# a second version token on the same line must not win
d=$(mktemp -d)
printf "requires 'perl', '5.020'; # needs 5.99 elsewhere\n" > "$d/cpanfile"
eq "$(_perlenv_detect_min_version "$d")" perl-5.20.0 "detect takes first token per line"

# --- Task 3: allow-list ---
store=$(mktemp -u)
export PERLENV_ALLOW_FILE="$store"
d=$(mktemp -d); printf 'export CARTON="carton exec "\n' > "$d/.perlenv"
_perlenv_allow_check "$d/.perlenv"
check "unknown .perlenv not allowed" \
    "$([ $? -ne 0 ] && echo 0 || echo 1)"
_perlenv_allow_add "$d/.perlenv"
_perlenv_allow_check "$d/.perlenv"; check "added .perlenv is allowed" $?
printf 'export CARTON="x"\n' >> "$d/.perlenv"   # change contents
_perlenv_allow_check "$d/.perlenv"
check "changed .perlenv no longer allowed" \
    "$([ $? -ne 0 ] && echo 0 || echo 1)"
_perlenv_allow_add "$d/.perlenv"
lines=$(grep -c " $(_perlenv_abspath "$d/.perlenv")\$" "$store")
eq "$lines" "1" "re-add replaces the old entry (one line for path)"
unset PERLENV_ALLOW_FILE

# re-adding a path must dedup on the EXACT path, not a substring match
store=$(mktemp -u); export PERLENV_ALLOW_FILE="$store"
a=$(mktemp -d); printf 'x\n' > "$a/.perlenv"; _perlenv_allow_add "$a/.perlenv"
absA=$(_perlenv_abspath "$a/.perlenv")
printf 'deadbeef /other/x %s\n' "$absA" >> "$store"   # path merely CONTAINS absA
_perlenv_allow_add "$a/.perlenv"                        # re-add A
grep -qF "deadbeef /other/x $absA" "$store"
check "re-add dedups on exact path, keeps substring-containing entries" $?
# the allow store is not group/world readable
perms=$(stat -c '%a' "$store" 2>/dev/null || stat -f '%Lp' "$store" 2>/dev/null)
eq "$perms" "600" "allow store is chmod 600"
unset PERLENV_ALLOW_FILE

# --- Task 4: perlenv-init ---
d=$(mktemp -d); ( cd "$d" && git init -q )
printf "requires 'perl', '5.036';\n" > "$d/cpanfile"
( cd "$d" && perlenv-init >/dev/null )
[ -f "$d/.perlenv" ]; check "perlenv-init writes .perlenv" $?
grep -q '^export PERL_VERSION=perl-5.36.0$' "$d/.perlenv"
check "perlenv-init fills detected PERL_VERSION" $?
grep -q 'CARTON=' "$d/.perlenv"; check "perlenv-init includes template body" $?

# no signals -> template only, no active PERL_VERSION
d=$(mktemp -d); ( cd "$d" && git init -q ); touch "$d/README"
( cd "$d" && perlenv-init >/dev/null )
grep -qE '^export PERL_VERSION=' "$d/.perlenv"
check "perlenv-init leaves PERL_VERSION unset when none detected" \
    "$([ $? -ne 0 ] && echo 0 || echo 1)"

# refuses to clobber
( cd "$d" && perlenv-init >/dev/null 2>&1 )
check "perlenv-init refuses to overwrite existing .perlenv" \
    "$([ $? -ne 0 ] && echo 0 || echo 1)"

# --- Task 5: chpwd handler ---
# stub perlbrew; record the last use/off to a file the PARENT reads
perlbrew() {
    case "${1:-}" in
        list) printf '  perl-5.34.0\n* perl-5.36.0\n  perl-5.20.0\n' ;;
        use)  echo "$2" > "$PB" ;;
        off)  echo off > "$PB" ;;
    esac
}
mkrepo() { local r; r=$(mktemp -d); ( cd "$r" && git init -q ); echo "$r"; }

# enter a repo whose allowed .perlenv sets an installed PERL_VERSION
PB=$(mktemp); store=$(mktemp -u); r=$(mkrepo)
printf 'export PERL5LIB=./lib\nexport PERL_VERSION=perl-5.36.0\n' > "$r/.perlenv"
p5=$( export PERLENV_ALLOW_FILE="$store" PERLENV_ASSUME=yes
      cd "$r" && _perlenv_chpwd; printf '%s' "${PERL5LIB:-<unset>}" )
eq "$(cat "$PB")" perl-5.36.0 "enter: perlbrew use installed version"
eq "$p5" "./lib" "enter: .perlenv sourced (PERL5LIB set)"

# leaving reverts perl (no PERLENV_DEFAULT -> off) and restores PERL5LIB
PB=$(mktemp); store=$(mktemp -u); r=$(mkrepo); out=$(mktemp -d)
printf 'export PERL5LIB=./lib\nexport PERL_VERSION=perl-5.36.0\n' > "$r/.perlenv"
p5=$( export PERLENV_ALLOW_FILE="$store" PERLENV_ASSUME=yes; export PERL5LIB=preexisting
      cd "$r" && _perlenv_chpwd
      cd "$out" && _perlenv_chpwd; printf '%s' "${PERL5LIB:-<unset>}" )
eq "$(cat "$PB")" off "leave: perlbrew off"
eq "$p5" preexisting "leave: PERL5LIB restored"

# uninstalled version -> warn, no perlbrew use
PB=$(mktemp); store=$(mktemp -u); r=$(mkrepo)
printf 'export PERL_VERSION=perl-5.99.0\n' > "$r/.perlenv"
( export PERLENV_ALLOW_FILE="$store" PERLENV_ASSUME=yes
  cd "$r" && _perlenv_chpwd 2>/dev/null )
[ ! -s "$PB" ]; check "enter: uninstalled version does not perlbrew use" $?

# declined allow -> .perlenv not sourced
PB=$(mktemp); store=$(mktemp -u); r=$(mkrepo)
printf 'export PERL5LIB=./lib\n' > "$r/.perlenv"
p5=$( export PERLENV_ALLOW_FILE="$store" PERLENV_ASSUME=no; export PERL5LIB=preexisting
      cd "$r" && _perlenv_chpwd; printf '%s' "${PERL5LIB:-<unset>}" )
eq "$p5" preexisting "declined allow: .perlenv not sourced"

# direct repo -> different repo: revert A then apply B
PB=$(mktemp); store=$(mktemp -u); rA=$(mkrepo); rB=$(mkrepo)
printf 'export PERL5LIB=./libA\nexport PERL_VERSION=perl-5.36.0\n' > "$rA/.perlenv"
printf 'export PERL5LIB=./libB\nexport PERL_VERSION=perl-5.34.0\n' > "$rB/.perlenv"
p5=$( export PERLENV_ALLOW_FILE="$store" PERLENV_ASSUME=yes
      cd "$rA" && _perlenv_chpwd
      cd "$rB" && _perlenv_chpwd; printf '%s' "${PERL5LIB:-<unset>}" )
eq "$(cat "$PB")" perl-5.34.0 "repo->repo: perl switches to B"
eq "$p5" "./libB" "repo->repo: PERL5LIB is B's"

# subdir of same repo -> no re-switch
PB=$(mktemp); store=$(mktemp -u); r=$(mkrepo); mkdir -p "$r/lib/Deep"
printf 'export PERL_VERSION=perl-5.36.0\n' > "$r/.perlenv"
after=$( export PERLENV_ALLOW_FILE="$store" PERLENV_ASSUME=yes
         cd "$r" && _perlenv_chpwd
         : > "$PB"
         cd "$r/lib/Deep" && _perlenv_chpwd
         cat "$PB" )
eq "$after" "" "subdir of same repo: no re-switch"

# PERLENV_DEFAULT set -> leave reverts to it (not off)
PB=$(mktemp); store=$(mktemp -u); r=$(mkrepo); out=$(mktemp -d)
printf 'export PERL_VERSION=perl-5.36.0\n' > "$r/.perlenv"
( export PERLENV_ALLOW_FILE="$store" PERLENV_ASSUME=yes PERLENV_DEFAULT=perl-5.20.0
  cd "$r" && _perlenv_chpwd
  cd "$out" && _perlenv_chpwd )
eq "$(cat "$PB")" perl-5.20.0 "leave: reverts to PERLENV_DEFAULT"

# CARTON snapshot/restore across enter/leave
PB=$(mktemp); store=$(mktemp -u); r=$(mkrepo); out=$(mktemp -d)
printf 'export CARTON="carton exec "\nexport PERL_VERSION=perl-5.36.0\n' > "$r/.perlenv"
c=$( export PERLENV_ALLOW_FILE="$store" PERLENV_ASSUME=yes; export CARTON=orig
     cd "$r" && _perlenv_chpwd
     cd "$out" && _perlenv_chpwd; printf '%s' "${CARTON:-<unset>}" )
eq "$c" orig "leave: CARTON restored"

echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
