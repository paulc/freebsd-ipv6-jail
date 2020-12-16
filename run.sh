
IPV6_PREFIX=$(/usr/local/bin/python3 -c 'import json;c=json.load(open("/var/hcloud/network-config"));print([x["address"].split("::")[0] for x in c["config"][0]["subnets"] if x.get("ipv6")][0])')

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

_log truncate -s 10G /var/zroot
_log zpool create zroot /var/zroot
_log zfs create -o mountpoint=/jail zroot/jail
_log zfs create zroot/jail/base
_log "( cd /jail/base && fetch -o - http://ftp.freebsd.org/pub/FreeBSD/releases/amd64/amd64/$(uname -r)/base.txz | tar -xJf -)"
_log "printf 'nameserver %s\n' 2001:4860:4860::6464 2001:4860:4860::64 | tee /jail/base/etc/resolv.conf"
_log zfs snap zroot/jail/base@release

_log "freebsd-update fetch --not-running-from-cron | cat"
_log "freebsd-update install --not-running-from-cron || echo No updates available"

_log rm -f /firstboot
_log reboot
