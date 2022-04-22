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

echo "=== $JAIL: cloning a skeleton to the thinjail directory / dataset... ==="
echo "zfs clone \"${JB_TEMPLATES_ZFS}/${JAIL_RELEASE}_skeleton@complete\" \"$JB_THINDATA_ZFS/$JAIL\""
zfs clone "${JB_TEMPLATES_ZFS}/${JAIL_RELEASE}_skeleton@complete" "$JB_THINDATA_ZFS/$JAIL"
echo "zfs create -o readonly=on \"$JAILBASE_ZFS/$JAIL\""
zfs create -o readonly=on "$JAILBASE_ZFS/$JAIL"

echo "=== $JAIL: creating fstab ==="
cat << EOF > $JAILBASE/$JAIL.fstab
# device/nullfs-dir   mountpoint   type   opts   dump   pass
${JB_TEMPLATES}/${JAIL_RELEASE}_base ${JAILBASE}/${JAIL} nullfs ro 0 0
${JB_THINDATA}/${JAIL} ${JAILBASE}/${JAIL}/skeleton nullfs rw 0 0
EOF

echo "=== $JAIL: Preparation successful! ==="
cat << EOF
$JAIL is prepared. If it is defined in jail.conf(5), you
should be able to start it right up with:

jail -c $JAIL

EOF
