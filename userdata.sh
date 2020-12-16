#!/bin/sh

set -o pipefail errexit nounset

pkg install -y git-lite

TMPDIR=$(mktemp -d)

cd $TMPDIR 

pwd

/usr/local/bin/git clone https://github.com/paulc/freebsd-ipv6-jail.git .

. ./utils.sh
. ./run.sh
