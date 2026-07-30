# install.sh per-hunk merge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps
> use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `install.sh`'s vimdiff merge step with a built-in
per-hunk `[y]/[n]/[e]/[q]` prompt, where `e` opens `$EDITOR` on a file
carrying git-style conflict markers.

**Architecture:** Two new shell functions in `install.sh`. `_merge_editor`
renders the two file versions as one conflict-marked file (via GNU `diff`
group-format) and opens it in `${EDITOR:-vi}`, adopting the result only if
every marker was resolved. `merge_file` walks a unified diff hunk by hunk,
applies the accepted hunks with `patch` to a copy of the target, and hands
off to `_merge_editor` on `e`. `deploy_file`'s merge branch calls
`merge_file` instead of launching `$DOTFILES_MERGE`.

**Tech Stack:** bash (3.2-safe), GNU `diff`, `patch`, POSIX text tools.
Tests are the existing `test/install_test.sh` harness style (source or
invoke `install.sh`, drive throwaway files, stub external programs).

## Global Constraints

- Target bash 3.2; no bash-4-only features (associative arrays, etc.).
- `install.sh` runs under `set -euo pipefail`. Any pipeline whose left
  side may exit non-zero (notably `diff`, which returns 1 when files
  differ) MUST end with `|| true`, or the script aborts.
- `shellcheck -S warning` must stay clean on `install.sh`.
- Merge deps are GNU `diff` (for `--*-group-format`) and `patch`. If
  either is absent, the merge branch warns and skips rather than failing.
- Conflict markers are exactly `<<<<<<< yours (.<name>)`, `=======`,
  `>>>>>>> repo`. "Unresolved" means a surviving line that starts with
  `<<<<<<<` or `>>>>>>>` (each followed by a space) or is exactly
  `=======`. The grep for this is `'^(<<<<<<< |>>>>>>> |=======$)'`.
- Answers for the per-hunk prompt are read from `$DOTFILES_INPUT` (default
  `/dev/tty`). This is an internal test seam, not documented in `--help`.
- The editor is `${EDITOR:-vi}`. `DOTFILES_MERGE` is removed entirely.
- Counters `MERGED` / `SKIPPED` are script globals; the new functions
  update them directly. A file that changes counts as merged; unchanged
  (all-no, quit-with-none, patch failure, unresolved markers) counts as
  skipped.
- Every new function must return 0 on all paths (end on `rm`/assignment),
  so `set -e` does not abort `deploy_file` when the function is called
  outside a conditional.
- Implementer subagents do NOT commit. Each task ends by running the suite
  and shellcheck, then stopping for the controller to review and gate the
  commit.

---

## File Structure

- `install.sh`: add `_merge_editor` and `merge_file`; rewire the
  `deploy_file` merge branch; drop `DOTFILES_MERGE`; update `usage()`.
- `test/install_test.sh`: add direct-call tests for both functions;
  replace the old stub-merge integration case; add a diff/patch-missing
  skip case.

No new files.

---

### Task 1: `_merge_editor` (the `$EDITOR` fallback)

**Files:**

- Modify: `install.sh` (add the `_merge_editor` function; place it above
  `deploy_file`, after the `is_interactive` helper)
- Test: `test/install_test.sh` (new block after the existing Task 2
  deploy tests)

**Interfaces:**

- Consumes: globals `MERGED`, `SKIPPED`; helpers `ok`, `warn`. Env
  `EDITOR`.
- Produces: `_merge_editor <name> <src> <target>`, which renders `target`
  (yours) vs `src` (repo) as one conflict-marked file, opens it in
  `${EDITOR:-vi}`, and if no marker survives copies the result over
  `target` and does `MERGED++`; otherwise warns and does `SKIPPED++`.
  Returns 0. `merge_file` (Task 2) calls this for `e`.

- [ ] **Step 1: Write the failing tests**

Add to `test/install_test.sh`, after the Task 2 deploy block (before the
Task 3 prereq block). This defines two stub editors reused later:

```bash
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash test/install_test.sh`
Expected: the three new checks FAIL (function `_merge_editor` not defined,
so the target is never changed / not left correct). Prior checks still
pass.

- [ ] **Step 3: Implement `_merge_editor`**

Add to `install.sh` (after `is_interactive`, before `deploy_file`):

```bash
# _merge_editor <name> <src> <target>
# Render target (yours) vs src (repo) as one git-style conflict-marked
# file, open it in $EDITOR, and adopt the result only if every marker was
# resolved. Updates the global MERGED / SKIPPED counters. Returns 0.
_merge_editor() {
    local name="$1" src="$2" target="$3"
    local nl=$'\n' tmp og ng cg
    tmp="$(mktemp)"
    og="<<<<<<< yours (.$name)$nl%<=======$nl>>>>>>> repo$nl"
    ng="<<<<<<< yours (.$name)$nl=======$nl%>>>>>>>> repo$nl"
    cg="<<<<<<< yours (.$name)$nl%<=======$nl%>>>>>>>> repo$nl"
    diff --old-group-format="$og" --new-group-format="$ng" \
         --changed-group-format="$cg" --unchanged-group-format='%=' \
         "$target" "$src" > "$tmp" 2>/dev/null || true
    "${EDITOR:-vi}" "$tmp" || true
    if grep -qE '^(<<<<<<< |>>>>>>> |=======$)' "$tmp"; then
        warn ".$name: conflict markers unresolved, kept unchanged"
        SKIPPED=$((SKIPPED + 1))
    else
        cp "$tmp" "$target"; ok "merged .$name"; MERGED=$((MERGED + 1))
    fi
    rm -f "$tmp"
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash test/install_test.sh`
Expected: all checks PASS, including the three new ones.

- [ ] **Step 5: Shellcheck**

Run: `shellcheck -S warning install.sh test/install_test.sh`
Expected: clean (no warnings). If SC flags the `%>>>>>>>>` literal or the
group-format strings, they are correct as written; only suppress with a
scoped `# shellcheck disable=` plus a one-line reason if genuinely needed.

- [ ] **Step 6: Stop for review**

Do NOT commit. Report the diff and the passing suite + shellcheck output;
the controller reviews and gates the commit.

---

### Task 2: `merge_file` (per-hunk prompt loop)

**Files:**

- Modify: `install.sh` (add `merge_file` directly below `_merge_editor`)
- Test: `test/install_test.sh` (new block after the Task 1 merge block)

**Interfaces:**

- Consumes: `_merge_editor` (Task 1); globals `MERGED`, `SKIPPED`; helpers
  `ok`, `warn`, `info`. Env `DOTFILES_INPUT` (default `/dev/tty`).
- Produces: `merge_file <name> <src> <target>`, which walks the unified
  diff of `target` (yours) toward `src` (repo) hunk by hunk, prompting
  `[y]es/[n]o/[e]dit/[q]uit`. Accepted hunks apply with `patch` to a copy
  of `target` that replaces it on success (`MERGED++`); `e` hands off to
  `_merge_editor`; nothing accepted, or a failed patch, leaves `target`
  unchanged (`SKIPPED++`). Returns 0. `deploy_file` (Task 3) calls this.

- [ ] **Step 1: Write the failing tests**

Add to `test/install_test.sh`, immediately after the Task 1 merge block
(so `resolve_ed` is already defined):

```bash
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash test/install_test.sh`
Expected: the five new checks FAIL (`merge_file` not defined). Earlier
checks still pass.

- [ ] **Step 3: Implement `merge_file`**

Add to `install.sh`, directly below `_merge_editor`:

```bash
# merge_file <name> <src> <target>
# Walk the diff of target (yours) -> src (repo) hunk by hunk, prompting
# [y]es/[n]o/[e]dit/[q]uit. Accepted hunks are applied with patch to a
# copy of the target, which replaces it only on success. 'e' hands off to
# _merge_editor. Answers come from $DOTFILES_INPUT (default /dev/tty).
# Updates the global MERGED / SKIPPED counters. Returns 0.
merge_file() {
    local name="$1" src="$2" target="$3"
    local input="${DOTFILES_INPUT:-/dev/tty}"
    local tmpdir; tmpdir="$(mktemp -d)"

    diff -u "$target" "$src" | awk -v dir="$tmpdir" '
        /^--- / && n==0 { print > (dir "/header"); next }
        /^\+\+\+ / && n==0 { print >> (dir "/header"); next }
        /^@@ / { n++; hf = sprintf("%s/hunk.%03d", dir, n); print > hf; next }
        n > 0 { print >> hf }
    ' || true

    info "merging .$name (per hunk)"
    local accepted="$tmpdir/accepted.patch"
    if [ ! -f "$tmpdir/header" ]; then
        warn ".$name: no diff header, kept unchanged"
        SKIPPED=$((SKIPPED + 1)); rm -rf "$tmpdir"; return 0
    fi
    cp "$tmpdir/header" "$accepted"

    if ! exec 3< "$input"; then
        warn ".$name: cannot read answers, kept unchanged"
        SKIPPED=$((SKIPPED + 1)); rm -rf "$tmpdir"; return 0
    fi
    local hf ans any=0 editmode=0
    for hf in "$tmpdir"/hunk.*; do
        [ -e "$hf" ] || break
        cat "$hf"
        printf 'Apply this hunk? [y]es / [n]o / [e]dit / [q]uit '
        IFS= read -r ans <&3 || ans=""
        ans="$(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]' | cut -c1)"
        case "$ans" in
            y) cat "$hf" >> "$accepted"; any=1 ;;
            e) editmode=1; break ;;
            q) break ;;
            *) : ;;
        esac
    done
    exec 3<&-

    if [ "$editmode" = 1 ]; then
        rm -rf "$tmpdir"; _merge_editor "$name" "$src" "$target"; return 0
    fi
    if [ "$any" = 1 ]; then
        local copy="$tmpdir/copy"; cp "$target" "$copy"
        if patch -s "$copy" < "$accepted" >/dev/null 2>&1; then
            cp "$copy" "$target"; ok "merged .$name"; MERGED=$((MERGED + 1))
        else
            warn ".$name: patch failed, kept unchanged"
            SKIPPED=$((SKIPPED + 1))
        fi
    else
        info ".$name kept unchanged"; SKIPPED=$((SKIPPED + 1))
    fi
    rm -rf "$tmpdir"; return 0
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash test/install_test.sh`
Expected: all checks PASS, including the five new ones.

- [ ] **Step 5: Shellcheck**

Run: `shellcheck -S warning install.sh test/install_test.sh`
Expected: clean. If SC2129 fires on the `cp header` + loop-append to
`$accepted`, it is a false positive here (the appends are in a loop);
suppress with a scoped `# shellcheck disable=SC2129` and a one-line note.

- [ ] **Step 6: Stop for review**

Do NOT commit. Report the diff and passing suite + shellcheck; controller
gates the commit.

---

### Task 3: Wire `deploy_file`, remove `DOTFILES_MERGE`, integration test

**Files:**

- Modify: `install.sh` (merge branch of `deploy_file`; delete the
  `DOTFILES_MERGE` default line; update `usage()`)
- Modify: `test/install_test.sh` (replace the old stub-merge case; add a
  diff/patch-missing skip case; remove the now-unused `stub_merge`)

**Interfaces:**

- Consumes: `merge_file` (Task 2), `is_interactive`, `tool_present`.
- Produces: no new functions. `deploy_file`'s merge branch now routes
  through `merge_file`; `DOTFILES_MERGE` no longer exists.

- [ ] **Step 1: Update the integration tests (failing)**

In `test/install_test.sh`:

Delete the `stub_merge` definition (the `stub_merge="$(mktemp)" ...`
heredoc block) and the old "differing target + interactive + stub merge"
case (the three lines ending `check "differing target invokes merge" $?`).

Replace that case with an all-yes drive through the real `main`:

```bash
# differing target + interactive + all-yes -> becomes the repo version
printf 'local change\n' > "$th/.bash_aliases"
ans="$(mktemp)"; yes y | head -n 40 > "$ans"
DOTFILES_INTERACTIVE=1 DOTFILES_INPUT="$ans" \
    bash "$SCRIPT" --deploy-only --home "$th" >/dev/null 2>&1
cmp -s "$HERE/bash_aliases" "$th/.bash_aliases"
check "differing target merges to repo version (per-hunk yes)" $?
```

Add, just below the existing "headless differ is not clobbered" case, a
diff/patch-missing skip case:

```bash
# merge deps missing -> differ is skipped, not clobbered
th_np="$(mktemp -d)"; printf 'keep me\n' > "$th_np/.bashrc"
# shellcheck disable=SC1090
( . "$SCRIPT"
  DEST_HOME="$th_np"
  is_interactive() { return 0; }
  tool_present() { [ "$1" != patch ]; }   # pretend patch is absent
  deploy_file bashrc ) >/dev/null 2>&1
grep -q '^keep me$' "$th_np/.bashrc"
check "missing patch: differ is skipped not clobbered" $?
```

- [ ] **Step 2: Run tests to verify the new expectations fail**

Run: `bash test/install_test.sh`
Expected: the new all-yes integration check FAILS (deploy_file still
launches `$DOTFILES_MERGE`, which is unset/`vimdiff` and does nothing
useful headlessly) and/or the missing-patch check behaves wrong. This
confirms the wiring is not yet in place.

- [ ] **Step 3: Rewire `deploy_file` and drop `DOTFILES_MERGE`**

In `install.sh`, replace the merge `else` branch of `deploy_file`:

```bash
    else
        if ! is_interactive; then
            warn ".$name differs; no tty, skipping (run interactively to merge)"
            SKIPPED=$((SKIPPED + 1))
        elif ! tool_present diff || ! tool_present patch; then
            warn ".$name differs; need diff and patch to merge, skipping"
            SKIPPED=$((SKIPPED + 1))
        else
            merge_file "$name" "$src" "$target"
        fi
    fi
```

Delete the line `DOTFILES_MERGE="${DOTFILES_MERGE:-vimdiff}"`.

Update `usage()`'s Environment section to drop `DOTFILES_MERGE` and
describe the new behaviour:

```bash
Environment:
  DOTFILES_INTERACTIVE  set to 1 or 0 to force or skip the interactive
                        merge (default: auto-probe for a tty). When a
                        deployed file differs, the merge walks the diff one
                        hunk at a time; press e at any hunk to resolve the
                        whole file in \$EDITOR with conflict markers.
EOF
```

(Keep the surrounding `cat <<EOF` / `Usage:` lines; only the Environment
block changes.)

- [ ] **Step 4: Run the full suite to verify it passes**

Run: `bash test/install_test.sh`
Expected: `== N passed, 0 failed ==` (all original checks plus the Task 1,
Task 2, and Task 3 additions).

- [ ] **Step 5: Shellcheck**

Run: `shellcheck -S warning install.sh test/install_test.sh`
Expected: clean.

- [ ] **Step 6: Stop for review**

Do NOT commit. Report the full diff, the passing suite, and clean
shellcheck; the controller reviews the whole branch and gates the commit.

---

## Self-Review

**Spec coverage:**

- Per-hunk `[y]/[n]/[e]/[q]` loop + `patch`-to-copy apply → Task 2.
- `q` = apply-accepted-so-far → Task 2 (`q) break`, then `any` gates
  apply; the quit-first test asserts the none-accepted case).
- `e` → `$EDITOR` conflict-marker resolve, unresolved = skip → Task 1
  (`_merge_editor`) + Task 2 (`e` handoff).
- GNU `diff` group-format render → Task 1, verified live.
- `DOTFILES_MERGE` removed, `$EDITOR`/`DOTFILES_INTERACTIVE` behaviour →
  Task 3.
- Headless skip unchanged; diff/patch-missing skip → Task 3.
- `DOTFILES_INPUT` test seam → Tasks 1-3.
- All spec test cases mapped to checks in Tasks 1-3.

**Placeholder scan:** No TBD/TODO; every code and test step is concrete.

**Type consistency:** `_merge_editor` and `merge_file` signatures
(`<name> <src> <target>`) are identical across their definitions, the
`merge_file`→`_merge_editor` call, and the `deploy_file`→`merge_file`
call. Counter names `MERGED`/`SKIPPED` match the existing globals. Stub
editor names `resolve_ed`/`noop_ed` are defined in Task 1 and reused in
Task 2.
