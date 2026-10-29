umask 002
export BASH_SILENCE_DEPRECATION_WARNING=1 # macOS: no "default shell is now zsh" nag

export PAGER=more # less can DIAF.
export PATH="$HOME/bin:$PATH"
if [ -x ~/perl5/perlbrew/etc/bashrc ]; then
    source ~/perl5/perlbrew/etc/bashrc
fi

# if running bash
if [ -n "$BASH_VERSION" ]; then
    # include .bashrc if it exists
    if [ -f "$HOME/.bashrc" ]; then
        source "$HOME/.bashrc"
    fi
fi
