#!/bin/sh

set -o pipefail
set -o errexit
set -o nounset

# Script expects the following config vars
# IPV4_HOST=
# IPV6_HOST=
# IPV6_PREFIXLEN=
# IPV4_ROUTE=
# IPV6_ROUTE=
# NAT64_NETWORK=
# NAT64_HOST=
# NAT64_PREFIXLEN=
# ROOT_PK=
# HOSTNAME=
# MODE=ROUTED|BRIDGED

# Source CONFIG if exists
if [ -r ./CONFIG ]; then
    . ./CONFIG
fi

# Check we have config
: ${IPV4_HOST?Error: Config not found}

# Ensure /usr/local/bin on PATH
PATH="${PATH}:/usr/local/bin"

# Run updates
_log "freebsd-update fetch --not-running-from-cron"
_log "freebsd-update install --not-running-from-cron || echo No updates available"

# Bootstrap pkg
_log "env ASSUME_ALWAYS_YES=yes pkg bootstrap"
_log "pkg update"

# Install packages
_log "pkg install -y python3 git-lite rsync knot3"
PY_VER=$(python3 -c 'import sys;print("py",sys.version_info.major,sys.version_info.minor,sep="")')

_log "pkg install -y ${PY_VER}-pip"

# Configure loader.conf
_log "tee -a /boot/loader.conf" <<EOM
net.inet.ip.fw.default_to_accept=1
kern.racct.enable=1
EOM

# Set hostname
_log "sysrc hostname=\"${HOSTNAME}\""

# periodic.conf
_log "install -v -m 644 ./files/periodic.conf /etc"

# Configure standard rc.conf settings
_log "sysrc -x ifconfig_DEFAULT || echo"
_log "sysrc gateway_enable=YES \
            ipv6_gateway_enable=YES \
            defaultrouter=${IPV4_ROUTE} \
            ipv6_defaultrouter=${IPV6_ROUTE} \
            ip6addrctl_policy=ipv6_prefer \
            sshd_enable=YES \
            sshd_flags=\"-o PermitRootLogin=prohibit-password\" \
            firewall_enable=YES \
            firewall_logif=YES \
            firewall_nat64_enable=YES \
            firewall_script=/etc/ipfw.rules \
            syslogd_flags=-ss \
            sendmail_enable=NONE \
            zfs_enable=YES \
            knot_enable=YES \
            knot_config=/usr/local/etc/knot/knot.conf"

if [ "${MODE}" = "ROUTED" ]; then
    _log "sysrc cloned_interfaces=\"bridge0\" \
                ifconfig_vtnet0=\"inet ${IPV4_HOST} up\" \
                ifconfig_vtnet0_ipv6=\"inet6 ${IPV6_HOST} prefixlen ${IPV6_PREFIXLEN} auto_linklocal up\" \
                ifconfig_bridge0_ipv6=\"inet6 ${NAT64_HOST} prefixlen ${NAT64_PREFIXLEN} auto_linklocal up\" \
                ifconfig_bridge0_alias0=\"inet6 fe80::1\""
else
    _log "sysrc cloned_interfaces=\"bridge0\" \
                ifconfig_vtnet0=\"up\" \
                ifconfig_bridge0=\"inet ${IPV4_HOST} up\" \
                ifconfig_bridge0_ipv6=\"inet6 ${IPV6_HOST} prefixlen ${IPV6_PREFIXLEN} auto_linklocal up\""
    # Attach vtnet0 - work round 13.0 vtnet bug
    if [ $(uname -K) -gt 1300000 ]; then 
        _log "tee /etc/start_if.bridge0" <<EOM
ifconfig vtnet0 down
ifconfig bridge0 addm vtnet0
ifconfig vtnet0 up
EOM
    else
        _log "tee /etc/start_if.bridge0" <<EOM
ifconfig bridge0 addm vtnet0
EOM
    fi
fi

# SSHD keys
if [ ! -f /root/.ssh/authorized_keys ]; then
    _log "install -v -d -m 700 /root/.ssh"
    _log "install -v -m 600 /dev/null /root/.ssh/authorized_keys"
    _log "printf \"%s %s %s\n\" $ROOT_PK | tee -a /root/.ssh/authorized_keys"
fi

# Install devfs config files
_log "install -v -m 644 ./files/devfs.rules /etc"

# Configure IPFW
if [ "${MODE}" = "ROUTED" ]; then
    NAT64_NETWORK="${NAT64_NETWORK}/${NAT64_PREFIXLEN}"
else
    NAT64_NETWORK="${IPV6_HOST}/${IPV6_PREFIXLEN}"
fi
_log "install -v -m 755 ./files/ipfw.rules /etc/ipfw.rules"
_log "ex -s /etc/ipfw.rules" <<EOM
%s!__IPV4_HOST__!${IPV4_HOST}!gp
%s!__IPV6_HOST__!${IPV6_HOST}!gp
%s!__IPV4_NAT__!${IPV4_HOST}!gp
%s!__NAT64_NETWORK__!${NAT64_NETWORK}!gp
wq
EOM

# Configure knot
if [ "${MODE}" = "ROUTED" ]; then
    KNOT_IPV6="${NAT64_HOST}"
else
    KNOT_IPV6="${IPV6_HOST}"
fi

_log "install -v -m 644 ./files/knot.conf /usr/local/etc/knot"
_log "ex -s /usr/local/etc/knot/knot.conf" <<EOM
%s/__HOSTNAME__/${HOSTNAME}/gp
%s/__IPV6_ADDRESS__/${KNOT_IPV6}/gp
wq
EOM

_log "install -v -m 644 ./files/knot.zone /var/db/knot/${HOSTNAME}.zone"
_log "ex -s /var/db/knot/${HOSTNAME}.zone" <<EOM
%s/__HOSTNAME__/${HOSTNAME}/gp
%s/__IPV6_ADDRESS__/${KNOT_IPV6}/gp
wq
EOM

# Cosmetic tidy-up
_log "uname -a | tee /etc/motd"
_log "chsh -s /bin/sh root"
_log "install -v -m 644 files/dot.profile /root/.profile"
_log "install -v -m 644 files/dot.profile /usr/share/skel/"
_log "install -v -m 755 ./files/zone-set.sh /root"
_log "install -v -m 755 ./files/zone-del.sh /root"
_log "install -v -m 755 ./files/linux-init.sh /root"

# Create ZFS file
if ! zfs list zroot; then
    _log "truncate -s 10G /var/zroot"
    _log "zpool create zroot /var/zroot"
fi

# Create jail mountpoint
_log "zfs create -o mountpoint=/jail -o compression=lz4 zroot/jail"
_log "zfs create zroot/jail/base"

# Install base os
_log "( cd /jail/base && fetch -qo - http://ftp.freebsd.org/pub/FreeBSD/releases/amd64/amd64/$(uname -r | sed -e 's/-p[0-9]*$//')/base.txz | tar -xJf -)"
_log "zfs snap zroot/jail/base@release"

# Install v6jail
_log "pkg install -y gmake"
_log "/usr/local/bin/pip install shiv"

TMPDIR=$(mktemp -d)
(
    cd $TMPDIR
    _log "/usr/local/bin/git clone https://github.com/paulc/v6jail.git"
    _log "(cd v6jail && /usr/local/bin/gmake shiv && install -v -m 755 bin/v6 /usr/local/bin)"
    rm -rf $TMPDIR
)

# Install files to base
_log "install -v -m 644 files/rc.conf-jail /jail/base/etc/rc.conf"
_log "install -v -m 755 files/firstboot /jail/base/etc/rc.d"
_log "install -v -m 644 files/dot.profile /jail/base/usr/share/skel/"
_log "install -v -m 644 files/dot.profile /jail/base/root/.profile"
_log "install -v -m 644 files/resolv.conf-ipv6 /jail/base/etc/resolv.conf"
# _log "/usr/sbin/pw -R /jail/base usermod root -s /bin/sh -h -"
_log "uname -a | tee /jail/base/etc/motd"

# Need bridge0 to exist and have address for v6jail
_log "ifconfig bridge0 inet || ifconfig bridge0 create"

# Use hostname as salt for v6 (prevents jail names colliding on same network)
_log "hostname ${HOSTNAME}"
SALT=$(/usr/local/bin/python3 -c 'import hashlib,subprocess;print(hashlib.md5(subprocess.run("hostname",capture_output=True).stdout).hexdigest())')

# Create config file 
if [ "${MODE}" = "ROUTED" ]; then
    _log "ifconfig bridge0 inet6 ${NAT64_HOST} prefixlen ${NAT64_PREFIXLEN}"
    _log "/usr/local/bin/v6 config --salt $SALT --network ${NAT64_NETWORK} | tee /usr/local/etc/v6jail.ini"
else
    _log "ifconfig bridge0 inet6 ${IPV6_HOST} prefixlen ${IPV6_PREFIXLEN}"
    _log "/usr/local/bin/v6 config --salt $SALT | tee /usr/local/etc/v6jail.ini"
fi

# Update base
_log "/usr/local/bin/v6 update-base"

# Check for any local config 
if [ -f ./local.sh ]; then
    sh ./local.sh
fi

# Remove /firstboot and reboot
_log "rm -f /firstboot"
_log "reboot"

