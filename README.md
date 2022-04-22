## jailmgr

Yet another FreeBSD jail manager. It's currently **very incomplete** but my
intents for jailmgr are:

* Extensively use jail.conf functionality provided by the
  base system, rather than reinventing the wheel
* Dependency free, so it'll run on an otherwise bone stock modern
  FreeBSD system
* ZFS-first, but will still work with lesser filesystems
* Designed around using VNET for jail networking
* Provide a nice interface around the existing `jail` / `jexec` 
  / `jls` / etc tools to bring them into line with more modern,
  friendlier FreeBSD utilities (such as `service(8)`, `sysrc(8)`
  and `pkg(8)`)
* integrate with the pf firewall and ifconfig for providing
  on-demand network interfaces and firewall rules for each jail
