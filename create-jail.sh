#!/bin/sh

# create-jail.sh - quickly prepare a thin jail from a base jail

# ( assumes templates set up similar to described at                        )
# ( https://jacob.ludriks.com/2017/06/07/FreeBSD-Thin-Jails/                )

# ( these scripts require ZFS )

# SCRIPT CONFIGURATION

#JAILBASE="/usr/jails"
JAILBASE_ZFS="freebsd-zroot/usr/jails"
JAILBASE=`zfs get -Ho value mountpoint $JAILBASE_ZFS`

#JB_RELEASE="$JAILBASE/.releases"
JB_RELEASE_ZFS="$JAILBASE_ZFS/.releases"
JB_RELEASE=`zfs get -Ho value mountpoint $JB_RELEASE_ZFS`

if [ -z "$2" ]; then
		JAIL_RELEASE=`zfs list -Hrd 1 -o name freebsd-zroot/usr/jails/.releases \
				| sed 's|.*/||' | grep -E '^[0-9]+\.[0-9]+-RELEASE$' | sort -V |tail -n 1`
else
		JAIL_RELEASE="$2"
fi

JAIL="$1"

MOUNTPOINT_DIRS="bin lib libexec sbin usr/bin usr/lib usr/libdata usr/share usr/include usr/lib32 usr/libexec usr/sbin"
WRITEABLE_DIRS="etc var root tmp mnt media dev"

if [ "$(id -u)" -gt 0 ]; then
	echo "$0 needs to be run as root!"
	exit 1
fi

if [ -z "$1" ]; then
	echo "usage: $0 jail [base-version]"
	exit 1
fi 

echo "=== $JAIL: preparing the jail directory... ==="
zfs create "${JAILBASE_ZFS}/${JAIL}"

echo "creating directories for base system mountpoints..."
for dir in $MOUNTPOINT_DIRS; do
		mkdir -p "${JAILBASE}/${JAIL}/${dir}"
done

echo "copying writables from base system..."
for dir in $WRITEABLE_DIRS; do
		cp -a "${JB_RELEASE}/${JAIL_RELEASE}/$dir" "$JAILBASE/$JAIL/"
done

echo "=== $JAIL: creating fstab ==="
{
		echo "# device/nullfs-dir mountpoint type options dump pass"
		for dir in $MOUNTPOINT_DIRS; do
				echo "${JB_RELEASE}/${JAIL_RELEASE}/$dir ${JAILBASE}/${JAIL}/$dir nullfs ro 0 0"
		done
} > "$JAILBASE/$JAIL.fstab"

echo "=== $JAIL: Preparation successful! ==="
cat << EOF
$JAIL is prepared. If it is defined in jail.conf(5), you
should be able to start it right up with either of:

# jail -c $JAIL
# service jail start $JAIL
EOF

exit 0
