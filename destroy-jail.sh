#!/bin/sh

# create-jail.sh - quickly prepare a thin jail from a template

# ( assumes templates set up similar to described at                        )
# ( https://jacob.ludriks.com/2017/06/07/FreeBSD-Thin-Jails/                )

# ( also assumes you're using zfs because you really should be, but it will )
# ( will eventually be rewritten for the odd people still using UFS         )

# my zfs dataset names differ slightly from the mountpoints
JAILBASE="/usr/jails"
JAILBASE_ZFS="freebsd-root/usr/jails"

JB_RELEASE="$JAILBASE/.releases"
JB_RELEASE_ZFS="$JAILBASE_ZFS/releases"

JB_TEMPLATES="$JAILBASE/.templates"
JB_TEMPLATES_ZFS="$JAILBASE_ZFS/templates"

JB_THINDATA="$JAILBASE/.thinjails"
JB_THINDATA_ZFS="$JAILBASE_ZFS/thinjails"

JAIL_RELEASE="13.0-RELEASE"

JAIL="$1"

if [ "$(id -u)" -gt 0 ]; then
	echo "$0 needs to be run as root!"
	exit 1
fi

if [ -z "$1" ]; then
	echo "usage: $0 jail"
	exit 1
fi 

echo "Sure you want to destroy $JAIL?"
echo "Please type the name of the jail to confirm:"
read USERINPUT
if [ "$USERINPUT" != "$JAIL" ]; then
	echo "Cancelled."
	exit 1
fi

echo "=== $JAIL: stopping and removing the jail... ==="
jexec $JAIL /bin/sh /etc/rc.shutdown
jail -r $JAIL

echo "=== $JAIL: deleting zfs datasets and files belonging to the jail... ==="
zfs destroy "$JB_THINDATA_ZFS/$JAIL"
zfs destroy "$JAILBASE_ZFS/$JAIL"
rm "$JAILBASE/$JAIL.fstab"

echo "=== $JAIL: Destroy successful! ==="
cat << EOF
Note that if snapshots of the thin-jail dataset exist,
$JB_THINDATA_ZFS/$JAIL
will still exist. You can use:

# zfs destroy -r $JB_THINDATA_ZFS/$JAIL

to delete this dataset.
EOF
