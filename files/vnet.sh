#!/bin/sh

set -o errexit
set -o pipefail
set -o nounset

USAGE="Usage: $0 [-c <id>|-r <id>] [-n <name_template>] [jail_args...]"

args=$(getopt c:r:n: $*) || echo ${__?${USAGE}}
template="vnet%03d"

set -- $args

while :; do
	case "$1" in
	-c)	mode="-c"
		id="$2"
		shift; shift
		;;
	-r)	mode="-r"
		id="$2"
		shift; shift
		;;
	-n)	template="$2"
		shift; shift
		;;
	--)	shift; break
		;;
	esac
done

: ${mode?$USAGE}

jname=$(printf "$template" $id)
jargs=$(printf "%s;" $@)

(cat /etc/jail.conf; printf "%s { \$id=%d; $jargs }\n" $jname $id) \
		| jail -f- -v $mode $jname

