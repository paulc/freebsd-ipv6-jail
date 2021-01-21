

# Get network configuration

IPV6_PREFIX=$(/usr/local/bin/python3 -c 'import json;c=json.load(open("/var/hcloud/network-config"));print([x["address"].split("::")[0] for x in c["config"][0]["subnets"] if x.get("ipv6")][0])')
IPV4_PREFIX=$(tr -d \" < /var/hcloud/public-ipv4)

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

# Install packages
_log "pkg install -y $(pkg search -q '^py3[0-9]+-pip-[0-9]')"

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
            zfs_enable=YES"

# Install config files
_log "install -v ./files/devfs.rules /etc"

_log "install -v -m 755 ./files/ipfw.rules /etc"
_log "ex -s /etc/ipfw.rules" <<EOM
g/IPV4_PREFIX/s/__IPV4_PREFIX__/${IPV4_PREFIX}/p
g/IPV6_PREFIX/s/__IPV6_PREFIX__/${IPV6_PREFIX}/p
wq
EOM

# Create ZFS volume for jails (grow disk if possible)
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

# Create jail mountpoint
_log "zfs create -o mountpoint=/jail -o compression=lz4 zroot/jail"
_log "zfs create zroot/jail/base"

# Install base os
_log "( cd /jail/base && fetch -o - http://ftp.freebsd.org/pub/FreeBSD/releases/amd64/amd64/$(uname -r | sed -e 's/-p[0-9]*$//')/base.txz | tar -xJf -)"
_log "zfs snap zroot/jail/base@release"

# Install v6jail
_log "/usr/local/bin/pip install https://github.com/paulc/v6jail/releases/download/v6jail-1.0/v6jail-1.0.tar.gz"

# Update base

# Need bridge0 to exist
_log "ifconfig bridge0 create"
_log "/usr/local/bin/python3 -m v6jail.cli update-base"

# Install files to base
_log "install -v -m 755 files/firstboot /jail/base/etc/rc.d"

# Configure base
_log "/usr/local/bin/python3 -m v6jail.cli chroot-base --snapshot" <<EOM
printf 'nameserver %s\n' 2001:4860:4860::6464 2001:4860:4860::64 | tee /etc/resolv.conf
sysrc sendmail_enable=NONE syslogd_flags="-C -ss"
EOM

# Cosmetic tidy-up
_log "uname -a > /etc/motd"
_log "chsh -s /bin/sh root"
_log "install -v files/dot.profile /root/.profile"
_log "install -v files/dot.profile /usr/share/skel/"

_log "rm -f /firstboot"
_log "reboot"

