#!/bin/sh

set -o errexit         
set -o pipefail
set -o nounset

USAGE="Usage: $0 <name> <ipv6_prefix> <id>"

NAME=${1?ERROR}
IPV6_PREFIX=${2?$USAGE}
ID=${3?$USAGE}

HOST_ROUTE=$(ifconfig epair${ID}a inet6 | awk '/fe80::/ { split($2,a,"%");sub("a$","b",a[1]);print a[1] "%" a[2] }')
JAIL_ROUTE=$(ifconfig epair${ID}a inet6 | awk '/fe80::/ { split($2,a,"%");sub("a$","b",a[2]);print a[1] "%" a[2] }')

# Add host route
route -6 add ${IPV6_PREFIX}::1000:${ID} ${HOST_ROUTE}

# Add jail route
jexec ${NAME} route -6 add ${IPV6_PREFIX}::1 ${JAIL_ROUTE}
