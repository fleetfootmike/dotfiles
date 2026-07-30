# install.sh merge: per-hunk prompting with an $EDITOR fallback

**Date:** 2026-07-30
**Status:** approved (brainstorming), pending implementation plan

## Purpose

Replace the vimdiff merge step in `install.sh`. When a deployed dotfile
differs from the repo's version, the script currently launches
`$DOTFILES_MERGE` (default `vimdiff`) on the two files. That is heavy and
assumes the user knows vim. This change swaps it for a built-in per-hunk
prompt, with a fallback that drops the user into `$EDITOR` on a file
carrying git-style conflict markers, the way git leaves a file that needs
merging.

The scope is the merge branch of `deploy_file` only. Everything else the
script does (the copy-on-missing path, the identical-file skip, the
headless no-tty skip, the prereq report) is unchanged.

## Behaviour

`deploy_file` reaches the merge branch when the target exists and differs
from the repo source. Today that branch checks for the merge tool, checks
for a tty, then runs `$DOTFILES_MERGE "$target" "$src"`. The new branch
keeps the tty gate (headless still warns and skips, never clobbers) and
replaces the tool launch with the flow below.

### Per-hunk loop

Compute a unified diff of the deployed file against the repo version:

```sh
diff -u "$target" "$src"
```

`$target` is the deployed file (yours), `$src` is the repo version, so the
diff reads as "your file, patched towards the repo". Split the output into
its `---`/`+++` header and a list of hunks (each starting with `@@`). For
each hunk, print it and prompt:

```text
Apply this hunk? [y]es / [n]o / [e]dit / [q]uit
```

- **y**: include this hunk in the patch to apply.
- **n**: skip this hunk.
- **q**: stop prompting and apply the hunks accepted so far, skipping the
  rest. This matches `git add -p` quit semantics.
- **e**: abandon per-hunk mode for this file and go to the `$EDITOR`
  fallback below. Any y/n choices made so far for this file are discarded,
  because the fallback resolves the whole file at once.

Accepted hunks are assembled into a temp patch file (the original header
plus the chosen hunks) and applied with `patch` to a **copy** of the
target. On success the copy replaces the target and the file counts as
merged. On failure the script warns and leaves the target untouched, and
the file counts as skipped. Applying to a copy keeps `patch` from leaving
`.orig` files or writing a half-patched target. If no hunks are accepted
(all `n`, or `q` before any `y`), the target is left unchanged and counts
as skipped.

### `$EDITOR` fallback (`e`)

Render a single file that carries both versions as git-style conflict
markers, using GNU `diff` group-format output:

```text
<<<<<<< yours (~/.bashrc)
...your lines...
=======
...repo lines...
>>>>>>> repo (bashrc)
```

Unchanged runs appear once, plain. Only differing runs get wrapped in
markers. Write that to a temp file and open it in `${EDITOR:-vi}`. When the
editor exits:

- If any `<<<<<<<`, `=======`, or `>>>>>>>` marker remains, warn
  "unresolved, kept .name unchanged", leave the target untouched, and count
  the file as skipped. The script never deploys a file that still has
  conflict markers.
- Otherwise the resolved temp file replaces the target and the file counts
  as merged.

The script does not re-open the editor on unresolved markers; the user can
re-run `install.sh` to try again.

### `DOTFILES_MERGE` removed

The built-in flow is the only merge path, so `DOTFILES_MERGE` is gone.
`$EDITOR` (the standard variable) selects the editor for the `e` fallback,
falling back to `vi`. `DOTFILES_INTERACTIVE` is unchanged: it still forces
or skips the interactive path, and the auto-probe for a tty still governs
the default.

## Dependencies

- GNU `diff`, for the per-hunk diff and the `--*-group-format` conflict
  rendering. The group-format flags are a GNU `diff` feature.
- `patch`, for applying the accepted hunks.

Both are standard on the Linux dev target. If either is missing the merge
branch warns and skips rather than failing the run. macOS is out of scope
here (tracked separately with the wider zsh/macOS work).

## Test seam

The per-hunk prompt reads answers from `/dev/tty` by default. An internal
`DOTFILES_INPUT` env var overrides the read source with a file of answer
lines (`y`, `n`, `e`, `q`), so the harness can drive the loop without a
real terminal. It is a test seam, not a documented option, so `--help`
does not mention it. The `e` fallback launches `$EDITOR`, which the harness
stubs with a script, exactly as the current tests stub `DOTFILES_MERGE`.

## Testing

Extend `test/install_test.sh` in its existing style (source or invoke
`install.sh`, drive against throwaway `--home` dirs, stub external
programs). Replace the current stub-merge case. New cases:

- Differing target, `DOTFILES_INPUT` of all `y`: target becomes
  byte-identical to the repo version, reported merged.
- Differing target, all `n`: target unchanged, reported skipped.
- Two-hunk fixture, one `y` and one `n`: only the accepted hunk lands;
  the other region keeps the deployed content.
- `q` before any `y`: target unchanged.
- `e` with a stub `$EDITOR` that resolves the markers (keeps one side):
  the resolved result is deployed, reported merged.
- `e` with a stub `$EDITOR` that leaves the markers in place: target
  unchanged, reported skipped.
- Headless (`DOTFILES_INTERACTIVE=0`) differing target: unchanged, as
  today.

`shellcheck -S warning` clean; no bash-4-only features (the repo targets
bash 3.2).

## Out of scope

- macOS / BSD `diff` and `patch` differences (tracked with the zsh/macOS
  future work).
- Any change to the copy-on-missing, identical-skip, headless-skip, or
  prereq-check behaviour.
- Three-way merge against a common ancestor. The conflict markers come from
  a two-file diff, not a real base; that is enough to hand-resolve in an
  editor.
