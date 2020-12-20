#!/bin/sh

set -o pipefail errexit nounset

_NORMAL=$(printf "\033[0m")
_RED=$(printf "\033[0;31m")
_YELLOW=$(printf "\033[0;33m")
_CYAN=$(printf "\033[0;36m")

_COLOUR=

_log() {
    local _cmd="$@"
    printf "${_COLOUR:+${_YELLOW}}"
    printf "%s [%s]\n" "$(date '+%b %d %T')" "CMD: $_cmd"
    printf "${_COLOUR:+${_CYAN}}"
    eval "$_cmd" 2>&1 | sed -e 's/^/     | /'
    local _status=$?
    if [ $_status -eq 0 ]
    then
        printf "${_COLOUR:+${_YELLOW}}[OK]\n"
    else
        printf "${_COLOUR:+${_RED}}[ERROR]\n"
    fi
    printf "${_COLOUR:+${_NORMAL}}"
    return $_status
}

_install_stdin() {
    local _args=""
    local _tmp=$(mktemp) || return $?
    local _opts=$(getopt bCcdpSsUvB:D:f:g:h:l:M:m:N:o:T: $*) || return $?
    set -- $_opts
    while :; do
      case "$1" in
        --) shift;break
            ;;
        *)  _args="${_args} $1";shift
            ;;
      esac
    done
    tee -a ${_tmp} 2>&1
    install ${_args} ${_tmp} $*
    local _status=$?
    rm -f ${_tmp}
    return $_status
}

_err() {
    echo ERROR: $@ >&1
    exit 1
}
