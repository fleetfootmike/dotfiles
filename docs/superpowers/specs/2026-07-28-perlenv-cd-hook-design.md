# Perlenv cd hook: design

**Date:** 2026-07-28
**Status:** approved (brainstorming), pending implementation plan

## Purpose

Add a bash hook that runs on directory change and manages the per-repo
Perl environment automatically. When you `cd` into a git repo it reads
that repo's `.perlenv`, switches the active perlbrew perl to the repo's
`PERL_VERSION`, and loads the repo's `CARTON` / `PERL5LIB` into the shell.
When you leave, it puts those back. It also nudges you to set things up in
Perl repos that lack a `.perlenv` or a `PERL_VERSION`.

`.perlenv` is per-repo (the pre-commit hook already sources it for
`$CARTON` / `$PERL5LIB`); the template currently sets `CARTON` and
`PERL5LIB` but not `PERL_VERSION`, and this project adds that reminder.

This is a bash-only v1. macOS uses zsh and is tracked separately as a
future item; nothing here targets zsh.

## Trigger: bash chpwd emulation

bash has no native `chpwd`. The hook rides `PROMPT_COMMAND`: before each
prompt, if `$PWD` differs from the last value it saw, it runs the handler.
This catches `cd`, `pushd`, `popd`, and any other `$PWD` change.

- Interactive shells only (`case $- in *i*) ;; *) return ;; esac`).
- When `$PWD` is unchanged it returns immediately, so ordinary prompts pay
  nothing.
- It tracks the current git repo root (`git rev-parse --show-toplevel`).
  Moving between subdirectories of the same repo does nothing; it acts
  only when the repo root changes (entering or leaving a repo).
- It appends to any existing `PROMPT_COMMAND` rather than replacing it.

## Per-entry decision flow

On landing in a git repo whose root differs from the last one processed:

- **Repo-root `.perlenv` exists:**
  - Allow-list check (see below). If the file is not yet allowed, prompt
    `allow this .perlenv? [y/N]`. Declined means it is not sourced, and
    the decline is remembered for the session so there is no re-nag.
  - If allowed, snapshot the current `CARTON` / `PERL5LIB`, then source
    the `.perlenv` (setting `CARTON`, `PERL5LIB`, and `PERL_VERSION` if
    present).
  - `PERL_VERSION` set and that perlbrew perl is installed: `perlbrew use
    <version>` for the current shell.
  - `PERL_VERSION` set but not installed: warn and print the exact
    `perlbrew install perl-X.Y.Z` command; stay on the current perl.
  - `.perlenv` present but no `PERL_VERSION`, in a Perl repo: warn and
    offer to add one (runs the detector below).
- **No `.perlenv`, repo looks like a Perl project** (has `cpanfile`,
  `Makefile.PL`, `dist.ini`, or a `*.pm` under `lib/`): warn and prompt to
  create one from the template via `perlenv-init`. Declined is remembered
  for the session.
- **Otherwise** (not a Perl repo, no signals): silent.

**On leaving** a managed repo, that is, moving into a non-repo or a repo
with no allowed env: restore the snapshotted `CARTON` / `PERL5LIB`, and
switch the perl back to `$PERLENV_DEFAULT`. If `PERLENV_DEFAULT` is unset,
revert to the system perl (`perlbrew off`).

State the hook keeps in the shell (all bash 3.2 safe, no associative
arrays): the last `$PWD`, the active managed repo root, the snapshotted
`CARTON` / `PERL5LIB` to restore, and a newline-delimited list of
session-declined directories.

## Allow-list

Sourcing a repo's `.perlenv` runs whatever code it contains, so the hook
only sources files you have explicitly allowed, in the style of direnv.

- State file: `~/.local/state/perlenv/allow`, one entry per line as
  `<sha256><space><absolute path to .perlenv>`.
- On encountering a `.perlenv`, hash it and compare:
  - `(path, hash)` present: allowed, source it.
  - path present but hash differs: the file changed, re-prompt to allow.
  - path absent: prompt to allow.
- Only allowed, hash-matching files are ever sourced. A decline this
  session is remembered in memory so the prompt does not repeat.

## `perlenv-init` and the min-version detector

`perlenv-init` writes `.perlenv` from the template into the current repo
root, then best-effort pre-fills `PERL_VERSION` with the **highest** floor
it can find across these sources:

- `use 5.0NN` or `use v5.NN` statements in `lib/**/*.pm` and top-level
  `*.pm`.
- a `perl` prerequisite in `cpanfile` (`requires 'perl', '5.034'`),
  `Makefile.PL` (`MIN_PERL_VERSION`), or `dist.ini` (`perl = 5.034`).

It normalizes the result to perlbrew naming (for example `perl-5.36.0`).
If it finds nothing it leaves the commented reminder in place. The
detection is best-effort with no guarantees; a full transitive-dependency
resolver is out of scope (see below).

The cd hook's "create one?" prompt calls `perlenv-init`. The detector and
parser are pure functions (a directory or file path in, a version string
out) so they are unit-testable against fixture repos.

## Template change

Add a commented `PERL_VERSION` reminder to the `perlenv` template:

```sh
# set PERL_VERSION so the cd hook switches perlbrew perls for you:
# export PERL_VERSION=perl-5.36.0
```

## Files and packaging

- New tracked `perlenv_hook` (deploys to `~/.perlenv_hook`) holding the
  cd hook, `perlenv-init`, the detector, and the allow-list logic.
- `bashrc` gains one line: `[ -f ~/.perlenv_hook ] && . ~/.perlenv_hook`.
- `install.sh`'s `DOTFILES` list gains `perlenv_hook`, so it deploys the
  usual way.
- `perlenv` template updated with the reminder above.

## Testing

A harness in the same style as `install.sh`'s: source `perlenv_hook`, stub
`perlbrew`, and drive the functions against throwaway fixture repos.

- Detector: each source type (`use` statement, cpanfile, Makefile.PL,
  dist.ini) and the "highest floor wins" combination.
- `PERL_VERSION` parse from a `.perlenv`.
- Allow-list: allow, deny, and changed-hash re-prompt.
- Is-Perl-repo detection (positive and negative).
- Enter and leave: perl switch on entry, and snapshot restore plus revert
  to `PERLENV_DEFAULT` on leave.

`shellcheck -S warning` clean; the hook stays free of bash-4-only features.

## Out of scope

- A full min-perl resolver across transitive dependencies (v1 ships only
  the simple detector; the fuller resolver is a possible follow-up).
- zsh support (tracked as a separate future item; v1 is bash only).
- Any change to how the pre-commit hook consumes `.perlenv`.
- Building missing perls automatically (the hook only warns and prints the
  `perlbrew install` command).
