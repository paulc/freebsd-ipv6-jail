
IPV6_PREFIX=$(/usr/local/bin/python3 -c 'import json;c=json.load(open("/var/hcloud/network-config"));print([x["address"].split("::")[0] for x in c["config"][0]["subnets"] if x.get("ipv6")][0])')
IPV4_PREFIX=$(tr -d \" < /var/hcloud/public-ipv4)

_log "freebsd-update fetch --not-running-from-cron | cat"
_log "freebsd-update install --not-running-from-cron || echo No updates available"
_log "pkg update"
_log "pkg upgrade -y"

_log sysrc  gateway_enable=YES \
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
            zfs_enable=YES 

_log tee -a /boot/loader.conf <<EOM
net.inet.ip.fw.default_to_accept=1
kern.racct.enable=1
EOM

_log install -v ./files/jail.conf /etc

_log ex -s /etc/jail.conf <<EOM
g/IPV6_PREFIX/s/IPV6_PREFIX/${IPV6_PREFIX}/p
wq
EOM

_log install -v -m 755 ./files/ipfw.rules /etc
_log ex -s /etc/ipfw.rules <<EOM
g/IPV4_PREFIX/s/__IPV4_PREFIX__/${IPV4_PREFIX}/p
g/IPV6_PREFIX/s/__IPV6_PREFIX__/${IPV6_PREFIX}/p
wq
EOM

_log install -v -m 755 ./files/vnet.sh /root
_log install -v -m 755 ./files/route_epair.sh /root

if gpart show da0 | grep -qs CORRUPT
then
    # Wrong disk size - fix and add zfs partition
    _log gpart recover da0
    _log gpart add -t freebsd-zfs da0
    _log zpool create zroot $(gpart show da0 | awk '/freebsd-zfs/ { print "/dev/da0p" $3 }')
else 
    # Create ZFS file
    _log truncate -s 10G /var/zroot
    _log zpool create zroot /var/zroot
fi

_log "zfs create -o mountpoint=/jail -o compression=lz4 zroot/jail"
_log "zfs create zroot/jail/base"

_log "( cd /jail/base && fetch -o - http://ftp.freebsd.org/pub/FreeBSD/releases/amd64/amd64/$(uname -r | sed -e 's/-p[0-9]*$//')/base.txz | tar -xJf -)"
_log "zfs snap zroot/jail/base@release"

_log "printf 'nameserver %s\n' 2001:4860:4860::6464 2001:4860:4860::64 | tee /jail/base/etc/resolv.conf"
_log "sysrc -f /jail/base/etc/rc.conf sendmail_enable=NONE syslogd_flags=-ss"

# Run updates inside /jail/base
_log "mount -t devfs -o ruleset=2 devfs /jail/base/dev"
_log "chroot /jail/base /usr/sbin/freebsd-update --not-running-from-cron fetch | head"
_log "chroot /jail/base /usr/sbin/freebsd-update --not-running-from-cron install || echo No updates available"
_log "chroot /jail/base /usr/bin/env ASSUME_ALWAYS_YES=true /usr/sbin/pkg bootstrap -f"
_log "chroot /jail/base /usr/bin/env ASSUME_ALWAYS_YES=true /usr/sbin/pkg update"
_log "umount -f /jail/base"

_log "zfs snap zroot/jail/base@$(date +%s)"

_log rm -f /firstboot
_log reboot
