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
    # shellcheck disable=SC2217
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

main() {
    # shellcheck disable=SC2034  # Variables used by functions added in later tasks
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
    if [ "$DO_DEPLOY" = 1 ]; then deploy_all; fi
    return 0
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
