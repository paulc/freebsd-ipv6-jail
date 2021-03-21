#!/bin/sh

set -o pipefail
set -o errexit
set -o nounset

# Ensure /usr/local/bin on PATH
PATH="${PATH}:/usr/local/bin"

# Get network configuration from metadata
IPV4_ADDRESS=${IPV4_ADDRESS-$(tr -d \" < /var/hcloud/public-ipv4)}
IPV6_ADDRESS=${IPV6_ADDRESS-$(/usr/local/bin/python3 -c 'import json;c=json.load(open("/var/hcloud/network-config"));print([x["address"].split("/")[0] for x in c["config"][0]["subnets"] if x.get("ipv6")][0])')}
HOSTNAME=${HOSTNAME-$(/usr/local/bin/python3 -c 'import yaml;print(yaml.safe_load(open("/var/hcloud/cloud-config"))["fqdn"])')}

# Get /65 subnet for bridge0
SUBNET=$(/usr/local/bin/python3 -c 'import sys,ipaddress;print(next(list(ipaddress.IPv6Network(sys.argv[1],False).subnets())[1].hosts()))' ${IPV6_ADDRESS}/64)

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

# Set hostname
_log "sysrc hostname=\"${HOSTNAME}\""

# Install packages
_log "pkg install -y $(pkg search -q '^py3[0-9]+-pip-[0-9]')"
_log "pkg install -y knot3"

# Configure rc.conf
_log "sysrc gateway_enable=YES \
            ipv6_gateway_enable=YES \
            cloned_interfaces=bridge0 \
            ifconfig_vtnet0_ipv6=\"inet6 ${IPV6_ADDRESS} prefixlen 128\" \
            ifconfig_bridge0_ipv6=\"inet6 ${SUBNET} prefixlen 65\" \
            ip6addrctl_policy=ipv6_prefer \
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
%s/__IPV4_ADDRESS__/${IPV4_ADDRESS}/gp
%s/__IPV6_ADDRESS__/${IPV6_ADDRESS}/gp
wq
EOM

# Configure knot
_log "install -v -m 644 ./files/knot.conf /usr/local/etc/knot"
_log "ex -s /usr/local/etc/knot/knot.conf" <<EOM
%s/__HOSTNAME__/${HOSTNAME}/gp
wq
EOM

_log "install -v -m 644 ./files/knot.zone /var/db/knot/${HOSTNAME}.zone"
_log "ex -s /var/db/knot/${HOSTNAME}.zone" <<EOM
%s/__HOSTNAME__/${HOSTNAME}/gp
%s/__IPV4_ADDRESS__/${IPV4_ADDRESS}/gp
%s/__IPV6_ADDRESS__/${IPV6_ADDRESS}/gp
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
_log "pkg install -y gmake"
_log "/usr/local/bin/pip install shiv"
_log "/usr/local/bin/git clone https://github.com/paulc/v6jail.git"
_log "(cd v6jail && /usr/local/bin/gmake shiv && install -v -m 755 bin/v6 /usr/local/bin)"

# Install files to base
_log "install -v -m 644 files/rc.conf-jail /jail/base/etc/rc.conf"
_log "install -v -m 755 files/firstboot /jail/base/etc/rc.d"
_log "install -v -m 644 files/dot.profile /jail/base/usr/share/skel/"
_log "install -v -m 644 files/dot.profile /jail/base/root/.profile"
_log "install -v -m 644 files/resolv.conf-ipv6 /jail/base/etc/resolv.conf"
_log "/usr/sbin/pw -R /jail/base usermod root -s /bin/sh -h -"
_log "uname -a | tee /jail/base/etc/motd"

# Need bridge0 to exist and have address for v6jail
_log "ifconfig bridge0 inet || ifconfig bridge0 create"
_log "ifconfig bridge0 inet6 ${SUBNET} prefixlen 65"

# Update base
_log "/usr/local/bin/v6 update-base"

# Create config file 
_log "/usr/local/bin/v6 config --proxy true | tee /usr/local/etc/v6jail.ini"

# Remove /firstboot and reboot
_log "rm -f /firstboot"
_log "reboot"

