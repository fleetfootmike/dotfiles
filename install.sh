#!/usr/bin/env bash
#
# install.sh - deploy this repo's dotfiles into $HOME and check prereqs.
# Config files are copied (never symlinked) with a leading dot added.
set -euo pipefail

GREEN=$'\033[0;32m'; BLUE=$'\033[0;34m'; YELLOW=$'\033[1;33m'
RED=$'\033[0;31m'; NC=$'\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2034  # Used by functions added in later tasks
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
    # phases wired in later tasks
    return 0
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
