# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working
with code in this repository.

Personal dotfiles: bash shell setup plus Perl-development tooling
(perlbrew + carton + GNU screen). No secrets are stored here.

## Conventions

- Config files are stored **without leading dots**: `bashrc` →
  `~/.bashrc`, `bash_profile` → `~/.bash_profile`, `bash_aliases` →
  `~/.bash_aliases`, `perlenv` → `~/.perlenv`, `screenrc` → `~/.screenrc`.
- There is **no install/bootstrap script**, and the deployment method
  (symlink vs copy) is not fixed — don't assume one.
- `bin/` is untracked; scripts there aren't part of the committed repo yet.
- No CI or tests for this repo itself.
- Lint shell scripts with `shellcheck`, e.g.
  `shellcheck bashrc bash_profile bash_aliases bin/*`. The files here carry
  no `.sh` extension, so pass them explicitly.

## git/hooks/pre-commit

This is a **reusable template** meant to be copied/symlinked into *other*
project repos' `.git/hooks/` — not solely a hook for this repo (though it
is installed here too, so commits here get linted and main is blocked).
When editing it, preserve these behaviors:

- Blocks direct commits to `main`/`master` (exits 1).
- Requires a tty (`exec < /dev/tty`) for its interactive prompts.
- Validates staged files by type:
  - `.pl` / `.pm` → `perl -Ilib -cw`
  - `.t` → `prove -l`
  - `.json` → `json_pp`
  - `.sh` / bash → `bash -n`
  - `.yml` / `.yaml` → `yamllint`
  - `.md` → `markdownlint` (enforces MD013, 80-col line length)
  - `Dockerfile*` → `docker build --check`
  - `.sql` → stub, not yet validated
- Optionally sources `.perlenv` (local then `~/.perlenv`) to set `$CARTON`
  and `$PERL5LIB` so Perl checks can run under `carton exec`.
- Assumes on PATH: `yamllint`, `markdownlint`, `json_pp`, `carton`,
  `docker`, `mysql`.
- Escape hatch is `git commit --no-verify`.
