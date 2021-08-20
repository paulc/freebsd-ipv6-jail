#!/bin/sh

set -o pipefail
set -o errexit
set -o nounset

# Ensure /usr/local/bin on PATH
PATH="${PATH}:/usr/local/bin"

# Assume systems configured via hcloud 
export IPV4_HOST=$(ifconfig vtnet0 inet | awk '/inet/ { print $2; exit }')
export IPV6_HOST=$(ifconfig vtnet0 inet6 | awk '/inet6/ && !/fe80::/ { print $2; exit }')
export IPV6_PREFIXLEN=128
export IPV4_ROUTE=$(route -4 get default | awk '/gateway:/ { print $2 }')
export IPV6_ROUTE=$(route -6 get default | awk '/gateway:/ { print $2 }')
export NAT64_NETWORK=__NAT64_NETWORK__
export NAT64_HOST=__NAT64_HOST__
export NAT64_PREFIXLEN=64
export HOSTNAME=$(hostname)
export MODE=ROUTED

pkg install -y git-lite
TMPDIR=$(mktemp -d)
cd $TMPDIR 

/usr/local/bin/git clone https://github.com/paulc/freebsd-ipv6-jail.git .

. ./utils.sh
( . ./run.sh | tee /var/log/config.log ) || /bin/sh

