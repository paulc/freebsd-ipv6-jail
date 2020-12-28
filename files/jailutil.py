#!/usr/bin/env python3

import hashlib,ipaddress,re,struct,subprocess,sys

class JailConf:

    DEFAULT_PARAMS = {
            "allow.set_hostname":   False,
            "allow.raw_sockets":    True,
            "allow.socket_af":      True,
            "allow.sysvipc":        True,
            "allow.chflags":        True,
            "mount.devfs":          True,
            "devfs_ruleset":        4,
            "enforce_statfs":       2,
            "sysvmsg":              "new",
            "sysvsem":              "new",
            "sysvshm":              "new",
            "children.max":         0,
            "osrelease":            "12.2-RELEASE",
            "vnet":                 1,
            "vnet.interface":       None,
            "persist":              True,
            "exec.start":           "/bin/sh /etc/rc",
    }

    def __init__(self,hostaddr=None,prefix=None,zroot="zroot/jail",bridge="bridge0",debug=False):
        self.debug = debug
        self.zroot = zroot
        self.bridge = bridge
        self.hostaddr = hostaddr or self.host_ipv6()
        self.prefix = prefix or ipaddress.IPv6Address(self.hostaddr).exploded[:19]
        self.mountpoint = self.get_mountpoint(zroot)

    def cmd(self,*args):
        try:
            result = subprocess.run(args,capture_output=True,check=True)
            out = result.stdout.strip().decode()
            if self.debug:
                print("CMD:",args)
                if out:
                    print("\n".join([f"   | {l}" for l in out.split("\n")]))
            return out
        except subprocess.CalledProcessError as e:
            if self.debug:
                err = e.stderr.strip().decode("utf8","ignore")
                print("ERR:",args)
                if err:
                    print("\n".join([f"   ! {l}" for l in err.split("\n")]))
            raise

    def host_ipv6(self):
        (default_if,) = re.search("interface: (.*)",
                                    self.cmd("route","-6","get","default")).groups()
        (ipv6,) = re.search("inet6 (?!fe80::)(\S*)",
                                    self.cmd("ifconfig",default_if,"inet6")).groups()
        return ipv6

    def get_mountpoint(self,vol):
        return self.cmd("zfs","list","-H","-o","mountpoint",vol)

    def generate_addr(self,name):
        a,b,c,d = struct.unpack("4H",hashlib.blake2b(name.encode('utf8'),digest_size=8).digest())
        return "{}:{:x}:{:x}:{:x}:{:x}".format(self.prefix,a,b,c,d)

    def generate_hash(self,name):
        return hashlib.blake2b(name.encode('utf8'),digest_size=7).hexdigest()

    def get_latest_snapshot(self):
        out = self.cmd("zfs", "list", "-Hrt", "snap", "-s", "creation", "-o", "name", 
                              f"{self.zroot}/base")
        if out:
            return out.split("\n")[-1]
        else:
            raise ValueError(f"No snapshots found: {path}")

    def jail(self,name):
        return Jail(name,self)
        

class Jail:

    def __init__(self,name,conf=None):

        # Check name cane be encoded as ascii
        name.encode("ascii")

        # Jail params
        self.name = name
        self.conf = conf or JailConf()
        self.ipv6 = self.conf.generate_addr(name)
        self.path = f"{self.conf.mountpoint}/{self.name}"
        self.zpath = f"{self.conf.zroot}/{self.name}"
        self.hash = self.conf.generate_hash(name)
        self.epair = (f"{self.hash}A",f"{self.hash}B")

        # Useful commands
        self.ifconfig       = lambda *args: self.conf.cmd("ifconfig",*args)
        self.route6         = lambda *args: self.conf.cmd("route","-6",*args)
        self.jail_route6    = lambda *args: self.conf.cmd("jexec",self.name,"route","-6",*args)
        self.jexec          = lambda *args: self.conf.cmd("jexec",self.name,*args)
        self.sysrc          = lambda *args: self.conf.cmd("sysrc","-R",self.path,*args)
        self.zfs_clone      = lambda *args: self.conf.cmd("zfs","clone",*args)
        self.zfs_destroy    = lambda *args: self.conf.cmd("zfs","destroy",self.zpath)
        self.jail_create    = lambda *args: self.conf.cmd("jail","-cv",*args)
        self.jail_stop      = lambda *args: self.conf.cmd("jail","-Rv",self.name)
        self.umount_devfs   = lambda *args: self.conf.cmd("umount",f"{self.path}/dev")

    def create_epair(self):
        epair = self.ifconfig("epair","create")[:-1]
        epair_host,epair_jail = self.epair
        self.ifconfig(f"{epair}a","name",epair_host)
        self.ifconfig(f"{epair}b","name",epair_jail)
        self.ifconfig(epair_host,"inet6","auto_linklocal","up")
        self.ifconfig(self.conf.bridge,"addm",epair_host,
                                       "private",epair_host)

    def remove_vnet(self):
        self.ifconfig(self.epair[1],"-vnet",self.name)

    def destroy_epair(self):
        self.ifconfig(self.epair[0],"destroy")

    def get_lladdr(self):
        (lladdr_host,) = re.search("inet6 (fe80::.*?)%",self.ifconfig(self.epair[0])).groups()
        lladdr_jail = lladdr_host[:-1] + "b"
        return (lladdr_host,lladdr_jail)

    def local_route(self):
        epair_host,epair_jail = self.epair
        lladdr_host,lladdr_jail = self.get_lladdr()
        self.route6("add",self.ipv6,f"{lladdr_jail}%{epair_host}")
        self.jail_route6("add",self.conf.hostaddr,f"{lladdr_host}%{epair_jail}")

    def create_fs(self):
        self.zfs_clone(self.conf.get_latest_snapshot(),self.zpath)

    def destroy_fs(self):
        self.zfs_destroy(f"{self.conf.zroot}/{self.name}")

    def configure(self):
        epair_host,epair_jail = self.epair
        self.sysrc("sendmail_enable=NONE",
                   "syslogd_flags=-ss",
                   "ip6addrctl_policy=ipv6_prefer",
                   f"ifconfig_{epair_jail}_ipv6=inet6 {self.ipv6}/64",
                   f"ipv6_defaultrouter=fe80::1%{epair_jail}")

    def start(self):
        params = self.conf.DEFAULT_PARAMS.copy()
        params["name"] = self.name
        params["path"] = self.path
        params["vnet.interface"] = self.epair[1]
        params["host.hostname"] = self.name
        self.create_epair()
        self.jail_create(*[f"{k}={v}" for k,v in params.items()])
        self.local_route()

    def stop(self):
        # XXX Check if running?
        self.remove_vnet()
        self.jail_stop()
        self.umount_devfs()
        self.destroy_epair()

    def run(self):
        self.create_fs()
        self.configure()
        self.start()

    def kill(self):
        self.stop()
        self.destroy_fs()

