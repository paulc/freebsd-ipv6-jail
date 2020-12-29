#!/usr/bin/env python3

import hashlib,ipaddress,re,struct,subprocess,sys

class JailHost:

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

    def __init__(self,name,host=None):

        # Check name can be encoded as ascii
        # name.encode("ascii")

        # Jail params
        self.name = name
        self.host = host or JailHost()
        self.ipv6 = self.host.generate_addr(name)
        self.hash = self.host.generate_hash(name)
        self.path = f"{self.host.mountpoint}/{self.hash}"
        self.zpath = f"{self.host.zroot}/{self.hash}"
        self.epair = (f"{self.hash}A",f"{self.hash}B")

        # Useful commands
        self.ifconfig       = lambda *args: self.host.cmd("ifconfig",*args)
        self.route6         = lambda *args: self.host.cmd("route","-6",*args)
        self.jail_route6    = lambda *args: self.host.cmd("jexec",self.hash,"route","-6",*args)
        self.jexec          = lambda *args: self.host.cmd("jexec",self.hash,*args)
        self.sysrc          = lambda *args: self.host.cmd("sysrc","-R",self.path,*args)
        self.zfs_clone      = lambda *args: self.host.cmd("zfs","clone",*args)
        self.zfs_destroy    = lambda *args: self.host.cmd("zfs","destroy",self.zpath)
        self.zfs_set        = lambda *args: self.host.cmd("zfs","set",*args,self.zpath)
        self.jail_create    = lambda *args: self.host.cmd("jail","-cv",*args)
        self.jail_stop      = lambda *args: self.host.cmd("jail","-Rv",self.hash)
        self.umount_devfs   = lambda *args: self.host.cmd("umount",f"{self.path}/dev")

    def create_epair(self):
        epair = self.ifconfig("epair","create")[:-1]
        epair_host,epair_jail = self.epair
        self.ifconfig(f"{epair}a","name",epair_host)
        self.ifconfig(f"{epair}b","name",epair_jail)
        self.ifconfig(epair_host,"inet6","auto_linklocal","up")
        self.ifconfig(self.host.bridge,"addm",epair_host,
                                       "private",epair_host)

    def remove_vnet(self):
        self.ifconfig(self.epair[1],"-vnet",self.hash)

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
        self.jail_route6("add",self.host.hostaddr,f"{lladdr_host}%{epair_jail}")

    def create_fs(self):
        self.zfs_clone(self.host.get_latest_snapshot(),self.zpath)
        self.zfs_set(f"jail:name={self.name}",f"jail:ipv6={self.ipv6}")

    def destroy_fs(self):
        self.zfs_destroy(self.zpath)

    def check_cmd(self,*args):
        try:
            self.host.cmd(*args)
            return True
        except subprocess.CalledProcessError:
            return False

    def running(self):
        return self.check_cmd("jls","-Nj",self.hash)

    def check_fs(self):
        return self.check_cmd("zfs","list",self.zpath)

    def check_epair(self):
        return self.check_cmd("ifconfig",self.epair[0])

    def check_devfs(self):
        return self.check_cmd("ls",f"{self.path}/dev/zfs")

    def configure(self):
        epair_host,epair_jail = self.epair
        self.sysrc(f"ifconfig_{epair_jail}_ipv6=inet6 {self.ipv6}/64",
                   f"ipv6_defaultrouter=fe80::1%{epair_jail}")

    def clean(self):
        self.stop()
        if self.check_devfs():
            self.umount_devfs()
        if self.check_fs():
            self.destroy_fs()
        if self.check_epair():
            self.destroy_epair()

    def start(self):
        if not self.running():
            params = self.host.DEFAULT_PARAMS.copy()
            params["name"] = self.hash
            params["path"] = self.path
            params["vnet.interface"] = self.epair[1]
            params["host.hostname"] = self.name
            self.create_epair()
            self.jail_create(*[f"{k}={v}" for k,v in params.items()])
            self.local_route()
        else:
            raise ValueError(f"Jail running: {self.name} ({self.hash})")

    def stop(self):
        if self.running():
            self.remove_vnet()
            self.jail_stop()
            self.umount_devfs()
            self.destroy_epair()
        else:
            raise ValueError(f"Jail not running: {self.name} ({self.hash})")

    def run(self):
        self.create_fs()
        self.configure()
        self.start()

    def kill(self):
        self.stop()
        self.destroy_fs()

