# Dotfiles install script Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps
> use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a tracked `install.sh` that deploys the repo's config files
into `$HOME` as dot-prefixed copies (merging on conflict) and reports
missing prereqs with per-tool install recipes.

**Architecture:** One self-locating bash script at the repo root, built
from small functions (`detect_pkg_mgr`, `check_prereqs`, `deploy_file`,
`deploy_all`, `main`). A source guard lets a test harness load the
functions without running `main`, so prereq logic is unit-tested and the
deploy path is integration-tested against a throwaway `--home` dir.

**Tech Stack:** bash (portable to macOS's bash 3.2), shellcheck,
markdownlint, the repo's own pre-commit hook.

## Global Constraints

Every task's requirements implicitly include these:

- Deploy by **copy**, never symlink. Home files are independent
  snapshots.
- `perlenv` is **never** deployed to `~/.perlenv`. It is not in the
  in-scope list.
- Prereq check is **report only**: no sudo, no install ever executed.
- Perl version floor for the prereq check: **perlbrew perl >= 5.36.0**.
- Package managers supported: `apt-get` and `brew`. Anything else is
  report-only with no recipes.
- Portable bash: **no `declare -A`** (macOS ships bash 3.2). Use indexed
  arrays and `case`.
- `install.sh` must pass `shellcheck -S warning` (the repo's pre-commit
  hook lints it on commit).
- `main`/`master` are blocked for direct commits by the hook. All work
  lands on the `dotfiles-install-script` branch, one commit per task.
- Commit messages end with:
  `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`
- Ask the user before every commit. Do not commit without explicit OK.

## File Structure

- Create: `install.sh` (repo root) — the whole deploy + prereq script.
- Create: `test/install_test.sh` — tracked test harness (sources
  `install.sh` for unit tests, invokes it for integration tests).
- Modify: `CLAUDE.md` — replace the "no install/bootstrap script" note
  and record the copy-based deploy method; adjust the "No CI or tests"
  line to mention `test/install_test.sh`.
- Modify: `README.md` — one line pointing at `install.sh`.

`install.sh` is intentionally one file: it is small, and its functions
share the colour helpers, counters, and the in-scope list. Splitting it
would spread that shared state across files for no gain.

---

### Task 1: Script skeleton, arg parsing, help, source guard

**Files:**

- Create: `install.sh`
- Test: `test/install_test.sh`

**Interfaces:**

- Consumes: nothing.
- Produces: `main()` (arg parser), `usage()`, the globals `DEST_HOME`,
  `DO_CHECK`, `DO_DEPLOY`, `REPO_ROOT`, and the source guard
  `if [ "${BASH_SOURCE[0]}" = "${0}" ]; then main "$@"; fi`. Later tasks
  add `check_prereqs` (Task 3) and `deploy_all` (Task 2) and wire them
  into `main`.

- [ ] **Step 1: Write the failing test**

Create `test/install_test.sh`:

```bash
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
# sourcing must NOT run main (no output)
srcout="$( . "$SCRIPT"; echo "SENTINEL" )"
[ "$srcout" = "SENTINEL" ]; check "sourcing does not run main" $?

echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
```

- [ ] **Step 2: Run the harness to verify it fails**

Run: `bash test/install_test.sh`
Expected: FAIL (`install.sh` does not exist yet).

- [ ] **Step 3: Write the skeleton**

Create `install.sh`:

```bash
#!/usr/bin/env bash
#
# install.sh - deploy this repo's dotfiles into $HOME and check prereqs.
# Config files are copied (never symlinked) with a leading dot added.
set -euo pipefail

GREEN=$'\033[0;32m'; BLUE=$'\033[0;34m'; YELLOW=$'\033[1;33m'
RED=$'\033[0;31m'; NC=$'\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"

DEST_HOME="${HOME}"
DO_CHECK=1
DO_DEPLOY=1

info() { echo "${BLUE}>>>${NC} install: $*"; }
ok()   { echo "${GREEN}+++${NC} install: $*"; }
warn() { echo "${YELLOW}!!!${NC} install: $*"; }

usage() {
    cat <<EOF
Usage: install.sh [options]
  --check-only    only run the prereq check
  --deploy-only   only deploy dotfiles (skip the prereq check)
  --home <dir>    deploy into <dir> instead of \$HOME (for testing)
  -h, --help      show this help

Environment:
  DOTFILES_MERGE        merge command for conflicts (default: vimdiff)
  DOTFILES_INTERACTIVE  set to 1 or 0 to force or skip the merge prompt
                        (default: auto-probe for a tty)
EOF
}

main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --check-only)  DO_DEPLOY=0 ;;
            --deploy-only) DO_CHECK=0 ;;
            --home)        shift; DEST_HOME="${1:?--home needs a dir}" ;;
            -h|--help)     usage; exit 0 ;;
            *) echo "${RED}install.sh: unknown option '$1'${NC}" >&2
               usage >&2; exit 2 ;;
        esac
        shift
    done
    # phases wired in later tasks
    return 0
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
```

- [ ] **Step 4: Run the harness to verify Task 1 cases pass**

Run: `bash test/install_test.sh`
Expected: the four Task 1 cases print `ok`.

- [ ] **Step 5: shellcheck**

Run: `shellcheck -S warning install.sh test/install_test.sh`
Expected: no output. (`RED` is used in `main`; unused-var warnings mean
a colour must be removed or used.)

- [ ] **Step 6: Commit (after user OK)**

```bash
git add install.sh test/install_test.sh
git commit  # message: "Add install.sh skeleton with arg parsing and tests"
```

---

### Task 2: Deploy dotfiles (copy, merge on conflict)

**Files:**

- Modify: `install.sh`
- Test: `test/install_test.sh`

**Interfaces:**

- Consumes: `REPO_ROOT`, `DEST_HOME`, `info/ok/warn` from Task 1.
- Produces: `deploy_file <name>`, `deploy_all`, the `DOTFILES` array, the
  `is_interactive`/`tool_present` helpers, and the counters `INSTALLED`,
  `UPTODATE`, `MERGED`, `SKIPPED`. `tool_present` is reused by Task 3.

- [ ] **Step 1: Write the failing tests**

Append to `test/install_test.sh` before the summary line:

```bash
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
```

- [ ] **Step 2: Run to verify the new cases fail**

Run: `bash test/install_test.sh`
Expected: the Task 2 cases FAIL (`deploy_all` is a no-op).

- [ ] **Step 3: Implement the deploy functions**

Add to `install.sh` above `main()`:

```bash
# In-scope dotfiles: each is copied to $DEST_HOME/.<name>. Deliberately
# excludes perlenv (per-repo) and the pre-commit hook template.
DOTFILES=(bashrc bash_profile bash_aliases screenrc markdownlint.json)

INSTALLED=0; UPTODATE=0; MERGED=0; SKIPPED=0
DOTFILES_MERGE="${DOTFILES_MERGE:-vimdiff}"

tool_present() { command -v "$1" >/dev/null 2>&1; }

is_interactive() {
    if [ -n "${DOTFILES_INTERACTIVE:-}" ]; then
        [ "$DOTFILES_INTERACTIVE" = 1 ]
        return
    fi
    { true < /dev/tty; } 2>/dev/null
}

deploy_file() {
    local name="$1" src="$REPO_ROOT/$name" target="$DEST_HOME/.$name"
    if [ ! -e "$target" ]; then
        cp "$src" "$target"; ok "installed .$name"
        INSTALLED=$((INSTALLED + 1))
    elif cmp -s "$src" "$target"; then
        info ".$name up to date"; UPTODATE=$((UPTODATE + 1))
    else
        local mergecmd="${DOTFILES_MERGE%% *}"
        if ! tool_present "$mergecmd"; then
            warn ".$name differs; merge tool '$mergecmd' not found, skipping"
            SKIPPED=$((SKIPPED + 1))
        elif ! is_interactive; then
            warn ".$name differs; no tty, skipping (run interactively to merge)"
            SKIPPED=$((SKIPPED + 1))
        else
            info "merging .$name with $DOTFILES_MERGE"
            # shellcheck disable=SC2086
            $DOTFILES_MERGE "$target" "$src"
            ok "merged .$name"; MERGED=$((MERGED + 1))
        fi
    fi
}

deploy_all() {
    if [ ! -d "$DEST_HOME" ]; then
        echo "${RED}install.sh: home '$DEST_HOME' is not a directory${NC}" >&2
        exit 1
    fi
    info "deploying dotfiles into $DEST_HOME"
    local name
    for name in "${DOTFILES[@]}"; do
        deploy_file "$name"
    done
    ok "deploy: $INSTALLED installed, $MERGED merged, $UPTODATE up to date, $SKIPPED skipped"
}
```

Wire into `main` by replacing the `# phases wired in later tasks`
comment with:

```bash
    if [ "$DO_DEPLOY" = 1 ]; then deploy_all; fi
```

- [ ] **Step 4: Run to verify Task 2 cases pass**

Run: `bash test/install_test.sh`
Expected: the Task 2 cases print `ok`.

- [ ] **Step 5: shellcheck**

Run: `shellcheck -S warning install.sh test/install_test.sh`
Expected: no output.

- [ ] **Step 6: Commit (after user OK)**

```bash
git add install.sh test/install_test.sh
git commit  # "Deploy dotfiles by copy with merge-on-conflict"
```

---

### Task 3: Prereq check with per-tool recipes

**Files:**

- Modify: `install.sh`
- Test: `test/install_test.sh`

**Interfaces:**

- Consumes: `tool_present` (Task 2), `info/ok/warn`.
- Produces: `detect_pkg_mgr` (sets `PKG` to `apt`/`brew`/`none`),
  `prereq_present <tool>`, `perl_ok`, `label_for <tool>`,
  `recipe_for <tool>`, `check_prereqs`, and the `CORE_PREREQS` /
  `OPTIONAL_PREREQS` arrays. `prereq_present` and `perl_ok` are the
  overridable seams the unit tests stub.

- [ ] **Step 1: Write the failing unit tests**

Append to `test/install_test.sh` before the summary line:

```bash
# --- Task 3: prereqs (unit tests via sourcing) ---
# all-missing, apt: every core tool prints its apt/special recipe
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
picked="$( . "$SCRIPT"; tool_present() { [ "$1" = apt-get ]; }; \
    detect_pkg_mgr; echo "$PKG" )"
[ "$picked" = apt ]; check "detect_pkg_mgr picks apt" $?
```

- [ ] **Step 2: Run to verify the new cases fail**

Run: `bash test/install_test.sh`
Expected: Task 3 cases FAIL (`check_prereqs` undefined).

- [ ] **Step 3: Implement the prereq functions**

Add to `install.sh` above `main()`:

```bash
# Core prereqs in dependency order (perlbrew -> perl -> cpanm -> carton;
# npm -> markdownlint). perl536 is the >= 5.36.0 check.
CORE_PREREQS=(perlbrew perl536 cpanm carton screen shellcheck yamllint \
    npm markdownlint)
OPTIONAL_PREREQS=(docker mysql json_pp)

PKG=none

detect_pkg_mgr() {
    if tool_present apt-get; then PKG=apt
    elif tool_present brew; then PKG=brew
    else PKG=none; fi
}

perl_ok() {
    tool_present perl && perl -e 'require 5.036;' >/dev/null 2>&1
}

prereq_present() {
    case "$1" in
        perl536) perl_ok ;;
        *)       tool_present "$1" ;;
    esac
}

label_for() {
    case "$1" in
        perl536) echo "perl >= 5.36.0" ;;
        *)       echo "$1" ;;
    esac
}

# Print the install recipe for a tool, honouring $PKG.
recipe_for() {
    local tool="$1" apt="" brew="" special=""
    case "$tool" in
        perlbrew) special='\curl -L https://install.perlbrew.pl | bash' ;;
        perl536)  special='perlbrew install perl-5.36.0' ;;
        cpanm)    special='perlbrew install-cpanm'
                  apt='sudo apt-get install -y cpanminus'
                  brew='brew install cpanminus' ;;
        carton)   special='cpanm Carton' ;;
        screen)   apt='sudo apt-get install -y screen'
                  brew='brew install screen' ;;
        shellcheck) apt='sudo apt-get install -y shellcheck'
                  brew='brew install shellcheck' ;;
        yamllint) apt='sudo apt-get install -y yamllint'
                  brew='brew install yamllint' ;;
        npm)      apt='sudo apt-get install -y nodejs npm'
                  brew='brew install node' ;;
        markdownlint) special='npm install -g markdownlint-cli' ;;
        docker)   apt='sudo apt-get install -y docker.io'
                  brew='brew install --cask docker' ;;
        mysql)    apt='sudo apt-get install -y mariadb-client'
                  brew='brew install mysql-client' ;;
        json_pp)  special='ships with perl' ;;
        *)        special='(no recipe)' ;;
    esac
    if [ -n "$special" ]; then
        printf '%s' "$special"
        if [ "$PKG" = apt ]  && [ -n "$apt" ];  then printf '  (or %s)' "$apt"; fi
        if [ "$PKG" = brew ] && [ -n "$brew" ]; then printf '  (or %s)' "$brew"; fi
    elif [ "$PKG" = apt ]  && [ -n "$apt" ];  then printf '%s' "$apt"
    elif [ "$PKG" = brew ] && [ -n "$brew" ]; then printf '%s' "$brew"
    else printf '(install manually)'
    fi
}

check_prereqs() {
    detect_pkg_mgr
    info "checking prereqs (package manager: $PKG)"
    local missing=0 tool
    for tool in "${CORE_PREREQS[@]}"; do
        if prereq_present "$tool"; then
            ok "$(label_for "$tool") present"
        else
            missing=$((missing + 1))
            if [ "$PKG" = none ]; then
                warn "$(label_for "$tool") MISSING"
            else
                warn "$(label_for "$tool") MISSING -> $(recipe_for "$tool")"
            fi
        fi
    done
    for tool in "${OPTIONAL_PREREQS[@]}"; do
        if prereq_present "$tool"; then
            ok "$(label_for "$tool") present (optional)"
        elif [ "$PKG" = none ]; then
            warn "$(label_for "$tool") missing (optional)"
        else
            warn "$(label_for "$tool") missing (optional) -> $(recipe_for "$tool")"
        fi
    done
    if [ "$missing" -eq 0 ]; then
        ok "all core prereqs present"
    else
        warn "$missing core prereq(s) missing"
    fi
}
```

Wire into `main` above the deploy line:

```bash
    if [ "$DO_CHECK" = 1 ]; then check_prereqs; fi
```

- [ ] **Step 4: Run to verify Task 3 cases pass**

Run: `bash test/install_test.sh`
Expected: Task 3 cases print `ok`.

- [ ] **Step 5: shellcheck**

Run: `shellcheck -S warning install.sh test/install_test.sh`
Expected: no output.

- [ ] **Step 6: Commit (after user OK)**

```bash
git add install.sh test/install_test.sh
git commit  # "Check prereqs and print per-tool install recipes"
```

---

### Task 4: Orchestration checks, docs, final lint

**Files:**

- Modify: `install.sh` (only if orchestration test reveals a gap)
- Modify: `CLAUDE.md`, `README.md`
- Test: `test/install_test.sh`

**Interfaces:**

- Consumes: `main`, `check_prereqs`, `deploy_all`.
- Produces: no new functions; verifies the flag gating end to end.

- [ ] **Step 1: Write the failing orchestration tests**

Append to `test/install_test.sh` before the summary line:

```bash
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
```

- [ ] **Step 2: Run the full harness**

Run: `bash test/install_test.sh`
Expected: all cases pass. If a gating case fails, fix `main`'s
`if [ "$DO_CHECK" ... ]` / `if [ "$DO_DEPLOY" ... ]` guards and re-run.

- [ ] **Step 3: Update the docs**

In `CLAUDE.md`, replace the bullet that begins "There is **no
install/bootstrap script**..." with:

```markdown
- `install.sh` (repo root) deploys the config files into `$HOME` by
  **copy** (adding the leading dot), launching a merge tool (`vimdiff`
  by default, override with `$DOTFILES_MERGE`) when a target already
  exists and differs. `perlenv` is never deployed. It also runs a
  report-only prereq check that prints per-tool install commands but
  never installs anything. Run `install.sh --help` for options.
  `$DOTFILES_MERGE` picks the merge tool and `$DOTFILES_INTERACTIVE`
  (1 or 0) forces or skips the merge prompt.
```

Update the "No CI or tests for this repo itself." line to:

```markdown
- No CI. The one test is `test/install_test.sh` (run
  `bash test/install_test.sh`), covering `install.sh`.
```

In `README.md`, add a line:

```markdown
Run `./install.sh` to deploy these into your home directory and check
prerequisites (`./install.sh --help` for options).
```

- [ ] **Step 4: Final full lint**

Run: `shellcheck -S warning install.sh test/install_test.sh` and
`markdownlint CLAUDE.md README.md docs/superpowers/plans/2026-07-25-dotfiles-install-script.md`
Expected: both clean.

- [ ] **Step 5: Manual smoke test**

Run: `./install.sh --check-only` in a real terminal.
Expected: a readable prereq report against the actual machine, recipes
only for whatever is missing, no side effects.

- [ ] **Step 6: Commit (after user OK)**

```bash
git add install.sh test/install_test.sh CLAUDE.md README.md
git commit  # "Wire install.sh phases and document it"
```

---

## Self-Review

**Spec coverage:**

- Scope / in-scope table -> `DOTFILES` array (Task 2), perlenv exclusion
  tested (Task 2 Step 1).
- Copy + merge-on-conflict, vimdiff default, `$DOTFILES_MERGE` override,
  headless skip, idempotent, `--home` -> Task 2.
- Prereq report-only, pkg-mgr detect, per-tool recipes, dependency
  order, optional tools -> Task 3.
- Structure/flags (`--check-only`, `--deploy-only`, `--home`, `--help`),
  self-locating, coloured prefixes, end summary, `set -euo pipefail`,
  shellcheck-clean -> Tasks 1, 2, 4.
- Testing harness with the five listed cases -> Tasks 2-4 (an extra
  headless-skip case is added for the merge gate).
- Out-of-scope items are simply not implemented (no sudo/install, hook
  not deployed).

**Placeholder scan:** No TBD/TODO; every code and test step carries real
content.

**Type consistency:** `tool_present` is defined in Task 2 and reused in
Task 3. `prereq_present`/`perl_ok`/`label_for`/`recipe_for` are named
consistently across Task 3 code and its tests. Counters
(`INSTALLED`/`UPTODATE`/`MERGED`/`SKIPPED`) are declared once in Task 2
and only incremented via `X=$((X + 1))` to stay `set -e` safe.

**Note on `set -e` and counters:** `((X++))` returns non-zero when the
pre-increment value is 0, which would abort under `set -euo pipefail`.
Every counter uses `X=$((X + 1))` instead. Do not "simplify" back to
`((X++))`.
