
. ./utils.sh

_log "tee /etc/resolv.conf" <<EOM
nameserver 2a01:4ff:ff00::add:1
nameserver 2a01:4ff:ff00::add:2
EOM

_log "sysrc static_routes=default route_default=\"${IPV4_ROUTE} -iface vtnet0\""
