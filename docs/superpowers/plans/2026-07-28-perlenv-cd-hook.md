# Perlenv cd hook Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps
> use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A bash `PROMPT_COMMAND` hook that, on entering a git repo,
switches the perlbrew perl to the repo's `PERL_VERSION` and loads its
`CARTON`/`PERL5LIB` (reverting on leave), sourcing `.perlenv` only from an
allow-list, plus a `perlenv-init` helper with a best-effort min-perl
detector.

**Architecture:** One sourced bash file, `perlenv_hook`, built from small
functions. Pure helpers (version normalize, Perl-repo detection,
`PERL_VERSION` parse, min-version detect, allow-list) are unit-tested by
sourcing the file and calling them; the stateful `_perlenv_chpwd` handler
is tested by driving it across fixture repos with `perlbrew` stubbed. A
tracked harness `test/perlenv_hook_test.sh` runs it all. `bashrc`,
`install.sh`, and the `perlenv` template get small edits to wire it in.

**Tech Stack:** bash (portable to 3.2), shellcheck, perlbrew, git.

## Global Constraints

Every task's requirements implicitly include these:

- `perlenv_hook` is **sourced** into an interactive shell. It must NOT set
  `set -e`/`set -u` (that would break the user's shell). Put
  `# shellcheck shell=bash` as the first line so shellcheck lints it.
- **No side effects on source except the interactive wiring.** The
  `PROMPT_COMMAND` wiring block runs only for interactive shells
  (`case $- in *i*)`). The test harness sources the file
  non-interactively, so wiring is skipped and only function definitions
  load.
- Portable bash, **no bash-4-only features**: no `declare -A`, no
  `mapfile`/`readarray`, no `${v^^}`/`${v,,}`. Indexed values, `case`, and
  string ops only.
- Every read of a hook state variable uses a default (`${_PERLENV_x:-}`)
  so it is safe under a caller's `set -u`.
- Perl-version **normalization is only for the detector**. The cd hook
  passes `PERL_VERSION` to `perlbrew use` **as written** (trust the user's
  perlbrew name), never normalized.
- A repo's `.perlenv` is sourced **only** when present in the allow-list
  with a matching hash.
- `perlenv_hook` must pass `shellcheck -S warning` clean.
- Hashing must work on Linux and macOS: `sha256sum`, else `shasum -a 256`.
- Test seams: `PERLENV_ALLOW_FILE` overrides the allow-store path;
  `PERLENV_ASSUME` (`yes`/`no`) pre-answers confirm prompts.
- `main`/`master` are hook-blocked. Work lands on the `perlenv-cd-hook`
  branch, one commit per task, each gated on the user's explicit OK.
- Commit messages end with:
  `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`

## File Structure

- Create: `perlenv_hook` (repo root), the whole hook + helpers.
- Create: `test/perlenv_hook_test.sh`, the tracked harness.
- Modify: `bashrc`, one source line (after the perlbrew block).
- Modify: `install.sh`, add `perlenv_hook` to `DOTFILES`.
- Modify: `perlenv`, add the `PERL_VERSION` reminder.

`perlenv_hook` is one file: the functions share state variables and the
embedded template, and it deploys as a single dotfile.

---

### Task 1: Scaffold + pure helpers (normalize, is-perl-repo, parse)

**Files:**

- Create: `perlenv_hook`
- Create: `test/perlenv_hook_test.sh`

**Interfaces:**

- Produces: `_perlenv_normalize_version <raw> -> perl-5.MM.PP` (echo, rc 1
  if unparseable); `_perlenv_is_perl_repo <dir>` (rc 0/1);
  `_perlenv_parse_version <perlenv_file> -> raw PERL_VERSION value` (echo).
  Later tasks add the detector, allow-list, `perlenv-init`, and the
  `_perlenv_chpwd` handler to the same file.

- [ ] **Step 1: Write the failing test harness**

Create `test/perlenv_hook_test.sh`:

```bash
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
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash test/perlenv_hook_test.sh`
Expected: FAIL (`perlenv_hook` does not exist).

- [ ] **Step 3: Create `perlenv_hook` with the pure helpers**

```bash
# shellcheck shell=bash
# perlenv_hook - bash cd hook to manage the per-repo perlbrew perl and
# .perlenv. Sourced from ~/.bashrc. Interactive shells only. No set -e/-u.

# Normalize a raw perl version token to perlbrew form perl-5.MM.PP.
# Used ONLY by the detector; the cd hook uses PERL_VERSION as written.
_perlenv_normalize_version() {
    local v="$1" maj rest min pat
    v="${v#perl-}"; v="${v#v}"
    case "$v" in
        *.*.*) printf 'perl-%s\n' "$v"; return 0 ;;
        *.*)
            maj="${v%%.*}"; rest="${v#*.}"; rest="${rest//[!0-9]/}"
            case ${#rest} in
                0) return 1 ;;
                1|2|3) min=$((10#$rest)); pat=0 ;;
                *) min=$((10#${rest:0:3})); pat=$((10#${rest:3:3})) ;;
            esac
            printf 'perl-%s.%s.%s\n' "$maj" "$min" "$pat"; return 0 ;;
        *) return 1 ;;
    esac
}

# Does $1 (default .) look like a Perl project?
_perlenv_is_perl_repo() {
    local d="${1:-.}"
    [ -f "$d/cpanfile" ] && return 0
    [ -f "$d/Makefile.PL" ] && return 0
    [ -f "$d/dist.ini" ] && return 0
    [ -d "$d/lib" ] && \
        [ -n "$(find "$d/lib" -name '*.pm' -print -quit 2>/dev/null)" ] && \
        return 0
    return 1
}

# Echo the raw (trimmed) PERL_VERSION value from a .perlenv, rc 1 if none.
_perlenv_parse_version() {
    local f="$1" line val
    [ -f "$f" ] || return 1
    line=$(grep -E '^[[:space:]]*(export[[:space:]]+)?PERL_VERSION=' "$f" \
        2>/dev/null | tail -1)
    [ -n "$line" ] || return 1
    val="${line#*=}"; val="${val%%#*}"
    val="${val//\"/}"; val="${val//\'/}"
    val="$(printf '%s' "$val" | tr -d '[:space:]')"
    [ -n "$val" ] || return 1
    printf '%s\n' "$val"
}
```

Note the `grep -E '^[[:space:]]*(export...)?PERL_VERSION='` anchors at line
start after optional whitespace, so a `# export PERL_VERSION=` comment line
does not match (the `#` precedes the whitespace-then-PERL_VERSION anchor).

- [ ] **Step 4: Run to verify Task 1 cases pass**

Run: `bash test/perlenv_hook_test.sh`
Expected: all Task 1 cases print `ok`, exit 0.

- [ ] **Step 5: shellcheck**

Run: `shellcheck -S warning perlenv_hook test/perlenv_hook_test.sh`
Expected: no output.

- [ ] **Step 6: Commit (after user OK)**

```bash
git add perlenv_hook test/perlenv_hook_test.sh
git commit  # "Add perlenv_hook scaffold with version/repo/parse helpers"
```

---

### Task 2: Min-perl-version detector

**Files:**

- Modify: `perlenv_hook`
- Test: `test/perlenv_hook_test.sh`

**Interfaces:**

- Consumes: `_perlenv_normalize_version` (Task 1).
- Produces: `_perlenv_detect_min_version <dir> -> perl-5.MM.PP` (echo,
  empty if nothing detected).

- [ ] **Step 1: Write the failing tests**

Append before the summary line in `test/perlenv_hook_test.sh`:

```bash
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
```

- [ ] **Step 2: Run to verify the new cases fail**

Run: `bash test/perlenv_hook_test.sh`
Expected: Task 2 cases FAIL (`_perlenv_detect_min_version` undefined).

- [ ] **Step 3: Implement the detector**

Add to `perlenv_hook`:

```bash
# Best-effort minimum perl version for a repo, as perl-5.MM.PP (or empty).
# Scans: use VERSION in *.pm, and a perl prereq in cpanfile/Makefile.PL/
# dist.ini. Highest floor wins. Best-effort, no guarantees.
_perlenv_detect_min_version() {
    local d="${1:-.}" tok
    {
        grep -rhE 'use[[:space:]]+v?5\.' "$d" --include='*.pm' 2>/dev/null
        [ -f "$d/cpanfile" ] && \
            grep -E "['\"]perl['\"]" "$d/cpanfile" 2>/dev/null
        [ -f "$d/Makefile.PL" ] && \
            grep -E 'MIN_PERL_VERSION' "$d/Makefile.PL" 2>/dev/null
        [ -f "$d/dist.ini" ] && \
            grep -iE '^[[:space:]]*perl[[:space:]]*=' "$d/dist.ini" 2>/dev/null
    } | grep -oE 'v?5\.[0-9][._0-9]*' | while IFS= read -r tok; do
        _perlenv_normalize_version "$tok"
    done | sort -V | tail -1
}
```

- [ ] **Step 4: Run to verify Task 2 cases pass**

Run: `bash test/perlenv_hook_test.sh`
Expected: Task 2 cases print `ok`.

- [ ] **Step 5: shellcheck**

Run: `shellcheck -S warning perlenv_hook test/perlenv_hook_test.sh`
Expected: no output.

- [ ] **Step 6: Commit (after user OK)**

```bash
git add perlenv_hook test/perlenv_hook_test.sh
git commit  # "Add best-effort min-perl-version detector"
```

---

### Task 3: Allow-list

**Files:**

- Modify: `perlenv_hook`
- Test: `test/perlenv_hook_test.sh`

**Interfaces:**

- Produces: `_perlenv_allow_file` (echo store path), `_perlenv_hash <file>`
  (echo sha256, rc 1 if no tool), `_perlenv_abspath <file>` (echo absolute
  path), `_perlenv_allow_check <perlenv>` (rc 0 allowed / 1 not),
  `_perlenv_allow_add <perlenv>` (record path+hash). Honors
  `PERLENV_ALLOW_FILE`.

- [ ] **Step 1: Write the failing tests**

Append before the summary line:

```bash
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
```

- [ ] **Step 2: Run to verify the new cases fail**

Run: `bash test/perlenv_hook_test.sh`
Expected: Task 3 cases FAIL.

- [ ] **Step 3: Implement the allow-list**

Add to `perlenv_hook`:

```bash
_perlenv_allow_file() {
    printf '%s\n' \
        "${PERLENV_ALLOW_FILE:-${XDG_STATE_HOME:-$HOME/.local/state}/perlenv/allow}"
}

_perlenv_hash() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" 2>/dev/null | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
    else
        return 1
    fi
}

_perlenv_abspath() {
    ( cd "$(dirname "$1")" 2>/dev/null && \
        printf '%s/%s\n' "$(pwd -P)" "$(basename "$1")" )
}

# rc 0 if this .perlenv is allowed with a matching hash, else 1.
_perlenv_allow_check() {
    local f="$1" store h abs
    h=$(_perlenv_hash "$f") || return 1
    abs=$(_perlenv_abspath "$f") || return 1
    store=$(_perlenv_allow_file)
    [ -f "$store" ] || return 1
    grep -qxF "$h $abs" "$store"
}

# Record path+hash, replacing any prior entry for the same path.
_perlenv_allow_add() {
    local f="$1" store dir h abs
    h=$(_perlenv_hash "$f") || return 1
    abs=$(_perlenv_abspath "$f") || return 1
    store=$(_perlenv_allow_file); dir=$(dirname "$store")
    [ -d "$dir" ] || mkdir -p "$dir" || return 1
    if [ -f "$store" ]; then
        grep -vF " $abs" "$store" > "$store.tmp" 2>/dev/null || true
        mv "$store.tmp" "$store"
    fi
    printf '%s %s\n' "$h" "$abs" >> "$store"
}
```

- [ ] **Step 4: Run to verify Task 3 cases pass**

Run: `bash test/perlenv_hook_test.sh`
Expected: Task 3 cases print `ok`.

- [ ] **Step 5: shellcheck**

Run: `shellcheck -S warning perlenv_hook test/perlenv_hook_test.sh`
Expected: no output.

- [ ] **Step 6: Commit (after user OK)**

```bash
git add perlenv_hook test/perlenv_hook_test.sh
git commit  # "Add direnv-style allow-list for sourcing .perlenv"
```

---

### Task 4: `perlenv-init` + embedded template

**Files:**

- Modify: `perlenv_hook`
- Test: `test/perlenv_hook_test.sh`

**Interfaces:**

- Consumes: `_perlenv_detect_min_version` (Task 2).
- Produces: `_perlenv_write_template <path>` (writes the template file);
  `perlenv-init` (writes `.perlenv` at the repo root, appends a detected
  `PERL_VERSION`).

- [ ] **Step 1: Write the failing tests**

Append before the summary line:

```bash
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
```

- [ ] **Step 2: Run to verify the new cases fail**

Run: `bash test/perlenv_hook_test.sh`
Expected: Task 4 cases FAIL.

- [ ] **Step 3: Implement `perlenv-init`**

Add to `perlenv_hook`:

```bash
_perlenv_write_template() {
    cat > "$1" <<'TEMPLATE'
# .perlenv - per-repo Perl environment, sourced by the pre-commit hook and
# the perlenv cd hook.

# if your perl env requires carton
export CARTON="carton exec "
export PERL5LIB=./lib:./t/lib:$PERL5LIB

# set PERL_VERSION so the cd hook switches perlbrew perls for you:
# export PERL_VERSION=perl-5.36.0
TEMPLATE
}

# Create .perlenv at the current repo root, pre-filling a detected
# PERL_VERSION when one is found.
perlenv-init() {
    local root pv
    root=$(git rev-parse --show-toplevel 2>/dev/null) || {
        echo "perlenv-init: not inside a git repo" >&2; return 1; }
    if [ -e "$root/.perlenv" ]; then
        echo "perlenv-init: $root/.perlenv already exists" >&2; return 1
    fi
    _perlenv_write_template "$root/.perlenv"
    pv=$(_perlenv_detect_min_version "$root")
    if [ -n "$pv" ]; then
        printf 'export PERL_VERSION=%s\n' "$pv" >> "$root/.perlenv"
        echo "perlenv-init: wrote $root/.perlenv (PERL_VERSION=$pv, detected)"
    else
        echo "perlenv-init: wrote $root/.perlenv (set PERL_VERSION yourself)"
    fi
}
```

- [ ] **Step 4: Run to verify Task 4 cases pass**

Run: `bash test/perlenv_hook_test.sh`
Expected: Task 4 cases print `ok`.

- [ ] **Step 5: shellcheck**

Run: `shellcheck -S warning perlenv_hook test/perlenv_hook_test.sh`
Expected: no output.

- [ ] **Step 6: Commit (after user OK)**

```bash
git add perlenv_hook test/perlenv_hook_test.sh
git commit  # "Add perlenv-init to scaffold .perlenv with detected version"
```

---

### Task 5: The chpwd handler, revert, and PROMPT_COMMAND wiring

**Files:**

- Modify: `perlenv_hook`
- Test: `test/perlenv_hook_test.sh`

**Interfaces:**

- Consumes: everything from Tasks 1-4.
- Produces: `_perlenv_confirm`, `_perlenv_decline`/`_perlenv_declined`,
  `_perlenv_perl_installed`, `_perlenv_apply`, `_perlenv_revert`,
  `_perlenv_enter`, `_perlenv_chpwd`, and the interactive wiring block.

- [ ] **Step 1: Write the failing tests**

Append before the summary line. Each case runs in a subshell so state and
cwd stay isolated, with `perlbrew` stubbed and prompts pre-answered. (These
tests assume `mktemp -d` returns a dir outside any git repo, true on a
standard `/tmp`; if `$TMPDIR` sat under a working tree the "leave" case
would misfire.)

```bash
# --- Task 5: chpwd handler ---
# stub perlbrew; record the last "use"/"off" into a file the subshell shares
perlbrew() {
    case "${1:-}" in
        list) printf '  perl-5.34.0\n* perl-5.36.0\n' ;;
        use)  echo "$2" > "$PB" ;;
        off)  echo "off" > "$PB" ;;
    esac
}
mkrepo() { local r; r=$(mktemp -d); ( cd "$r" && git init -q ); echo "$r"; }

# entering a repo whose allowed .perlenv sets an installed PERL_VERSION
PB=$(mktemp); store=$(mktemp -u)
r=$(mkrepo)
printf 'export PERL5LIB=./lib\nexport PERL_VERSION=perl-5.36.0\n' > "$r/.perlenv"
(
    export PERLENV_ALLOW_FILE="$store" PERLENV_ASSUME=yes
    cd "$r" && _perlenv_chpwd
    eq "$(cat "$PB")" perl-5.36.0 "enter: perlbrew use installed version"
    eq "$PERL5LIB" "./lib" "enter: .perlenv sourced (PERL5LIB set)"
)

# leaving that repo reverts perl (no PERLENV_DEFAULT -> off) and PERL5LIB
PB=$(mktemp); store=$(mktemp -u); r=$(mkrepo)
printf 'export PERL5LIB=./lib\nexport PERL_VERSION=perl-5.36.0\n' > "$r/.perlenv"
out=$(mktemp -d)   # a plain non-repo dir
(
    export PERLENV_ALLOW_FILE="$store" PERLENV_ASSUME=yes
    export PERL5LIB=preexisting
    cd "$r" && _perlenv_chpwd
    cd "$out" && _perlenv_chpwd
    eq "$(cat "$PB")" off "leave: perlbrew off"
    eq "$PERL5LIB" preexisting "leave: PERL5LIB restored"
)

# uninstalled version -> warn, no perlbrew use
PB=$(mktemp); store=$(mktemp -u); r=$(mkrepo)
printf 'export PERL_VERSION=perl-5.99.0\n' > "$r/.perlenv"
(
    export PERLENV_ALLOW_FILE="$store" PERLENV_ASSUME=yes
    cd "$r" && _perlenv_chpwd 2>/dev/null
    [ ! -s "$PB" ]; check "enter: uninstalled version does not perlbrew use" $?
)

# declined allow -> not sourced
PB=$(mktemp); store=$(mktemp -u); r=$(mkrepo)
printf 'export PERL5LIB=./lib\n' > "$r/.perlenv"
(
    export PERLENV_ALLOW_FILE="$store" PERLENV_ASSUME=no
    export PERL5LIB=preexisting
    cd "$r" && _perlenv_chpwd
    eq "$PERL5LIB" preexisting "declined allow: .perlenv not sourced"
)
```

- [ ] **Step 2: Run to verify the new cases fail**

Run: `bash test/perlenv_hook_test.sh`
Expected: Task 5 cases FAIL (`_perlenv_chpwd` undefined).

- [ ] **Step 3: Implement the handler**

Add to `perlenv_hook`:

```bash
_perlenv_confirm() {
    local ans
    case "${PERLENV_ASSUME:-}" in
        yes) return 0 ;; no) return 1 ;;
    esac
    read -r -p ">>> perlenv: $1 [y/N] " ans
    case "$ans" in [Yy]*) return 0 ;; *) return 1 ;; esac
}

_perlenv_decline() { _PERLENV_DECLINED="${_PERLENV_DECLINED:-}
$1"; }
_perlenv_declined() {
    case "
${_PERLENV_DECLINED:-}
" in *"
$1
"*) return 0 ;; *) return 1 ;; esac
}

_perlenv_perl_installed() {
    perlbrew list 2>/dev/null | sed 's/^[* ]*//' | grep -qxF "$1"
}

# snapshot env, source the .perlenv, switch perl
_perlenv_apply() {
    local root="$1" pe="$2" pv
    _PERLENV_SAVED_PERL5LIB="${PERL5LIB-}"
    _PERLENV_SAVED_PERL5LIB_SET="${PERL5LIB+1}"
    _PERLENV_SAVED_CARTON="${CARTON-}"
    _PERLENV_SAVED_CARTON_SET="${CARTON+1}"
    # shellcheck source=/dev/null
    . "$pe"
    _PERLENV_ACTIVE_ROOT="$root"
    pv=$(_perlenv_parse_version "$pe") || return 0
    # perlbrew absent? skip the switch quietly. install.sh's prereq check
    # already yells about installing perlbrew, so no second warning here.
    command -v perlbrew >/dev/null 2>&1 || return 0
    if _perlenv_perl_installed "$pv"; then
        perlbrew use "$pv"
    else
        printf '!!! perlenv: .perlenv wants %s (not installed). To build it:\n' \
            "$pv" >&2
        printf '      perlbrew install %s\n' "$pv" >&2
    fi
}

# restore env snapshot and revert perl to the default
_perlenv_revert() {
    if [ "${_PERLENV_SAVED_PERL5LIB_SET:-}" = 1 ]; then
        export PERL5LIB="${_PERLENV_SAVED_PERL5LIB:-}"
    else
        unset PERL5LIB
    fi
    if [ "${_PERLENV_SAVED_CARTON_SET:-}" = 1 ]; then
        export CARTON="${_PERLENV_SAVED_CARTON:-}"
    else
        unset CARTON
    fi
    unset _PERLENV_SAVED_PERL5LIB _PERLENV_SAVED_PERL5LIB_SET
    unset _PERLENV_SAVED_CARTON _PERLENV_SAVED_CARTON_SET
    _PERLENV_ACTIVE_ROOT=""
    command -v perlbrew >/dev/null 2>&1 || return 0
    if [ -n "${PERLENV_DEFAULT:-}" ]; then
        perlbrew use "$PERLENV_DEFAULT"
    else
        perlbrew off 2>/dev/null || true
    fi
}

_perlenv_enter() {
    local root="$1" pe="$1/.perlenv"
    if [ -f "$pe" ]; then
        if _perlenv_allow_check "$pe"; then
            _perlenv_apply "$root" "$pe"
        elif _perlenv_declined "$pe"; then
            :
        elif _perlenv_confirm "allow .perlenv in $root?"; then
            _perlenv_allow_add "$pe" && _perlenv_apply "$root" "$pe"
        else
            _perlenv_decline "$pe"
        fi
    elif _perlenv_is_perl_repo "$root"; then
        if ! _perlenv_declined "$root"; then
            if _perlenv_confirm "no .perlenv in Perl repo $root; create one?"; then
                ( cd "$root" && perlenv-init )
                if [ -f "$pe" ]; then
                    _perlenv_allow_add "$pe" && _perlenv_apply "$root" "$pe"
                fi
            else
                _perlenv_decline "$root"
            fi
        fi
    fi
}

# PROMPT_COMMAND handler: act only when the git repo root changes.
_perlenv_chpwd() {
    [ "$PWD" = "${_PERLENV_LAST_PWD:-}" ] && return
    _PERLENV_LAST_PWD="$PWD"
    local root
    root=$(git rev-parse --show-toplevel 2>/dev/null)
    [ "$root" = "${_PERLENV_LAST_ROOT:-}" ] && return
    _PERLENV_LAST_ROOT="$root"
    [ -n "${_PERLENV_ACTIVE_ROOT:-}" ] && _perlenv_revert
    [ -n "$root" ] && _perlenv_enter "$root"
    return 0
}

# Wire into PROMPT_COMMAND for interactive shells only (skipped when the
# file is sourced non-interactively, e.g. by the test harness).
case $- in
    *i*)
        case "${PROMPT_COMMAND:-}" in
            *_perlenv_chpwd*) : ;;
            *) PROMPT_COMMAND="_perlenv_chpwd${PROMPT_COMMAND:+; $PROMPT_COMMAND}" ;;
        esac
        ;;
esac
```

- [ ] **Step 4: Run to verify Task 5 cases pass**

Run: `bash test/perlenv_hook_test.sh`
Expected: all cases print `ok`, exit 0.

- [ ] **Step 5: shellcheck**

Run: `shellcheck -S warning perlenv_hook test/perlenv_hook_test.sh`
Expected: no output. (`_perlenv_apply`'s `. "$pe"` carries a
`# shellcheck source=/dev/null`.)

- [ ] **Step 6: Commit (after user OK)**

```bash
git add perlenv_hook test/perlenv_hook_test.sh
git commit  # "Add chpwd handler, revert, and PROMPT_COMMAND wiring"
```

---

### Task 6: Packaging (bashrc, install.sh, template)

**Files:**

- Modify: `bashrc`
- Modify: `install.sh`
- Modify: `perlenv`
- Modify: `test/install_test.sh`

**Interfaces:**

- Consumes: the finished `perlenv_hook`, and `install.sh`'s `DOTFILES`
  array + `deploy_all`.

- [ ] **Step 1: Write the failing install test**

In `test/install_test.sh`, append before the summary line a case asserting
the hook is now deployed:

```bash
# --- perlenv_hook is deployed ---
th5="$(mktemp -d)"
bash "$SCRIPT" --deploy-only --home "$th5" >/dev/null
[ -f "$th5/.perlenv_hook" ] && cmp -s "$HERE/perlenv_hook" "$th5/.perlenv_hook"
check "install deploys perlenv_hook" $?
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash test/install_test.sh`
Expected: the new case FAILS (`perlenv_hook` not in `DOTFILES`).

- [ ] **Step 3: Wire the hook into the dotfiles**

In `install.sh`, add `perlenv_hook` to the `DOTFILES` array:

```bash
DOTFILES=(bashrc bash_profile bash_aliases screenrc markdownlint.json \
    perlenv_hook)
```

In `bashrc`, add this line near the end (it must come after the perlbrew
block so the `perlbrew` function exists when the hook runs):

```bash
# perlenv cd hook
if [ -f ~/.perlenv_hook ]; then
    . ~/.perlenv_hook
fi
```

In the `perlenv` template, add the reminder after the existing lines:

```sh
# set PERL_VERSION so the cd hook switches perlbrew perls for you:
# export PERL_VERSION=perl-5.36.0
```

- [ ] **Step 4: Run both suites**

Run: `bash test/install_test.sh` and `bash test/perlenv_hook_test.sh`
Expected: both exit 0, all cases pass.

- [ ] **Step 5: Lint everything**

Run: `shellcheck -S warning install.sh test/install_test.sh perlenv_hook
test/perlenv_hook_test.sh` (these must be clean) and `markdownlint` on any
changed `.md`. Do NOT require `bashrc` to be shellcheck-clean: it is
`unhandled` by the pre-commit hook (no `.sh` extension, no bash shebang), so
it is never linted on commit, and its existing `source` lines already trip
SC1090 with no directives. Match that style: add no lone shellcheck
directive to the new block, and verify it with `bash -n bashrc` (syntax
only), accepting the pre-existing warnings.

- [ ] **Step 6: Manual smoke**

In a real interactive bash: `source perlenv_hook`, then `cd` into a repo
with an allowed `.perlenv` setting an installed `PERL_VERSION` and confirm
the prompt's `<perl>` segment switches; `cd` out and confirm it reverts.

- [ ] **Step 7: Commit (after user OK)**

```bash
git add install.sh bashrc perlenv test/install_test.sh
git commit  # "Deploy perlenv_hook via install.sh and source it from bashrc"
```

---

## Self-Review

**Spec coverage:**

- Trigger (PROMPT_COMMAND chpwd emulation, interactive-only, PWD/root
  dedupe) -> Task 5.
- Per-entry flow (allow / source / perl switch / uninstalled warn /
  no-PERL_VERSION / no-.perlenv create / silent) -> Tasks 4-5.
- Revert on leave (snapshot restore + PERLENV_DEFAULT/off) -> Task 5.
- Allow-list (hash store, changed-hash re-prompt, session declines) ->
  Tasks 3, 5.
- perlenv-init + detector (use/cpanfile/Makefile.PL/dist.ini, highest
  wins, perlbrew normalize) -> Tasks 2, 4.
- Template reminder -> Task 6.
- Files/packaging (perlenv_hook, bashrc, install.sh DOTFILES) -> Task 6.
- Testing harness -> Tasks 1-6.
- Out of scope (full resolver, zsh, pre-commit changes, auto-build) ->
  not implemented, correct.

**Placeholder scan:** No TBD/TODO; every step carries real code.

**Type consistency:** `_perlenv_normalize_version` (Tasks 1-2, 4),
`_perlenv_detect_min_version` (Tasks 2, 4), `_perlenv_parse_version`
(Tasks 1, 5), `_perlenv_allow_check`/`_perlenv_allow_add` (Tasks 3, 5),
`_perlenv_apply`/`_perlenv_revert`/`_perlenv_enter`/`_perlenv_chpwd`
(Task 5) are named consistently across their definitions and call sites.
State variables (`_PERLENV_LAST_PWD`, `_PERLENV_LAST_ROOT`,
`_PERLENV_ACTIVE_ROOT`, the `_PERLENV_SAVED_*` pair, `_PERLENV_DECLINED`)
are read with `:-` defaults everywhere.

**Note on set -e / -u:** `perlenv_hook` deliberately sets neither (it is
sourced into the user's shell). The harness sets `set -u` only; every
hook state read uses `${x:-}` so it is safe. Do not add `set -e`/`set -u`
to `perlenv_hook`.
