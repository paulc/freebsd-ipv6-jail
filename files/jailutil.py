#!/usr/bin/env python3

import code,functools,hashlib,io,ipaddress,os,re,shutil,struct,subprocess,sys,tempfile,time

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
            "osrelease":            "",
            "vnet":                 "new",
            "vnet.interface":       "",
            "persist":              True,
            "exec.start":           "/bin/sh /etc/rc",
    }

    def __init__(self,hostif=None,hostipv6=None,prefix=None,gateway=None,
                    base="base",zroot="zroot/jail",bridge="bridge0",debug=False):
        self.debug = debug
        self.zroot = zroot
        self.bridge = bridge
        self.base = base
        self.hostif = hostif or self.host_default_if()
        self.hostipv6 = hostipv6 or self.host_ipv6(self.hostif)
        self.gateway = gateway or self.host_gateway()
        self.prefix = prefix or ipaddress.IPv6Address(self.hostipv6).exploded[:19]
        self.mountpoint = self.get_mountpoint(self.zroot)

        if not self.check_cmd("zfs","list",f"{self.zroot}/{self.base}"):
            raise ValueError(f"base not found: {self.zroot}/{self.base}")

        if not self.check_cmd("ifconfig",self.bridge):
            raise ValueError(f"bridge not found: {self.bridge}")

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

    def check_cmd(self,*args):
        try:
            self.cmd(*args)
            return True
        except subprocess.CalledProcessError:
            return False

    def host_default_if(self):
        (default_if,) = re.search("interface: (.*)",
                                    self.cmd("route","-6","get","default")).groups()
        return default_if

    def host_ipv6(self,default_if):
        (ipv6,) = re.search("inet6 (?!fe80::)(\S*)",
                                    self.cmd("ifconfig",default_if,"inet6")).groups()
        return ipv6

    def host_gateway(self):
        (gateway,) = re.search("gateway: (.*)",
                                    self.cmd("route","-6","get","default")).groups()
        return gateway

    def get_mountpoint(self,vol):
        return self.cmd("zfs","list","-H","-o","mountpoint",vol)

    def generate_addr(self,name):
        a,b,c,d = struct.unpack("4H",hashlib.blake2b(name.encode('utf8'),digest_size=8).digest())
        return "{}:{:x}:{:x}:{:x}:{:x}".format(self.prefix,a,b,c,d)

    def generate_gateway(self,interface):
        if "%" in self.gateway:
            # Link local address
            return f"{self.gateway.split('%')[0]}%{interface}"
        else:
            # Assume gateway directly reachable via interface
            return self.gateway

    def generate_hash(self,name):
        return hashlib.blake2b(name.encode('utf8'),digest_size=7).hexdigest()

    def name_from_hash(self,jail_hash):
        try:
            name = self.cmd("zfs","list","-Ho","jail:name",f"{self.zroot}/{jail_hash}")
            if name == "-":
                raise ValueError(f"jail:name not found: {self.zroot}/{jail_hash}")
            return name
        except subprocess.CalledProcessError:
            pass
        raise ValueError(f"ZFS volume not found: {self.zroot}/{jail_hash}")

    def get_latest_snapshot(self):
        out = self.cmd("zfs", "list", "-Hrt", "snap", "-s", "creation", "-o", "name", 
                              f"{self.zroot}/{self.base}")
        if out:
            return out.split("\n")[-1]
        else:
            raise ValueError(f"No snapshots found: {self.zroot}/{self.base}")

    def snapshot_base(self):
        self.cmd("zfs","snapshot",f"{self.zroot}/{self.base}@{time.strftime('%s')}")

    def chroot_base(self,cmds=None,snapshot=True):
        self.cmd("mount","-t","devfs","-o","ruleset=2","devfs",f"{self.mountpoint}/{self.base}/dev")
        if cmds:
            subprocess.run(["chroot",f"{self.mountpoint}/{self.base}","/bin/sh"],
                    input=b"\n".join([c.encode() for c in cmds]))
        else:
            subprocess.run(["chroot",f"{self.mountpoint}/{self.base}","/bin/sh"])
        self.cmd("umount","-f",f"{self.mountpoint}/{self.base}/dev")
        if snapshot:
            self.snapshot_base()

    def get_jails(self):
        out = self.cmd("zfs","list","-r","-H","-o","jail:base,jail:name",self.zroot)
        return [self.jail(name) for (base,name) in 
                        re.findall("(.*)\t(.*)",out) if base == self.base]

    def jail(self,name):
        return Jail(name,self)
        
    def jail_from_hash(self,jail_hash):
        return Jail(self.name_from_hash(jail_hash),self)

# For epair
HOST,JAIL = 0,1

# Use decorators to check state
def check_running(f):
    @functools.wraps(f)
    def _wrapper(self,*args,**kwargs):
        if not self.is_running():
            raise ValueError(f"Jail not running: {self.name} ({self.hash})")
        return f(self,*args,**kwargs)
    return _wrapper

def check_not_running(f):
    @functools.wraps(f)
    def _wrapper(self,*args,**kwargs):
        if self.is_running():
            raise ValueError(f"Jail running: {self.name} ({self.hash})")
        return f(self,*args,**kwargs)
    return _wrapper

def check_fs_exists(f):
    @functools.wraps(f)
    def _wrapper(self,*args,**kwargs):
        if not self.check_fs():
            raise ValueError(f"Jail FS not found: {self.name} ({self.zpath})")
        return f(self,*args,**kwargs)
    return _wrapper

class Jail:

    def __init__(self,name,host=None):

        # Jail params
        self.name = name
        self.host = host or JailHost()
        self.hash = self.host.generate_hash(name)
        self.ipv6 = self.host.generate_addr(name)
        self.path = f"{self.host.mountpoint}/{self.hash}"
        self.zpath = f"{self.host.zroot}/{self.hash}"
        self.epair = (f"{self.hash}A",f"{self.hash}B")
        self.gateway = self.host.generate_gateway(self.epair[JAIL])

        # Useful commands
        self.ifconfig       = lambda *args: self.host.cmd("ifconfig",*args)
        self.route6         = lambda *args: self.host.cmd("route","-6",*args)
        self.jail_route6    = lambda *args: self.host.cmd("jexec","-l",self.hash,"route","-6",*args)
        self.zfs_clone      = lambda *args: self.host.cmd("zfs","clone",*args)
        self.zfs_set        = lambda *args: self.host.cmd("zfs","set",*args,self.zpath)
        self.jail_start     = lambda *args: self.host.cmd("jail","-cv",*args)
        self.jail_stop      = lambda : self.host.cmd("jail","-Rv",self.hash)
        self.umount_devfs   = lambda : self.host.cmd("umount",f"{self.path}/dev")
        self.osrelease      = lambda : self.host.cmd("uname","-r")

    def create_epair(self,private=True):
        epair = self.ifconfig("epair","create")[:-1]
        epair_host,epair_jail = self.epair
        self.ifconfig(f"{epair}a","name",epair_host)
        self.ifconfig(f"{epair}b","name",epair_jail)
        self.ifconfig(epair_host,"inet6","auto_linklocal","up")
        if private:
            self.ifconfig(self.host.bridge,"addm",epair_host,"private",epair_host)
        else:
            self.ifconfig(self.host.bridge,"addm",epair_host)

    def remove_vnet(self):
        self.ifconfig(self.epair[JAIL],"-vnet",self.hash)

    def destroy_epair(self):
        self.ifconfig(self.epair[HOST],"destroy")

    def get_lladdr(self):
        (lladdr_host,) = re.search("inet6 (fe80::.*?)%",self.ifconfig(self.epair[HOST])).groups()
        lladdr_jail = lladdr_host[:-1] + "b"
        return (lladdr_host,lladdr_jail)

    def local_route(self):
        epair_host,epair_jail = self.epair
        lladdr_host,lladdr_jail = self.get_lladdr()
        self.route6("add",self.ipv6,f"{lladdr_jail}%{epair_host}")
        self.jail_route6("add",self.host.hostipv6,f"{lladdr_host}%{epair_jail}")

    def is_running(self):
        return self.host.check_cmd("jls","-Nj",self.hash)

    def check_fs(self):
        return self.host.check_cmd("zfs","list",self.zpath)

    def check_epair(self):
        return self.host.check_cmd("ifconfig",self.epair[HOST])

    def check_devfs(self):
        out = self.host.cmd("mount","-t","devfs")
        return re.search(f"{self.path}/dev",out) is not None

    def is_vnet(self):
        try:
            return self.host.cmd("jls","-j",self.hash,"vnet") == "1"
        except subprocess.CalledProcessError:
            return False

    @check_running
    def jexec(self,*args):
        return subprocess.run(["jexec","-l",self.hash,*args])

    @check_fs_exists
    def sysrc(self,*args):
        return self.host.cmd("sysrc","-R",self.path,*args)

    @check_fs_exists
    def install(self,source,dest,mode="0755",user=None,group=None):
        try:
            if isinstance(source,str):
                s = io.BytesIO(source.encode())
            elif isinstance(source,bytes):
                s = io.BytesIO(source)
            elif hasattr(source,"read"):
                s = source
            else:
                raise ValueError("Invalid source")

            if isinstance(dest,str):
                d = open(f"{self.path}{dest}","wb")
                os.chmod(f"{self.path}{dest}",int(mode,8))
                if user or group:
                    shutil.chown(f"{self.path}{dest}",user,group)
            elif isinstance(dest,int):
                d = os.fdopen(dest,"wb")
            else:
                raise ValueError("Invalid destination")

            return d.write(s.read())

        finally:
            s.close()
            d.close()

    @check_fs_exists
    def mkstemp(self,suffix=None,prefix=None,dir=None,text=False):
        jdir = f"{self.path}/{dir}" if dir else f"{self.path}/tmp"
        fd,path = tempfile.mkstemp(suffix,prefix,jdir,text)
        return (fd, path[len(self.path):])

    def create_fs(self):
        if self.check_fs():
            raise ValueError(f"Jail FS exists: {self.name} ({self.zpath})")
        self.zfs_clone(self.host.get_latest_snapshot(),self.zpath)
        self.zfs_set(f"jail:name={self.name}",
                     f"jail:ipv6={self.ipv6}",
                     f"jail:base={self.host.base}")

    @check_fs_exists
    def configure_vnet(self):
        epair_host,epair_jail = self.epair
        self.sysrc(f"ifconfig_{epair_jail}_ipv6=inet6 {self.ipv6}/64",
                   f"ipv6_defaultrouter={self.gateway}",
                   f"ifconfig_lo0_ipv6=inet6 up")

    @check_fs_exists
    def configure_host(self):
        self.ifconfig(self.host.hostif,"inet6",self.ipv6)

    @check_fs_exists
    @check_not_running
    def start(self,vnet=True,private=True,jail_params=None):
        params = self.host.DEFAULT_PARAMS.copy()
        params["name"] = self.hash
        params["path"] = self.path
        params["vnet.interface"] = self.epair[JAIL]
        params["host.hostname"] = self.name
        params["osrelease"] = self.osrelease()
        params.update(jail_params or {})
        if vnet:
            self.create_epair(private)
            self.configure_vnet()
        else:
            del params["vnet"]
            del params["vnet.interface"]
            params["ip6.addr"] = self.ipv6
            self.configure_host()
        self.jail_start(*[f"{k}={v}" for k,v in params.items()])
        if vnet:
            self.local_route()

    @check_running
    def stop(self):
        if self.is_vnet():
            self.remove_vnet()
            self.destroy_epair()
        else:
            self.ifconfig(self.host.hostif,"inet6",self.ipv6,"-alias")
        self.jail_stop()
        self.umount_devfs()

    @check_fs_exists
    def destroy_fs(self):
        self.host.cmd("zfs","destroy","-f",self.zpath)

    def remove(self,force=False):
        if self.is_running():
            if force:
                self.stop()
            else:
                raise ValueError(f"Jail running: {self.name} ({self.hash})")
        if self.check_devfs():
            self.umount_devfs()
        if self.check_epair():
            self.destroy_epair()
        self.destroy_fs()

    def cleanup(self,force=False,destroy_fs=False):
        if self.is_running() and force:
            self.stop()
        else:
            raise ValueError(f"Jail running: {self.name} ({self.hash})")
        if self.check_devfs():
            self.umount_devfs()
        if self.check_epair():
            self.destroy_epair()
        if self.check_fs() and destroy_fs:
            self.destroy_fs()

if __name__ == "__main__":

    import click,tabulate

    @click.group()
    @click.option("--debug",is_flag=True)
    @click.option("--base")
    @click.pass_context
    def cli(ctx,debug,base):
        try:
            ctx.ensure_object(dict)
            args = { "debug": debug }
            if base:
                args["base"] = base
            ctx.obj["host"] = JailHost(**args)
        except subprocess.CalledProcessError as e:
            raise click.ClickException(f"{e} :: {e.stderr.strip()}")
        except ValueError as e:
            raise click.ClickException(f"{e}")

    @cli.command()
    @click.argument("name",nargs=1)
    @click.pass_context
    def new(ctx,name):
        try:
            jail = ctx.obj['host'].jail(name)
            jail.create_fs()
            click.secho(f"Created jail: {jail.name} (id={jail.hash})",fg="green")
        except subprocess.CalledProcessError as e:
            raise click.ClickException(f"{e} :: {e.stderr.strip()}")
        except ValueError as e:
            raise click.ClickException(f"{e}")

    @cli.command()
    @click.argument("name",nargs=1)
    @click.option("--private",is_flag=True)
    @click.option("--params",multiple=True)
    @click.option("--vnet/--no-vnet",default=True)
    @click.pass_context
    def run(ctx,name,private,params,vnet):
        try:
            jail = ctx.obj['host'].jail(name)
            if not jail.check_fs():
                jail.create_fs()
            jail.start(vnet=vnet,private=private,jail_params=dict([p.split("=") for p in params]))
            click.secho(f"Started jail: {jail.name} (id={jail.hash} ipv6={jail.ipv6})",fg="green")
        except subprocess.CalledProcessError as e:
            raise click.ClickException(f"{e} :: {e.stderr.strip()}")
        except ValueError as e:
            raise click.ClickException(f"{e}")

    @cli.command()
    @click.argument("name",nargs=1)
    @click.option("--params",multiple=True)
    @click.option("--private",is_flag=True)
    @click.option("--vnet/--no-vnet",default=True)
    @click.pass_context
    def start(ctx,name,private,params,vnet):
        try:
            jail = ctx.obj['host'].jail(name)
            jail.start(vnet=vnet,private=private,jail_params=dict([p.split("=") for p in params]))
            click.secho(f"Started jail: {jail.name} (id={jail.hash} ipv6={jail.ipv6})",fg="green")
        except subprocess.CalledProcessError as e:
            raise click.ClickException(f"{e} :: {e.stderr.strip()}")
        except ValueError as e:
            raise click.ClickException(f"{e}")

    @cli.command()
    @click.argument("name",nargs=1)
    @click.pass_context
    def stop(ctx,name):
        try:
            jail = ctx.obj['host'].jail(name)
            jail.stop()
            click.secho(f"Stopped jail: {jail.name} ({jail.hash})",fg="green")
        except subprocess.CalledProcessError as e:
            raise click.ClickException(f"{e} :: {e.stderr.strip()}")
        except ValueError as e:
            raise click.ClickException(f"{e}")

    @cli.command()
    @click.option("--force",is_flag=True)
    @click.argument("name",nargs=1)
    @click.pass_context
    def remove(ctx,name,force):
        try:
            jail = ctx.obj['host'].jail(name)
            jail.remove(force=force)
            click.secho(f"Removed jail: {jail.name} ({jail.hash})",fg="green")
        except subprocess.CalledProcessError as e:
            raise click.ClickException(f"{e} :: {e.stderr.strip()}")
        except ValueError as e:
            raise click.ClickException(f"{e}")

    @cli.command()
    @click.pass_context
    def list(ctx):
        try:
            jails = [dict(name=j.name,hash=j.hash,ipv6=j.ipv6,running=j.is_running()) 
                            for j in ctx.obj['host'].get_jails()]
            click.echo(tabulate.tabulate(jails,headers="keys"))
        except subprocess.CalledProcessError as e:
            raise click.ClickException(f"{e} :: {e.stderr.strip()}")
        except ValueError as e:
            raise click.ClickException(f"{e}")

    @cli.command()
    @click.argument("name",nargs=1)
    @click.argument("args", nargs=-1)
    @click.pass_context
    def sysrc(ctx,name,args):
        try:
            jail = ctx.obj['host'].jail(name)
            click.secho(f"sysrc: {jail.name} ({jail.hash})",fg="yellow")
            if args:
                click.secho(jail.sysrc("-v",*args),fg="green")
            else:
                click.secho(jail.sysrc("-a","-v"),fg="green")
        except subprocess.CalledProcessError as e:
            raise click.ClickException(f"{e} :: {e.stderr.strip()}")
        except ValueError as e:
            raise click.ClickException(f"{e}")

    @cli.command()
    @click.argument("name",nargs=1)
    @click.argument("args", nargs=-1)
    @click.pass_context
    def jexec(ctx,name,args):
        try:
            jail = ctx.obj['host'].jail(name)
            jail.jexec(*args)
        except subprocess.CalledProcessError as e:
            raise click.ClickException(f"{e} :: {e.stderr.strip()}")
        except ValueError as e:
            raise click.ClickException(f"{e}")

    @cli.command()
    @click.argument("name",nargs=1)
    @click.pass_context
    def interact(ctx,name):
        try:
            jail = ctx.obj['host'].jail(name)
            code.interact(local=locals())
        except subprocess.CalledProcessError as e:
            raise click.ClickException(f"{e} :: {e.stderr.strip()}")
        except ValueError as e:
            raise click.ClickException(f"{e}")

    @cli.command()
    @click.argument("name",nargs=1)
    @click.option("--source",type=click.File('rb'),required=True)
    @click.option("--dest")
    @click.option("--mktemp",is_flag=True)
    @click.option("--mode",default="0755")
    @click.option("--user")
    @click.option("--group")
    @click.pass_context
    def install(ctx,name,source,dest,mktemp,mode,user,group):
        try:
            jail = ctx.obj['host'].jail(name)
            if dest:
                n = jail.install(source,dest,mode,user,group)
                click.secho(f"Installed to {dest} ({n} bytes)")
            elif mktemp:
                fd,path = jail.mkstemp(prefix="tmp_")
                n = jail.install(source,fd)
                click.secho(f"Installed to {path} ({n} bytes)")
            else:
                raise ValueError("Must specify either `--dest` or `--mktemp`")
        except subprocess.CalledProcessError as e:
            raise click.ClickException(f"{e} :: {e.stderr.strip()}")
        except ValueError as e:
            raise click.ClickException(f"{e}")

    cli()



