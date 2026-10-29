# shellcheck shell=bash
umask 002
export BASH_SILENCE_DEPRECATION_WARNING=1 # macOS: no "default shell is now zsh" nag

export PAGER=more # less can DIAF.
# macOS: Homebrew (Apple Silicon); first, so ~/bin and perlbrew override it
if [ -x /opt/homebrew/bin/brew ]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
fi
export PATH="$HOME/bin:$PATH"
if [ -d "$HOME/.local/bin" ]; then
    PATH="$HOME/.local/bin:$PATH"
fi
if [ -r ~/perl5/perlbrew/etc/bashrc ]; then
    # shellcheck source=/dev/null  # perlbrew's file, not in this repo
    source ~/perl5/perlbrew/etc/bashrc
fi

# if running bash
if [ -n "$BASH_VERSION" ]; then
    # include .bashrc if it exists
    if [ -f "$HOME/.bashrc" ]; then
        # shellcheck source=bashrc
        source "$HOME/.bashrc"
    fi
fi
