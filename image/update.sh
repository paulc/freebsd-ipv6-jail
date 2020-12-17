#!/bin/sh

set -o pipefail errexit nounset

: ${LOCATION:=fsn1}
: ${TYPE:=cx11}
: ${IMAGE?ERROR: Must specify IMAGE}

TS=$(date +%Y%m%d-%H%M%S)
NAME="update-${TS}"

hcloud server create --location ${LOCATION} --type ${TYPE} --image ${IMAGE} --name ${NAME} --user-data-from-file - <<'EOM'
#!/bin/sh
( freebsd-update fetch --not-running-from-cron | head
  freebsd-update install --not-running-from-cron || echo No updates available
  pkg update 
  pkg upgrade -y
  rm /var/hcloud/*
  rm /etc/ssh/*key*
  touch /firstboot
  shutdown -p now ) 2>&1 | tee /var/log/update-$(date +%Y%m%d-%H%M%S).log
EOM

printf "Waiting for server shutdown"

while [ $(hcloud server describe -o format='{{.Status}}' $NAME) != "off" ]; do
    printf "."
    sleep 1
done

printf "\n"

hcloud server create-image --description "FreeBSD-12.2-base-${TYPE}-${TS}" --type snapshot ${NAME}

hcloud server delete ${NAME}

echo hcloud image delete ${IMAGE}
