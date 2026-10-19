# Agentic Code Review: fix-perlenv-version-match

**Date:** 2026-10-19 11:53:58
**Branch:** fix-perlenv-version-match -> main
**Commit:** 3a91c3b16be31c17dad78ffd5f0cf9d05a15864e
**Files changed:** 2 | **Lines changed:** +22 / -3
**Diff size category:** Small

## Executive Summary

The trailing-whitespace strip is correct, and it turns out to be the real
fix. On main, real `perlbrew list` padding meant no `PERL_VERSION` ever
matched. The normalisation step is the problem. It rewrites valid perlbrew
names before the installed check. That mangles aliases, `--as` names and
`@lib` names. In some cases it silently switches to a different installed
perl, for example `5.36` resolves to `perl-5.36.0`. All six specialists
raised this independently. Everything else is pre-existing, Suggestion-level
hardening.

## Critical Issues

None found.

## Important Issues

### [I1] Normalising PERL_VERSION rewrites valid perlbrew names

- **File:** `perlenv_hook:193`
- **Bug:** `pv=$(_perlenv_normalize_version "$pv" || printf '%s' "$pv")`
  runs before the installed check and rewrites names `perlbrew use` would
  accept as written. Some examples:
  - `cperl-5.30.0` becomes `perl-cperl-5.30.0`
  - `perl-5.36-thr`, `5.36-thr` and `perl-5.36` become `perl-5.36.0`
  - `perl-5.36@lib` and `5.36@dev` become `perl-5.36.0` (the lib is dropped)
  - `5.36_01` becomes `perl-5.360.1`
- **Impact:**
  - Custom names get a false "not installed" hint.
  - Several inputs collapse to `perl-5.36.0`. That perl is installed on this
    machine, so the hook silently switches to the wrong perl, or drops the
    lib, with no warning.
  - The hook now disagrees with perlbrew's own resolver.
  - The normaliser's "minimum version" meaning (5.36 → 5.36.0) suits the
    detector but is wrong for a name lookup.
- **Suggested fix:** do the lookup the way `resolve_installation_name`
  does (`bin/perlbrew:3327-3345`):
  - Try the name as written, then `perl-$name`.
  - Read installed names from `perlbrew list --no-decoration`, which also
    makes the sed strip unnecessary.
  - Drop the normaliser from the cd hook.
  - In the install hint, use `perl-$pv` unless the value already starts with
    `perl-`.

  This deliberately drops the `5.036003`, `v5.36.3` and bare `5.36`
  conveniences, which `perlbrew use` rejects too. A raw-first-then-normalise
  fix is the smaller diff, but it keeps the silent 5.36 → 5.36.0 switch and
  the `@lib` drop.
- **Confidence:** High
- **Found by:** Logic, Error Handling, Contract & Integration, Concurrency &
  State, Security, Plan Alignment

## Suggestions

- **S1** (`test/perlenv_hook_test.sh:141-189`, introduced): the stub
  `perlbrew list` has only `perl-5.x.y` names, so I1 can't be caught. Add an
  alias, a `--as` name and a `@lib` entry, and assert that `perlbrew use`
  receives the exact name. Make the stub handle `--no-decoration` if that
  flag is used. (Logic, Contract)
- **S2** (`docs/superpowers/plans/2026-07-28-perlenv-cd-hook.md:41-43`,
  introduced): the plan invariant "cd hook uses PERL_VERSION as written,
  never normalized" is contradicted by this branch. With the I1 fix it is
  true again apart from the `perl-` fallback, so update that line. The spec
  (`docs/superpowers/specs/2026-07-28-perlenv-cd-hook-design.md:45-51`) also
  doesn't say which PERL_VERSION formats are accepted. (Plan, Contract)
- **S3** (`CLAUDE.md:21,28-29`, pre-existing): steering file is stale.
  - It says "the one test" is `install_test.sh`, but
    `test/perlenv_hook_test.sh` exists.
  - The deploy list omits `perlenv_hook` → `~/.perlenv_hook`.
  - The shellcheck example omits `perlenv_hook`.
  - It still documents `$DOTFILES_MERGE`, which commit a881f1f removed.

  (Concurrency, Logic, Verifier)
- **S4** (`test/perlenv_hook_test.sh` top, pre-existing): the harness
  inherits the caller's environment. `PERLENV_DEFAULT=perl-5.36.0 bash
  test/perlenv_hook_test.sh` fails "leave: perlbrew off". Unset `PERLENV_*`,
  `PERL5LIB`, `CARTON`, `PERL_VERSION` and the `_PERLENV_*` state after
  `set -u`. (Concurrency)
- **S5** (`perlenv_hook:180-191`, pre-existing): a sourced `.perlenv` that
  assigns `root=` or `pe=` overwrites `_perlenv_apply`'s locals, which
  silently corrupts `_PERLENV_ACTIVE_ROOT` or skips the version switch. Use
  namespaced locals. (Concurrency)
- **S6** (`perlenv_hook:196-199`, pre-existing): there are two problems.
  - `command -v perlbrew` is also true for the bare binary. Without the shell
    function, `perlbrew use` `exec`s an interactive sub-shell inside
    PROMPT_COMMAND, with output sent to /dev/null, which looks like a hung
    prompt. This is latent here because bashrc loads the function. Guard with
    `[ "$(type -t perlbrew)" = function ]`.
  - The return code of `perlbrew use` is ignored, so `_PERLENV_SWITCHED=1` is
    set even when the switch fails.

  (Error Handling)
- **S7** (`perlenv_hook:37-48`, pre-existing): the text parse of
  `PERL_VERSION` doesn't always match what bash actually sets:
  - `PERL_VERSION=x; export FOO=1` on one line breaks the parse.
  - `${PERL_VERSION:-...}` is taken literally.
  - `PERL_VERSION` is also never saved or restored on leave.

  Snapshot it like PERL5LIB, and read `${PERL_VERSION:-}` after sourcing.
  (Error Handling)
- **S8** (`perlenv_hook:141,144`, pre-existing): `perlenv-init` writes
  through a dangling `.perlenv` symlink, so a cloned repo can get a file
  created at a path it chooses. The content is a fixed template, so impact is
  limited. Refuse when `[ -L ]`, and write with noclobber. (Security)
- **S9** (`perlenv_hook:173-176`, pre-existing): if `perlbrew list` fails or
  prints nothing, the user gets the "not installed, run perlbrew install"
  hint. Return a distinct code for that case. (Error Handling)

## Plan Alignment

- **Implemented:** the spec requirement that "not installed" should print the
  exact `perlbrew install perl-X.Y.Z` command
  (`design.md:49-50`) is now met for bare versions.
- **Not yet implemented:** the spec doesn't document which PERL_VERSION
  formats the hook accepts.
- **Deviations:** the branch reverses the plan's "trust the user's perlbrew
  name" invariant (`plan.md:41-43`). The code comment was updated but the
  docs weren't. The I1 fix restores the invariant, apart from the `perl-`
  prefix fallback.

## Review Metadata

- **Agents dispatched:** Logic & Correctness, Error Handling & Edge Cases,
  Contract & Integration, Concurrency & State, Security, Plan Alignment,
  Verifier
- **Scope:** `perlenv_hook` (whole module), `test/perlenv_hook_test.sh`,
  `install.sh`, `bashrc`, perlbrew's `etc/bashrc` and `bin/perlbrew`
- **Raw findings:** 11 (after deduplicating findings from all six agents)
- **Verified findings:** 10 (1 Important, 9 Suggestions)
- **Filtered out:** 1, plus half of another:
  - F4: `PERLENV_DEFAULT` isn't normalised, but perlbrew resolves `perl-`
    itself.
  - The half of S5 that claimed `return` in `.perlenv` aborts
    `_perlenv_apply` (it doesn't: `return` only ends the `.` source).
- **Steering files consulted:** `CLAUDE.md`, `~/.claude/CLAUDE.md`
- **Plan/design docs consulted:**
  `docs/superpowers/specs/2026-07-28-perlenv-cd-hook-design.md`,
  `docs/superpowers/plans/2026-07-28-perlenv-cd-hook.md`
