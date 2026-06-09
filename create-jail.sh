#!/bin/sh
#
# create-jail.sh — scaffold a thin FreeBSD jail from a shared base release
#
# usage: create-jail.sh -n NAME -r RELEASE [--no-src] [--writable-root]
#                        [-b BASE] [-c CONF]
#        create-jail.sh -h
#
#   -n, --name NAME         Jail name. Required.
#                           Must match: ^[a-z][a-z0-9_-]{0,62}$
#
#   -r, --release REL       Release name. Required.
#                           e.g. 14.3-RELEASE
#                           Must exist under $JAIL_PARENT/.releases/$REL (or
#                           whatever --base specifies) and contain bin/ and etc/.
#
#       --no-src            Omit /usr/src from the fstab and skip its copy
#                           from base. Default: include /usr/src (ro from base).
#
#       --writable-root     Do NOT nullfs /root from base. The jail's /root
#                           remains a writable per-jail directory populated
#                           from the base release.
#                           Default: nullfs /root ro from base.
#
#   -b, --base REL-PATH     Release directory name under $JAIL_PARENT.
#                           Default: .releases
#                           Full release path: $JAIL_PARENT/$BASE/$REL
#
#   -c, --conf PATH         Override the config file path. Overrides
#                           $JAILMGR_CONF and the built-in search path.
#
#   -h, --help              Show this help and exit.
#
# What this script does:
#   * Resolves config (see "Configuration" below) and validates inputs.
#   * Creates a ZFS dataset at $JAIL_PARENT_ZFS/$NAME (no properties set).
#   * Copies writables from the base release into the new jail under a
#     single "copying writables from base release" banner:
#       - regular files at the base root (.cshrc, .profile, COPYRIGHT, etc.)
#         are picked up non-specifically via glob + [ -f ] filter, copied
#         non-recursively with `cp -p`;
#       - then the directories etc, var, tmp, mnt, media, dev are copied
#         recursively with `cp -RpP`; root/ is added to that list when
#         --writable-root is set.
#   * Creates empty mount-anchor directories for everything the fstab will
#     nullfs-mount over.
#   * Writes the host-side fstab to /etc/jail.conf.d/$NAME.fstab
#     (consumed by jail(8) at start; not mounted by this script).
#
# What this script does NOT do:
#   * Configure /etc/jail.conf or /etc/jail.conf.d/*.conf
#   * Mount anything (no mount_nullfs, no jail -c)
#   * Start the jail
#   * Fetch or unpack base releases
#   * Set ZFS properties on the per-jail dataset
#   * Handle an existing jail path (refuses; no --force in this version)
#
# Configuration:
#   The script reads shell variables from the first conf file found in:
#     1. $JAILMGR_CONF (env var, if set)
#     2. $SCRIPT_DIR/jailmgr.conf  (next to this script, for dev/testing)
#     3. /usr/local/etc/jailmgr.conf  (system-wide)
#   Recognised variables (all optional):
#     JAIL_PARENT_ZFS   ZFS dataset for the jails tree. Default: freebsd-zroot/usr/jails
#     JAIL_PARENT       Mountpoint of the above. Default: derived via `zfs get -Ho value mountpoint`.
#   Missing conf files are not errors; built-in defaults apply.
#
# Per-jail responsibilities left to the user (not done by this script):
#   * /etc/jail.conf(.d) configuration (IP, hostname, interfaces, devfs, etc.)
#   * Per-jail /etc/make.conf if ports are to be built:
#       WRKDIRPREFIX=/var/ports
#       DISTDIR=/var/ports/distfiles
#       PACKAGES=/var/ports/packages
#
# Requirements: FreeBSD 14.0+ base, ZFS, /bin/sh.

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

JAIL_NAME=
JAIL_RELEASE=
BASE_REL=".releases"
SRC_INCLUDE=1
WRITABLE_ROOT=0
CONF_PATH=

usage() {
	_end=$(grep -n '^set -u$' "$0" | head -n 1 | cut -d: -f1)
	[ -z "$_end" ] && _end=999
	_end=$((_end - 1))
	sed -n "2,${_end}p" "$0" | sed 's/^# \{0,1\}//; s/^# *$/ /'
}

err() {
	printf 'create-jail.sh: %s\n' "$*" >&2
}

resolve_conf() {
	_conf=
	if [ -n "$CONF_PATH" ]; then
		_conf="$CONF_PATH"
	elif [ -n "${JAILMGR_CONF:-}" ]; then
		_conf="$JAILMGR_CONF"
	elif [ -r "$SCRIPT_DIR/jailmgr.conf" ]; then
		_conf="$SCRIPT_DIR/jailmgr.conf"
	elif [ -r "/usr/local/etc/jailmgr.conf" ]; then
		_conf="/usr/local/etc/jailmgr.conf"
	fi
	if [ -n "$_conf" ]; then
		if [ ! -r "$_conf" ]; then
			err "conf file not readable: $_conf"
			exit 1
		fi
		. "$_conf" || { err "failed to source conf: $_conf"; exit 1; }
	fi

	: "${JAIL_PARENT_ZFS:=freebsd-zroot/usr/jails}"
	if [ -z "${JAIL_PARENT:-}" ]; then
		JAIL_PARENT=$(zfs get -Ho value mountpoint "$JAIL_PARENT_ZFS" 2>/dev/null) || {
			err "could not resolve JAIL_PARENT for dataset $JAIL_PARENT_ZFS"
			exit 1
		}
	fi
}

parse_args() {
	while [ $# -gt 0 ]; do
		case "$1" in
			-h|--help)
				usage
				exit 0
				;;
			-n|--name)
				[ $# -ge 2 ] || { err "-n requires an argument"; exit 2; }
				JAIL_NAME="$2"
				shift 2
				;;
			-r|--release)
				[ $# -ge 2 ] || { err "-r requires an argument"; exit 2; }
				JAIL_RELEASE="$2"
				shift 2
				;;
			--no-src)
				SRC_INCLUDE=0
				shift
				;;
			--writable-root)
				WRITABLE_ROOT=1
				shift
				;;
			-b|--base)
				[ $# -ge 2 ] || { err "-b requires an argument"; exit 2; }
				BASE_REL="$2"
				shift 2
				;;
			-c|--conf)
				[ $# -ge 2 ] || { err "-c requires an argument"; exit 2; }
				CONF_PATH="$2"
				shift 2
				;;
			--)
				shift
				break
				;;
			-*)
				err "unknown option: $1"
				usage >&2
				exit 2
				;;
			*)
				err "unexpected positional argument: $1"
				usage >&2
				exit 2
				;;
		esac
	done

	if [ -z "$JAIL_NAME" ]; then
		err "missing required option: -n/--name"
		usage >&2
		exit 2
	fi
	if [ -z "$JAIL_RELEASE" ]; then
		err "missing required option: -r/--release"
		usage >&2
		exit 2
	fi
}

validate_inputs() {
	case "$JAIL_NAME" in
		[a-z][a-z0-9_-]*)
			;;
		*)
			err "invalid jail name: $JAIL_NAME (must match ^[a-z][a-z0-9_-]{0,62}\$)"
			exit 1
			;;
	esac
	if [ "${#JAIL_NAME}" -gt 63 ]; then
		err "invalid jail name: $JAIL_NAME (max 63 characters)"
		exit 1
	fi

	if [ ! -d "$JAIL_PARENT" ]; then
		err "JAIL_PARENT does not exist or is not a directory: $JAIL_PARENT"
		exit 1
	fi
	if ! zfs list -Ho name "$JAIL_PARENT_ZFS" >/dev/null 2>&1; then
		err "JAIL_PARENT_ZFS does not exist: $JAIL_PARENT_ZFS"
		exit 1
	fi

	RELEASE_DIR="$JAIL_PARENT/$BASE_REL/$JAIL_RELEASE"
	if [ ! -d "$RELEASE_DIR" ]; then
		err "release directory does not exist: $RELEASE_DIR"
		exit 1
	fi
	if [ ! -d "$RELEASE_DIR/bin" ] || [ ! -d "$RELEASE_DIR/etc" ]; then
		err "release directory missing bin/ or etc/: $RELEASE_DIR"
		exit 1
	fi

	if zfs list -Ho name "$JAIL_PARENT_ZFS/$JAIL_NAME" >/dev/null 2>&1; then
		err "jail dataset already exists: $JAIL_PARENT_ZFS/$JAIL_NAME"
		exit 1
	fi
}

ensure_jailconf_d() {
	if [ ! -d "/etc/jail.conf.d" ]; then
		if ! mkdir -p "/etc/jail.conf.d" 2>/dev/null; then
			err "cannot create /etc/jail.conf.d (need root, or pre-create it)"
			exit 1
		fi
	fi
}

create_jail() {
	JAIL_DIR="$JAIL_PARENT/$JAIL_NAME"
	RELEASE_DIR="$JAIL_PARENT/$BASE_REL/$JAIL_RELEASE"

	printf '=== %s: creating ZFS dataset %s ===\n' "$JAIL_NAME" "$JAIL_PARENT_ZFS/$JAIL_NAME"
	zfs create "$JAIL_PARENT_ZFS/$JAIL_NAME" || {
		err "zfs create failed for $JAIL_PARENT_ZFS/$JAIL_NAME"
		exit 1
	}

	printf '=== %s: copying writables from base release ===\n' "$JAIL_NAME"
	_files=
	for _f in "$RELEASE_DIR"/.[!.]* "$RELEASE_DIR"/*; do
		[ -f "$_f" ] || continue
		cp -p "$_f" "$JAIL_DIR/" || {
			err "failed to copy $_f"
			exit 1
		}
		_files="$_files ${_f##*/}"
	done
	if [ -n "$_files" ]; then
		printf 'copying files:%s\n' "$_files"
	else
		printf 'copying files: (none in base)\n'
	fi

	_writables="etc var tmp mnt media dev"
	[ "$WRITABLE_ROOT" -eq 1 ] && _writables="$_writables root"
	_dirs=
	for _d in $_writables; do
		if [ ! -e "$RELEASE_DIR/$_d" ]; then
			continue
		fi
		cp -RpP "$RELEASE_DIR/$_d" "$JAIL_DIR/" || {
			err "failed to copy $_d"
			exit 1
		}
		_dirs="$_dirs $_d"
	done
	if [ -n "$_dirs" ]; then
		printf 'copying directories:%s\n' "$_dirs"
	else
		printf 'copying directories: (none copied)\n'
	fi

	_skipped=
	for _d in $_writables; do
		[ -e "$RELEASE_DIR/$_d" ] && continue
		_skipped="$_skipped $_d"
	done
	if [ -n "$_skipped" ]; then
		printf '  (skipped: not in base:%s)\n' "$_skipped"
	fi

	printf '=== %s: creating mount-anchor directories ===\n' "$JAIL_NAME"
	_anchors="bin lib libexec sbin usr/bin usr/lib usr/libdata usr/share usr/include usr/lib32 usr/libexec usr/sbin usr/local usr/ports root tmp mnt media dev"
	[ "$SRC_INCLUDE" -eq 1 ] && _anchors="$_anchors usr/src"
	for _a in $_anchors; do
		mkdir -p "$JAIL_DIR/$_a" || {
			err "failed to create anchor dir: $JAIL_DIR/$_a"
			exit 1
		}
	done
	printf 'creating directories:%s\n' "$_anchors"
}

_fstab_row() {
	printf '%s\n' "$1	$2	$3	$4	$5	$6"
}

write_fstab() {
	FSTAB="/etc/jail.conf.d/$JAIL_NAME.fstab"
	RELEASE_DIR="$JAIL_PARENT/$BASE_REL/$JAIL_RELEASE"
	JAIL_DIR="$JAIL_PARENT/$JAIL_NAME"

	printf '=== %s: writing fstab to %s ===\n' "$JAIL_NAME" "$FSTAB"

	{
		printf '%s\n' "# device/nullfs-dir	mountpoint	type	opts	dump	pass"
		_fstab_row "$RELEASE_DIR/bin"         "$JAIL_DIR/bin"         nullfs ro 0 0
		_fstab_row "$RELEASE_DIR/lib"         "$JAIL_DIR/lib"         nullfs ro 0 0
		_fstab_row "$RELEASE_DIR/libexec"     "$JAIL_DIR/libexec"     nullfs ro 0 0
		_fstab_row "$RELEASE_DIR/sbin"        "$JAIL_DIR/sbin"        nullfs ro 0 0
		_fstab_row "$RELEASE_DIR/usr/bin"     "$JAIL_DIR/usr/bin"     nullfs ro 0 0
		_fstab_row "$RELEASE_DIR/usr/lib"     "$JAIL_DIR/usr/lib"     nullfs ro 0 0
		_fstab_row "$RELEASE_DIR/usr/libdata" "$JAIL_DIR/usr/libdata" nullfs ro 0 0
		_fstab_row "$RELEASE_DIR/usr/share"   "$JAIL_DIR/usr/share"   nullfs ro 0 0
		_fstab_row "$RELEASE_DIR/usr/include" "$JAIL_DIR/usr/include" nullfs ro 0 0
		_fstab_row "$RELEASE_DIR/usr/lib32"   "$JAIL_DIR/usr/lib32"   nullfs ro 0 0
		_fstab_row "$RELEASE_DIR/usr/libexec" "$JAIL_DIR/usr/libexec" nullfs ro 0 0
		_fstab_row "$RELEASE_DIR/usr/sbin"    "$JAIL_DIR/usr/sbin"    nullfs ro 0 0
		if [ "$SRC_INCLUDE" -eq 1 ]; then
			_fstab_row "$RELEASE_DIR/usr/src" "$JAIL_DIR/usr/src" nullfs ro 0 0
		fi
		if [ "$WRITABLE_ROOT" -eq 0 ]; then
			_fstab_row "$RELEASE_DIR/root" "$JAIL_DIR/root" nullfs ro 0 0
		fi
		_fstab_row "/usr/ports"             "$JAIL_DIR/usr/ports"   nullfs ro 0 0
	} > "$FSTAB" || {
		err "failed to write fstab: $FSTAB"
		exit 1
	}
}

print_summary() {
	cat <<EOF

=== $JAIL_NAME: preparation complete ===

Dataset:    $JAIL_PARENT_ZFS/$JAIL_NAME
Jail dir:   $JAIL_PARENT/$JAIL_NAME
Release:    $JAIL_PARENT/$BASE_REL/$JAIL_RELEASE
Fstab:      /etc/jail.conf.d/$JAIL_NAME.fstab

Not done (by design):
  * /etc/jail.conf(.d) configuration — set that up yourself
  * No mounts applied — the fstab is consumed by jail(8) at start
  * Jail not started
  * No base release fetched/unpacked (assumes $JAIL_PARENT/$BASE_REL/$JAIL_RELEASE exists)

Next: configure /etc/jail.conf(.d)/$JAIL_NAME.conf with path="$JAIL_DIR",
mount.fstab="$FSTAB", and any IP/hostname/devfs settings, then start it.
EOF
}

main() {
	parse_args "$@"
	resolve_conf

	if [ "$(id -u)" -ne 0 ]; then
		err "must be run as root"
		exit 1
	fi

	validate_inputs
	ensure_jailconf_d
	create_jail
	write_fstab
	print_summary
}

main "$@"
