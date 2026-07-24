# Pre-commit shellcheck Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the `git/hooks/pre-commit` template lint shell files with
`shellcheck` (falling back to `bash -n`), and stop the override prompts from
hanging when there is no terminal.

**Architecture:** One bash file changes (`git/hooks/pre-commit`) plus a docs
line in `CLAUDE.md`. A tty probe sets an `INTERACTIVE` flag near the top; the
override prompts fail closed when it is unset. A new `validate_bash` function
runs `shellcheck -S warning` when present and `bash -n` when not. Existing
`validate_yaml` / `validate_sql` are fixed to `return` instead of `exit`.

**Tech Stack:** Bash, shellcheck, git hooks. No test framework exists; each task
is verified by running the hook against a throwaway git repo.

## Global Constraints

- shellcheck runs at `-S warning` (real/likely bugs, skips pure style). Copied
  verbatim: `shellcheck -S warning "$filename"`.
- Prompts fail **closed**: when non-interactive, print a notice and `return 1`.
- Functions use `return`, never `exit` (only `typeof`, which runs in `$(...)`,
  may keep `exit`).
- All new messages use the hook's colour vars and format:
  `echo -e "${RED}???${NC} pre-commit: ..."` (RED for prompts/failures, BLUE for
  info, GREEN for success, `${NC}` to reset).
- No `-s bash` flag on shellcheck; let it read the shebang.
- The hook blocks commits on `main`/`master`, so all verification and any
  commits happen on a feature branch.
- Per repo policy, the implementer does **not** commit without the user's
  explicit OK; commit steps below are gated on that approval.

## Verification harness

Every test step builds a throwaway repo with the hook installed, on a branch
that is not `main` (so the branch gate lets checks run). The hook reads staged
files via `git diff --cached`, so no initial commit is needed. Run the hook
directly rather than through `git commit`:

```bash
TMP=$(mktemp -d) && cd "$TMP"
git init -q
git checkout -q -b work
cp /home/mikew/Work/FleetfootMike/dotfiles/git/hooks/pre-commit .git/hooks/
chmod +x .git/hooks/pre-commit
# ... create + `git add` files, then:
setsid -w setsid -w timeout 10 bash .git/hooks/pre-commit </dev/null; echo "exit=$?"
```

**Caution:** run each step's block in the SAME shell as this setup, or
re-create `TMP` first. `$TMP` does not survive across separate shell
invocations, and a later `cd "$TMP"` with `TMP` unset becomes `cd ""` (a
no-op) — leaving you in the real repo, where the steps' `git add` commands
would stage test fixtures into it. Guard every `cd` as `cd "${TMP:?TMP unset}"`
so a lost `TMP` aborts loudly instead of polluting the repo.

`setsid -w` runs the hook in a new session with **no controlling terminal**, so
the hook's `/dev/tty` probe fails and `INTERACTIVE=0` **regardless of where you
run the test** (a plain terminal, otherwise, has a controlling tty and would
send the override tests into the interactive prompt and hang). `timeout` still
guards against a genuine hang. `exit=0` means the hook approved the staged
files; non-zero means it blocked; `exit=124` means it hung (a failure).

---

### Task 1: Terminal probe and exit-to-return fixes

Fixes the two latent bugs so the hook is safe to run headless, before any
shellcheck work. Deliverable: a passing linter no longer aborts the remaining
files, and the override path no longer hangs without a tty.

**Files:**

- Modify: `git/hooks/pre-commit` (lines 13-14 the tty `exec`; `validate_yaml`
  lines 51-68; `validate_sql` lines 70-73)

**Interfaces:**

- Produces: global `INTERACTIVE` (0 or 1), set once near the top before any
  function is called. `validate_bash` in Task 2 reads it.
- Produces: `validate_yaml "$file"` and `validate_sql "$file"` now `return`
  0/1 instead of `exit`.

- [ ] **Step 1: Write the failing test**

Uses the SQL stub (no external deps) followed by a syntactically broken shell
file. Today `validate_sql` calls `exit 0`, which ends the whole hook, so the
broken shell file downstream is never checked:

```bash
TMP=$(mktemp -d) && cd "$TMP"
git init -q && git checkout -q -b work
cp /home/mikew/Work/FleetfootMike/dotfiles/git/hooks/pre-commit .git/hooks/
chmod +x .git/hooks/pre-commit
printf 'SELECT 1;\n' > a.sql
printf '#!/usr/bin/env bash\nif then fi\n' > b.sh   # broken bash syntax
git add a.sql b.sh
setsid -w timeout 10 bash .git/hooks/pre-commit </dev/null; echo "exit=$?"
```

- [ ] **Step 2: Run test to verify it fails**

Run the block above.
Expected (buggy behaviour): output contains `/dev/tty: No such device or
address`, the SQL file is reported, `b.sh` is **never** checked, and
`exit=0` (the commit would be allowed despite broken bash).

- [ ] **Step 3: Implement the terminal probe**

Replace lines 13-14 of `git/hooks/pre-commit`:

```bash
# need tty interaction
exec < /dev/tty
```

with a probe that only redirects when the terminal can actually be opened
(the `/dev/tty` node can exist yet fail to open with `ENXIO`):

```bash
# override prompts need the tty; probe it so a missing terminal (CI, an
# agent, a scripted commit) neither errors here nor hangs the prompts later.
INTERACTIVE=0
if { true < /dev/tty; } 2>/dev/null
then
    exec < /dev/tty
    INTERACTIVE=1
fi
```

- [ ] **Step 4: Implement the validate_yaml fix**

Replace the whole `validate_yaml` function (lines 51-68) with a version that
uses `return`, reads the passed filename (not the global `$file`), and fails
closed when non-interactive:

```bash
function validate_yaml () {
    # requires yamllint
    filename=$1
    if yamllint "$filename"
    then
        return 0
    fi
    # some Ansible and Git YAML has decidedly iffy formatting
    if [ "$INTERACTIVE" != 1 ]
    then
        echo -e "${RED}???${NC} pre-commit: non-interactive, can't ask about this YAML file; treating as failure"
        return 1
    fi
    while true; do
        echo -e -n "${RED}???${NC} pre-commit: Do you wish to commit this YAML file anyway? "; read yn
        case $yn in
            [Yy]* ) return 0 ;;
            [Nn]* ) return 1 ;;
            * ) echo -e "${RED}???${NC} pre-commit: Please answer yes or no.";;
        esac
    done
}
```

- [ ] **Step 5: Implement the validate_sql fix**

Replace `validate_sql` (lines 70-73) so it returns instead of exiting:

```bash
function validate_sql () {
    echo -e "${BLUE}###${NC} pre-commit: Can't validate SQL yet!"
    return 0
}
```

- [ ] **Step 6: Run the test to verify it passes**

Re-run the Step 1 block.
Expected (fixed behaviour): no `/dev/tty` error line; the SQL notice prints;
`b.sh` **is** checked and fails `bash -n`; the failure summary lists `b.sh`;
`exit=1`. (`bash -n` on `b.sh` is still the pre-Task-2 behaviour.)

- [ ] **Step 7: Verify a clean commit still passes**

```bash
cd "$TMP" && git rm -q --cached b.sh && rm b.sh
setsid -w timeout 10 bash .git/hooks/pre-commit </dev/null; echo "exit=$?"
```

Expected: `+++ pre-commit: all files OK` and `exit=0`.

- [ ] **Step 8: Commit** (ask the user for OK first, per repo policy)

```bash
cd /home/mikew/Work/FleetfootMike/dotfiles
git checkout -b precommit-shellcheck
git add git/hooks/pre-commit
git commit -m "Fix pre-commit tty hang and exit-vs-return in validators

Probe /dev/tty before redirecting so the hook is safe non-interactively, and
make validate_yaml/validate_sql return instead of exit so a passing file no
longer aborts checks on the rest."
```

---

### Task 2: shellcheck validation for shell files

Adds the actual shellcheck check with a `bash -n` fallback, wires it into the
`bash` case, and documents the new dependency. Deliverable: staged shell files
are linted by shellcheck when it is installed.

**Prerequisite:** `shellcheck` must be on PATH for Steps 1-6 (`command -v
shellcheck` should succeed). Step 7 deliberately hides it to exercise the
fallback.

**Files:**

- Modify: `git/hooks/pre-commit` (add `validate_bash`; the `bash )` case at
  lines 126-129; the stale comment on line 127)
- Modify: `CLAUDE.md` (the pre-commit dependency list and the `.sh`/bash line)

**Interfaces:**

- Consumes: global `INTERACTIVE` from Task 1.
- Produces: `validate_bash "$file"` returning 0 (clean / overridden) or 1
  (blocked / syntax error).

- [ ] **Step 1: Write the failing test**

A shell file with a genuine **warning-level** shellcheck finding: an unguarded
`cd` (SC2164). This must be warning-level, not info: `-S warning` deliberately
filters info-level checks like SC2086, so an unquoted-variable file would lint
clean and never trigger the block. Task 1's `bash -n` catches neither:

```bash
TMP=$(mktemp -d) && cd "$TMP"
git init -q && git checkout -q -b work
cp /home/mikew/Work/FleetfootMike/dotfiles/git/hooks/pre-commit .git/hooks/
chmod +x .git/hooks/pre-commit
printf '#!/usr/bin/env bash\ncd /tmp\n' > deploy.sh   # SC2164: unguarded cd (warning)
git add deploy.sh
setsid -w timeout 10 bash .git/hooks/pre-commit </dev/null; echo "exit=$?"
```

- [ ] **Step 2: Run test to verify it fails**

Run the block above.
Expected (pre-implementation): `bash -n` finds no syntax error, output says
`Bash syntax OK`, `exit=0` (the SC2164 warning is not caught).

- [ ] **Step 3: Add the validate_bash function**

Add this function next to the other validators (e.g. after `validate_sql`):

```bash
function validate_bash () {
    filename=$1
    if ! command -v shellcheck >/dev/null 2>&1
    then
        echo -e "${BLUE}###${NC} pre-commit: shellcheck not found, falling back to bash -n"
        bash -n "$filename"
        return $?
    fi
    if shellcheck -S warning "$filename"
    then
        return 0
    fi
    # shellcheck flagged something at warning level or above
    if [ "$INTERACTIVE" != 1 ]
    then
        echo -e "${RED}???${NC} pre-commit: non-interactive, can't ask about this shell file; treating as failure"
        return 1
    fi
    while true; do
        echo -e -n "${RED}???${NC} pre-commit: Do you wish to commit this shell file anyway? "; read yn
        case $yn in
            [Yy]* ) return 0 ;;
            [Nn]* ) return 1 ;;
            * ) echo -e "${RED}???${NC} pre-commit: Please answer yes or no.";;
        esac
    done
}
```

- [ ] **Step 4: Wire it into the bash case**

Replace the `bash )` case (lines 126-129):

```bash
        bash )
            # note this WILL NOT check external commands missing from your PATH
            bash -n $file && echo "Bash syntax OK" || BAD=true
            ;;
```

with:

```bash
        bash )
            # shellcheck (warns on quoting, unset vars, etc.) when available,
            # otherwise a bare bash -n syntax check
            validate_bash "$file" && echo "Bash syntax OK" || BAD=true
            ;;
```

- [ ] **Step 5: Run the warning test to verify it passes**

Re-run the Step 1 block.
Expected: shellcheck reports SC2164, the non-interactive branch prints
`... treating as failure`, the summary lists `deploy.sh`, `exit=1`.

- [ ] **Step 6: Verify a clean shell file passes**

```bash
cd "$TMP" && git rm -q --cached deploy.sh && rm deploy.sh
printf '#!/usr/bin/env bash\ncd /tmp || exit 1\n' > deploy.sh   # guarded, clean
git add deploy.sh
setsid -w timeout 10 bash .git/hooks/pre-commit </dev/null; echo "exit=$?"
```

Expected: `Bash syntax OK`, `+++ pre-commit: all files OK`, `exit=0`.

- [ ] **Step 7: Verify the shellcheck-missing fallback**

Simulate shellcheck being absent by running the hook with a PATH that omits it
but still has the binaries the hook needs:

```bash
cd "$TMP"
SHIM=$(mktemp -d)
for c in git bash head sed basename tr cat env timeout; do
    ln -s "$(command -v $c)" "$SHIM/$c"
done   # deliberately NOT linking shellcheck
printf '#!/usr/bin/env bash\nif then fi\n' > broken.sh
git add broken.sh
PATH="$SHIM" setsid -w timeout 10 bash .git/hooks/pre-commit </dev/null; echo "exit=$?"
```

Expected: `shellcheck not found, falling back to bash -n`, `bash -n` reports the
syntax error, `exit=1`. Then confirm a clean file passes the fallback:

```bash
cd "$TMP" && git rm -q --cached broken.sh && rm broken.sh
printf '#!/usr/bin/env bash\necho hi\n' > ok.sh
git add ok.sh
PATH="$SHIM" setsid -w timeout 10 bash .git/hooks/pre-commit </dev/null; echo "exit=$?"
```

Expected: fallback notice, `Bash syntax OK`, `exit=0`.

- [ ] **Step 8: Manually verify the interactive override**

This is the one path the headless steps can't cover: the `INTERACTIVE=1`
prompt. Run it yourself in a real terminal (no `setsid`, so the hook gets a
controlling tty), staging the SC2164 warning file again:

```bash
cd "$TMP" && git rm -q --cached ok.sh && rm ok.sh
printf '#!/usr/bin/env bash\ncd /tmp\n' > deploy.sh
git add deploy.sh
timeout 30 bash .git/hooks/pre-commit   # no </dev/null, no setsid
```

Expected: shellcheck reports SC2164, then the prompt
`Do you wish to commit this shell file anyway?`. Type `n` → hook exits non-zero
(blocked). Repeat and type `y` → hook prints `all files OK` and exits 0.

- [ ] **Step 9: Update CLAUDE.md**

In `CLAUDE.md`, change the `.sh` / bash validation line under the pre-commit
section from:

```markdown
  - `.sh` / bash → `bash -n`
```

to:

```markdown
  - `.sh` / bash → `shellcheck -S warning` (falls back to `bash -n` if
    shellcheck is missing)
```

and add `shellcheck` to the assumed-on-PATH list:

```markdown
- Assumes on PATH: `shellcheck`, `yamllint`, `markdownlint`, `json_pp`,
  `carton`, `docker`, `mysql`.
```

Then confirm CLAUDE.md still lints clean (the hook markdownlints it on commit):

```bash
cd /home/mikew/Work/FleetfootMike/dotfiles
markdownlint CLAUDE.md && echo OK
```

Expected: `OK`.

- [ ] **Step 10: Commit** (ask the user for OK first, per repo policy)

```bash
cd /home/mikew/Work/FleetfootMike/dotfiles
git add git/hooks/pre-commit CLAUDE.md
git commit -m "Lint shell with shellcheck in pre-commit, fall back to bash -n

Add validate_bash: shellcheck -S warning when installed, bash -n otherwise.
Document the new shellcheck dependency in CLAUDE.md."
```

---

## Post-implementation note

This edits the **tracked** `git/hooks/pre-commit`, not the copy installed at
`.git/hooks/pre-commit` in this repo. To use the new behaviour on this repo's
own commits, the updated hook must be copied into `.git/hooks/` manually (the
repo has no auto-wiring). That install step is out of scope for this plan.

## Self-Review

**Spec coverage:**

- shellcheck -S warning + prompt-to-override → Task 2 Steps 3-5.
- bash -n fallback when shellcheck absent → Task 2 Step 3, verified Step 7.
- No `-s bash` flag → Task 2 Step 3 (none used).
- exit→return in validate_yaml/validate_sql → Task 1 Steps 4-5.
- INTERACTIVE probe + fail-closed prompts → Task 1 Step 3, both prompt functions.
- Coloured message style → all new `echo -e` lines use RED/BLUE + `${NC}`.
- CLAUDE.md dependency note → Task 2 Step 9.
- Interactive override path → Task 2 Step 8 (manual).
- Testing scenarios (clean pass, warning blocks headless, missing-shellcheck
  fallback, exit-to-return) → covered across both tasks' test steps.

**Placeholder scan:** none — every code and command step is complete.

**Type consistency:** `validate_bash`, `validate_yaml`, `validate_sql`, and the
global `INTERACTIVE` are named consistently across both tasks.
