# Source global definitions
if [ -f /etc/bashrc ]; then
        . /etc/bashrc
fi

# give me longrunning sessions or give me death
unset TMOUT

parse_git_branch() {
    git branch 2> /dev/null  | awk '/^*/ { print (length($2) >20) ? " (" substr($2,0,17) "...)" : " (" $2 ")"}'
}

export PS1="\u@\[\033[32m\]\h \[\033[34m\]\w\[\033[36m\] <${PERLBREW_PERL:-system perl}>\[\033[31m\]\$(parse_git_branch)\[\033[00m\] $ "

# User specific aliases and functions
# Auto-screen invocation. see: http://taint.org/wk/RemoteLoginAutoScreen
# if we're coming from a remote SSH connection, in an interactive session
# then automatically put us into a screen(1) session.   Only try once
# -- if $STARTED_SCREEN is set, don't try it again, to avoid looping
# if screen fails for some reason.
if [ "$PS1" != "" -a "${STARTED_SCREEN:-x}" = x -a "${SSH_TTY:-x}" != x ] 
then
    STARTED_SCREEN=1 ; export STARTED_SCREEN
    screen -RR -S main || echo "Screen failed! continuing with normal bash startup"
fi
# [end of auto-screen snippet]
