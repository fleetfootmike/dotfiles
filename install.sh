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
  DOTFILES_INTERACTIVE  set to 1 or 0 to force or skip the interactive
                        merge (default: auto-probe for a tty). When a
                        deployed file differs, the merge walks the diff one
                        hunk at a time; press e at any hunk to resolve the
                        whole file in \$EDITOR with conflict markers.
EOF
}

# In-scope dotfiles: each is copied to $DEST_HOME/.<name>. Deliberately
# excludes perlenv (per-repo) and the pre-commit hook template.
DOTFILES=(bashrc bash_profile bash_aliases screenrc markdownlint.json \
    perlenv_hook)

INSTALLED=0; UPTODATE=0; MERGED=0; SKIPPED=0

tool_present() { command -v "$1" >/dev/null 2>&1; }

is_interactive() {
    if [ -n "${DOTFILES_INTERACTIVE:-}" ]; then
        [ "$DOTFILES_INTERACTIVE" = 1 ]
        return
    fi
    # shellcheck disable=SC2217
    { true < /dev/tty; } 2>/dev/null
}

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
    elif cp "$tmp" "$target"; then
        ok "merged .$name"; MERGED=$((MERGED + 1))
    else
        warn ".$name: merge copy failed, kept unchanged"
        SKIPPED=$((SKIPPED + 1))
    fi
    rm -f "$tmp"
}

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
    if ! cp "$tmpdir/header" "$accepted"; then
        warn ".$name: cannot stage patch, kept unchanged"
        SKIPPED=$((SKIPPED + 1)); rm -rf "$tmpdir"; return 0
    fi

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
        local copy="$tmpdir/copy"
        if ! cp "$target" "$copy"; then
            warn ".$name: merge copy failed, kept unchanged"
            SKIPPED=$((SKIPPED + 1)); rm -rf "$tmpdir"; return 0
        fi
        if ! patch -s "$copy" < "$accepted" >/dev/null 2>&1; then
            warn ".$name: patch failed, kept unchanged"
            SKIPPED=$((SKIPPED + 1))
        elif cp "$copy" "$target"; then
            ok "merged .$name"; MERGED=$((MERGED + 1))
        else
            warn ".$name: merge copy failed, kept unchanged"
            SKIPPED=$((SKIPPED + 1))
        fi
    else
        info ".$name kept unchanged"; SKIPPED=$((SKIPPED + 1))
    fi
    rm -rf "$tmpdir"; return 0
}

deploy_file() {
    local name="$1" src="$REPO_ROOT/$name" target="$DEST_HOME/.$name"
    if [ ! -e "$target" ]; then
        if cp "$src" "$target"; then
            ok "installed .$name"; INSTALLED=$((INSTALLED + 1))
        else
            warn ".$name: copy failed, skipping"; SKIPPED=$((SKIPPED + 1))
        fi
    elif cmp -s "$src" "$target" 2>/dev/null; then
        info ".$name up to date"; UPTODATE=$((UPTODATE + 1))
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

# Core prereqs in dependency order (perlbrew -> perl -> cpanm -> carton;
# npm -> markdownlint). perl536 is the >= 5.36.0 check.
CORE_PREREQS=(perlbrew perl536 cpanm carton screen shellcheck yamllint \
    npm markdownlint)
OPTIONAL_PREREQS=(docker mysql json_pp)

PKG=none

detect_pkg_mgr() {
    if tool_present apt-get; then PKG=apt
    elif tool_present brew; then PKG=brew
    else PKG=none; fi
}

perl_ok() {
    tool_present perl && perl -e 'require 5.036;' >/dev/null 2>&1
}

prereq_present() {
    case "$1" in
        perl536) perl_ok ;;
        *)       tool_present "$1" ;;
    esac
}

label_for() {
    case "$1" in
        perl536) echo "perl >= 5.36.0" ;;
        *)       echo "$1" ;;
    esac
}

# Print the install recipe for a tool, honouring $PKG.
recipe_for() {
    local tool="$1" apt="" brew="" special=""
    case "$tool" in
        perlbrew) special='\curl -L https://install.perlbrew.pl | bash' ;;
        perl536)  special='perlbrew install perl-5.36.0' ;;
        cpanm)    special='perlbrew install-cpanm'
                  apt='sudo apt-get install -y cpanminus'
                  brew='brew install cpanminus' ;;
        carton)   special='cpanm Carton' ;;
        screen)   apt='sudo apt-get install -y screen'
                  brew='brew install screen' ;;
        shellcheck) apt='sudo apt-get install -y shellcheck'
                  brew='brew install shellcheck' ;;
        yamllint) apt='sudo apt-get install -y yamllint'
                  brew='brew install yamllint' ;;
        npm)      apt='sudo apt-get install -y nodejs npm'
                  brew='brew install node' ;;
        markdownlint) special='npm install -g markdownlint-cli' ;;
        docker)   apt='sudo apt-get install -y docker.io'
                  brew='brew install --cask docker' ;;
        mysql)    apt='sudo apt-get install -y mariadb-client'
                  brew='brew install mysql-client' ;;
        json_pp)  special='ships with perl' ;;
        *)        special='(no recipe)' ;;
    esac
    if [ -n "$special" ]; then
        printf '%s' "$special"
        if [ "$PKG" = apt ]  && [ -n "$apt" ];  then printf '  (or %s)' "$apt"; fi
        if [ "$PKG" = brew ] && [ -n "$brew" ]; then printf '  (or %s)' "$brew"; fi
    elif [ "$PKG" = apt ]  && [ -n "$apt" ];  then printf '%s' "$apt"
    elif [ "$PKG" = brew ] && [ -n "$brew" ]; then printf '%s' "$brew"
    else printf '(install manually)'
    fi
}

check_prereqs() {
    detect_pkg_mgr
    info "checking prereqs (package manager: $PKG)"
    local missing=0 tool
    for tool in "${CORE_PREREQS[@]}"; do
        if prereq_present "$tool"; then
            ok "$(label_for "$tool") present"
        else
            missing=$((missing + 1))
            if [ "$PKG" = none ]; then
                warn "$(label_for "$tool") MISSING"
            else
                warn "$(label_for "$tool") MISSING -> $(recipe_for "$tool")"
            fi
        fi
    done
    for tool in "${OPTIONAL_PREREQS[@]}"; do
        if prereq_present "$tool"; then
            ok "$(label_for "$tool") present (optional)"
        elif [ "$PKG" = none ]; then
            warn "$(label_for "$tool") missing (optional)"
        else
            warn "$(label_for "$tool") missing (optional) -> $(recipe_for "$tool")"
        fi
    done
    if [ "$missing" -eq 0 ]; then
        ok "all core prereqs present"
    else
        warn "$missing core prereq(s) missing"
    fi
}

main() {
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
    if [ "$DO_CHECK" = 1 ]; then check_prereqs; fi
    if [ "$DO_DEPLOY" = 1 ]; then deploy_all; fi
    return 0
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
