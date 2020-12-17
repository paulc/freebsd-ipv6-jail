#!/bin/sh

set -o pipefail errexit nounset

: ${LOCATION:=fsn1}
: ${TYPE:=cx11}
: ${IMAGE?ERROR: Must specify IMAGE}

hcloud server create --location $LOCATION --type $TYPE --image $IMAGE --name img-update --user-data-from-file - <<'EOM'
#!/bin/sh
( freebsd-update fetch --not-running-from-cron | cat
  freebsd-update install --not-running-from-cron || echo No updates available
  pkg update 
  pkg upgrade -y
  rm /var/hcloud/*
  rm /etc/ssh/*key*
  touch /firstboot
  shutdown -p now ) 2>&1 | tee /var/log/update-$(date +%Y%m%d-%H%M%S).log
EOM

hcloud server create-image --description "FreeBSD-12.2-base-cx11-$(date +%Y%m%d-%H%M%S)" --type snapshot img-update

hcloud server delete img-update

hcloud image delete $IMAGE
