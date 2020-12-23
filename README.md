
This repository provides a framework for automatically configuring a
[FreeBSD](https://www.freebsd.org) instance provisioned on 
[Hetzner Cloud](https://www.hetzner.com/cloud) as an IPv6 VNET jail server.

This assumes that the base FreeBSD instance has been configured using 
the [hcloud-freebsd](https://github.com/paulc/hcloud-freebsd) tool
and provides a [userdata.sh](./userdata.sh) script that bootstraps 
the configuration.

The rough sequence of events is:

- User provisions instance either using the web interface or
  [hcloud](https://github.com/hetznercloud/cli) cli utility - ie:

    * `hcloud server create-image --location ${LOCATION} --type ${TYPE} --image ${IMAGE} --name ${NAME} --ssh-key ${SSHKEY} --user-data-from-file [userdata.sh[(./userdata.sh)'`

- The `hcloud` utility configures the server and runs the 
  [userdata.sh](./userdata.sh) script 

- The [userdata.sh](./userdata.sh) install the `git-lite` package and uses
  this to clone the repository into a temporary directory

- From the temporary directory [userdata.sh](./userdata.sh) sources some 
  utility functions from [utils.sh](./utils.sh) and then sources the 
  main installation script [run.sh](./run.sh)

- The [run.sh](./run.sh) script can be confiigured as needed. Files needed 
  for installation are in the [files](./files) directory and can then be 
  installed to the host using the `install` utility (or other).

- For this example it configures the server as a jail host with:

    * ZFS filesystem for jails (/jail)
    * Base jail in /jail/base 
    * `jail.conf` file setup to allow dynamic craetion of IPv6 VNET jails 
      from /jail/base
    * NAT64 running on host (via IPFW) to allow IPv4 connectivity from
      jails

