## jailmgr -- FreeBSD jail management scripts

Currently, these are the scripts I use for jail management on my
FreeBSD system.

If I ever get around to making this a full-featured jail manager,
my intents for it are roughly along these lines:

* Extensively use jail.conf functionality provided by the
  base system, rather than reinventing the wheel
* Dependency free, so it'll run on an otherwise bone stock modern
  FreeBSD system
* ZFS and VNET flavours of opinionated
* Designed around using VNET for jail networking
* Provide a nice interface around the existing `jail` / `jexec` 
  / `jls` / etc tools to bring them into line with more modern,
  friendlier FreeBSD utilities (such as `service(8)`, `sysrc(8)`
  and `pkg(8)`)
* integrate with the pf firewall and ifconfig for providing
  on-demand network interfaces and firewall rules for each jail
