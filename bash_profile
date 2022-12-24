umask 002

export PATH="$HOME/bin:$PATH"
source ~/perl5/perlbrew/etc/bashrc

# if running bash
if [ -n "$BASH_VERSION" ]; then
    # include .bashrc if it exists
    if [ -f "$HOME/.bashrc" ]; then
        source "$HOME/.bashrc"
    fi
fi
