#!/bin/sh

set -o pipefail
set -o errexit
set -o nounset

# Get network configuration
IPV4_ADDRESS=${IPV4_ADDRESS-$(tr -d \" < /var/hcloud/public-ipv4)}
IPV6_ADDRESS=${IPV6_ADDRESS-$(/usr/local/bin/python3 -c 'import json;c=json.load(open("/var/hcloud/network-config"));print([x["address"].split("/")[0] for x in c["config"][0]["subnets"] if x.get("ipv6")][0])')}
HOSTNAME=${HOSTNAME-$(/usr/local/bin/python3 -c 'import yaml;print(yaml.safe_load(open("/var/hcloud/cloud-config"))["fqdn"])')}

# Run updates
_log "freebsd-update fetch --not-running-from-cron | head"
_log "freebsd-update install --not-running-from-cron || echo No updates available"
_log "pkg update"
_log "pkg upgrade -y"

# Configure loader.conf
_log "tee -a /boot/loader.conf" <<EOM
net.inet.ip.fw.default_to_accept=1
kern.racct.enable=1
EOM

# Set hostname to FQDN
_log "hostname $HOSTNAME"

# Install packages
_log "pkg install -y $(pkg search -q '^py3[0-9]+-pip-[0-9]')"
_log "pkg install -y knot3"

# Configure rc.conf
_log "sysrc gateway_enable=YES \
            ipv6_gateway_enable=YES \
            ip6addrctl_policy=ipv6_prefer \
            cloned_interfaces="bridge0" \
            ifconfig_bridge0=\"up addm vtnet0\" \
            firewall_enable=YES \
            firewall_logif=YES \
            firewall_nat64_enable=YES \
            firewall_script=/etc/ipfw.rules \
            syslogd_flags=-ss \
            sendmail_enable=NONE \
            zfs_enable=YES \
            knot_enable=YES \
            knot_config=/usr/local/etc/knot/knot.conf"

# Install config files
_log "install -v -m 644 ./files/devfs.rules /etc"

# Configure IPFW
_log "install -v -m 755 ./files/ipfw.rules /etc"
_log "ex -s /etc/ipfw.rules" <<EOM
g/__IPV4_ADDRESS__/s/__IPV4_ADDRESS__/${IPV4_ADDRESS}/p
g/__IPV6_ADDRESS__/s/__IPV6_ADDRESS__/${IPV6_ADDRESS}/p
wq
EOM

# Configure knot
_log "install -v -m 644 ./files/knot.conf /usr/local/etc/knot"
_log "ex -s /usr/local/etc/knot/knot.conf" <<EOM
g/__HOSTNAME__/s/__HOSTNAME__/${HOSTNAME}/p
wq
EOM

_log "install -v -m 644 ./files/knot.zone /var/db/knot/${HOSTNAME}.zone"
_log "ex -s /var/db/knot/${HOSTNAME}.zone" <<EOM
g/__HOSTNAME__/s/__HOSTNAME__/${HOSTNAME}/g
g/__IPV4_ADDRESS__/s/__IPV4_ADDRESS__/${IPV4_ADDRESS}/g
g/__IPV6_ADDRESS__/s/__IPV6_ADDRESS__/${IPV6_ADDRESS}/g
1,\$p
wq
EOM

# Cosmetic tidy-up
_log "uname -a | tee /etc/motd"
_log "chsh -s /bin/sh root"
_log "install -v -m 644 files/dot.profile /root/.profile"
_log "install -v -m 644 files/dot.profile /usr/share/skel/"
_log "install -v -m 755 ./files/zone-set.sh /root"
_log "install -v -m 755 ./files/zone-del.sh /root"

# Create ZFS volume for jails (grow disk if possible)
if gpart show da0 | grep -qs CORRUPT
then
    # Wrong disk size - fix and add zfs partition
    _log "gpart recover da0"
    _log "gpart add -t freebsd-zfs da0"
    _log "zpool create zroot $(gpart show da0 | awk '/freebsd-zfs/ { print "/dev/da0p" $3 }')"
else 
    # Create ZFS file
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
_log "/usr/local/bin/pip install https://github.com/paulc/v6jail/releases/download/v6jail-1.0/v6jail-1.0.tar.gz"

# Install files to base
_log "install -v -m 644 files/rc.conf-jail /jail/base/etc/rc.conf"
_log "install -v -m 755 files/firstboot /jail/base/etc/rc.d"
_log "install -v -m 644 files/dot.profile /jail/base/usr/share/skel/"
_log "install -v -m 644 files/dot.profile /jail/base/root/.profile"
_log "install -v -m 644 files/resolv.conf-ipv6 /jail/base/etc/resolv.conf"
_log "/usr/sbin/pw -R /jail/base usermod root -s /bin/sh -h -"
_log "uname -a | tee /jail/base/etc/motd"

# Need bridge0 to exist for v6jail
_log "ifconfig bridge0 inet || ifconfig bridge0 create"

# Update base
_log "/usr/local/bin/python3 -m v6jail.cli update-base"

# Remove /firstboot and reboot
_log "rm -f /firstboot"
_log "reboot"

