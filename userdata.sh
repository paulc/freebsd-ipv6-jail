#!/bin/sh

set -o pipefail
set -o errexit
set -o nounset

pkg install -y git-lite

TMPDIR=$(mktemp -d)

cd $TMPDIR 

/usr/local/bin/git clone https://github.com/paulc/freebsd-ipv6-jail.git .

. ./utils.sh
. ./run.sh | tee /var/log/userdata.log
