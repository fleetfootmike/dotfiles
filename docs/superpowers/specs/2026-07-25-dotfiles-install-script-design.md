# Dotfiles install script: design

**Date:** 2026-07-25
**Status:** approved (brainstorming), pending implementation plan

## Purpose

Add a tracked `install.sh` at the repo root that deploys this repo's
config files into `$HOME` on a new machine (adding the leading dot), and
checks that the tools the dotfiles and pre-commit hook assume are
present. There is currently no install/bootstrap script, so this fills
that gap without committing to a fragile all-or-nothing bootstrap.

It does two independent jobs from one script:

1. Deploy the in-scope config files into `$HOME` as `.`-prefixed copies,
   merging (not clobbering) when a target already exists.
2. Check prereqs and, for anything missing, print a copy-pasteable
   install command per tool without running it.

## Scope: what gets deployed

Copied into `$HOME` with a leading dot:

| Repo file          | Target                 |
| ------------------ | ---------------------- |
| `bashrc`           | `~/.bashrc`            |
| `bash_profile`     | `~/.bash_profile`      |
| `bash_aliases`     | `~/.bash_aliases`      |
| `screenrc`         | `~/.screenrc`          |
| `markdownlint.json`| `~/.markdownlint.json` |

Explicitly excluded:

- `perlenv`. Per-repo config, must never land at `~/.perlenv`. The
  per-repo tooling lives elsewhere (see the perlenv cd-hook project).
- `git/hooks/pre-commit`. A template for *other* repos' `.git/hooks/`,
  not a home dotfile. Out of scope for this script.
- Repo meta: `README.md`, `CLAUDE.md`, `docs/`, `paad/`, and the tracked
  `.markdownlint.json` symlink.

The in-scope set is a hardcoded list inside the script, not a directory
glob. Adding a new dotfile is a deliberate one-line edit, so nothing gets
deployed by accident.

## Deploy method: copy, merge on conflict

Files are copied, not symlinked. Home files are independent snapshots.
The cost is that updates need a re-run and home can drift from the repo,
which is acceptable for a personal dotfiles set and makes the merge story
natural.

Per-file flow:

```text
target = ~/.<name>
  target missing            -> cp repo/<name> -> target    ("installed")
  target identical (cmp -s) -> do nothing                  ("up to date")
  target exists & differs   -> launch merge tool           ("merging")
```

Merge behaviour:

- Default tool: `vimdiff "$target" "$repo_file"`. The target (home file)
  is on the left and is the artifact that persists; the repo version is
  on the right to pull from.
- Overridable via `$DOTFILES_MERGE` (for example `meld` or
  `code --diff`).
- If the merge tool is not found, or there is no tty (a headless run),
  the file is skipped with a warning. The script never does a blind
  overwrite.
- The flow is idempotent: a re-run only touches files that are missing or
  differ.
- `--home <dir>` overrides `$HOME` so the deploy path can be exercised
  against a throwaway directory in tests.

## Prereq check: report only, per-tool recipes

Detect the package manager once: `apt-get` (Debian/Ubuntu) or `brew`
(macOS). If neither is present, fall back to report-only with no recipes.

For each prereq, check presence with `command -v` and, for the missing
ones, print a per-tool recipe. The script never runs an install: no
sudo, no system mutation. The recipes are a per-tool by per-platform
lookup, because these tools do not share one package-manager line.

### Core prereqs (dependency order)

Reported top-down so the fix list reads in install order:

1. `perlbrew`: `\curl -L https://install.perlbrew.pl | bash`
2. a perlbrew perl >= 5.36.0: `perlbrew install perl-5.36.0`
3. `cpanm`: `perlbrew install-cpanm`
   (or `sudo apt-get install -y cpanminus` / `brew install cpanminus`)
4. `carton`: `cpanm Carton`
5. `screen`: `sudo apt-get install -y screen` / `brew install screen`
6. `shellcheck`: `sudo apt-get install -y shellcheck` /
   `brew install shellcheck`
7. `yamllint`: `sudo apt-get install -y yamllint` /
   `brew install yamllint`
8. `node` / `npm`: `sudo apt-get install -y nodejs npm` /
   `brew install node`
9. `markdownlint`: `npm install -g markdownlint-cli`

`carton` depends on `cpanm`, which depends on a perlbrew perl, which
depends on `perlbrew`; `markdownlint` depends on `npm`. The ordering
makes those chains obvious in the output.

### Optional prereqs

Checked and flagged as optional, since only some pre-commit hook
validators need them:

- `docker`: used only by the `Dockerfile*` validator.
- `mysql` client: for the planned SQL validation.
- `json_pp`: ships with perl, checked for completeness.

## Structure and UX

A single `install.sh` with focused functions:

- `detect_pkg_mgr`: sets the pkg-manager / recipe flavour.
- `check_prereqs`: presence checks plus recipe printing.
- `deploy_file`: the per-file missing/identical/differs logic.
- `deploy_all`: iterate the hardcoded in-scope list.
- `main`: arg parsing and orchestration.

Flags:

- `--check-only`: run the prereq check only.
- `--deploy-only`: skip the prereq check.
- `--home <dir>`: override the deploy target (testing).
- `-h` / `--help`: usage.

With no flags it runs the prereq check, then the deploy.

Other details:

- Self-locating: the repo root is derived from the script's own path, so
  it works from any clone location.
- Output uses the same coloured `>>>` / `+++` prefix style as the
  pre-commit hook, with an end summary (installed / merged / skipped /
  up-to-date counts).
- `set -euo pipefail`; clean under `shellcheck -S warning` (the repo's
  own hook lints it on commit).

## Testing

There is no CI in this repo, so testing uses a manual harness modelled on
the pre-commit test script, driven by `--home <tmpdir>`:

- missing target: file copied.
- identical target: no-op.
- differing target: merge tool invoked (stub `$DOTFILES_MERGE=true`).
- `perlenv` never deployed to the target home.
- prereq check with a stubbed `PATH` / `command -v` to force the
  missing-tool path and verify the printed recipes.

## Out of scope

- Running installs or any sudo action (deliberately report-only).
- Deploying the pre-commit hook into repos (a separate concern).
- The perlenv cd-hook and SQL validation projects (tracked separately).
- Windows and package managers other than apt and brew, beyond
  report-only.
