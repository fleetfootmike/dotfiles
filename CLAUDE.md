# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working
with code in this repository.

Personal dotfiles: bash shell setup plus Perl-development tooling
(perlbrew + carton + GNU screen). No secrets are stored here.

## Conventions

- Config files are stored **without leading dots**: `bashrc` →
  `~/.bashrc`, `bash_profile` → `~/.bash_profile`, `bash_aliases` →
  `~/.bash_aliases`, `perlenv` → `~/.perlenv`, `screenrc` → `~/.screenrc`.
  The one deliberate exception is markdownlint: the real config is
  `markdownlint.json` (deploys to `~/.markdownlint.json`), but a tracked
  `.markdownlint.json` symlink → `markdownlint.json` also sits in the repo
  root so `markdownlint` auto-discovers the config when the pre-commit hook
  lints this repo's own `.md` files.
- `install.sh` (repo root) deploys the config files into `$HOME` by
  **copy** (adding the leading dot), launching a merge tool (`vimdiff`
  by default, override with `$DOTFILES_MERGE`) when a target already
  exists and differs. `perlenv` is never deployed. It also runs a
  report-only prereq check that prints per-tool install commands but
  never installs anything. Run `install.sh --help` for options.
  `$DOTFILES_MERGE` picks the merge tool and `$DOTFILES_INTERACTIVE`
  (1 or 0) forces or skips the merge prompt.
- `bin/` is untracked; scripts there aren't part of the committed repo yet.
- No CI. The one test is `test/install_test.sh` (run
  `bash test/install_test.sh`), covering `install.sh`.
- Lint shell scripts with `shellcheck`, e.g.
  `shellcheck bashrc bash_profile bash_aliases bin/*`. The files here carry
  no `.sh` extension, so pass them explicitly.

## git/hooks/pre-commit

This is a **reusable template** meant to be copied/symlinked into *other*
project repos' `.git/hooks/` — not solely a hook for this repo (though it
is installed here too, so commits here get linted and main is blocked).
When editing it, preserve these behaviors:

- Blocks direct commits to `main`/`master` (exits 1).
- Probes for a tty and only redirects/prompts when one is present; when
  headless (CI, an agent, a scripted commit) it sets `INTERACTIVE=0` and
  fails closed on any override-eligible lint finding instead of hanging.
- Validates staged files by type:
  - `.pl` / `.pm` → `perl -Ilib -cw`
  - `.t` → `prove -l`
  - `.json` → `json_pp`
  - `.sh` / bash → `shellcheck -S warning` (falls back to `bash -n` if
    shellcheck is missing)
  - `.yml` / `.yaml` → `yamllint`
  - `.md` → `markdownlint` (MD013 80-col line length, per `markdownlint.json`
    which exempts code blocks)
  - `Dockerfile*` → `docker build --check`
  - `.sql` → stub, not yet validated
- Optionally sources `.perlenv` (local then `~/.perlenv`) to set `$CARTON`
  and `$PERL5LIB` so Perl checks can run under `carton exec`.
- Assumes on PATH: `shellcheck`, `yamllint`, `markdownlint`, `json_pp`,
  `carton`, `docker`, `mysql`.
- Escape hatch is `git commit --no-verify`.
