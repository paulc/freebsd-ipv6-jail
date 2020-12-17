#!/bin/sh

: ${2?Usage: $0 [-c|-r] <id>}

case "$1" in
-c) 	(cat /etc/jail.conf; printf 'vnet%03d { $id=%d; }\n' $2 $2) \
		| jail -f- -v -c $(printf vnet%03d $2)
	;;
-r) 	(cat /etc/jail.conf; printf 'vnet%03d { $id=%d; }\n' $2 $2) \
		| jail -f- -v -r $(printf vnet%03d $2)
	;;
*) 	echo "Usage $0 [-c|-r] <id>"
	;;
esac
