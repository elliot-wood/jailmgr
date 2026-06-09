#!/bin/sh
#
# destroy-jail.sh — undo a thin FreeBSD jail created by create-jail.sh
#
# usage: destroy-jail.sh -n NAME [-y] [-c CONF]
#        destroy-jail.sh -h
#
#   -n, --name NAME         Jail name. Required.
#                           Must match: ^[a-z][a-z0-9_-]{0,62}$
#
#   -y, --yes               Skip the confirmation prompt.
#
#   -c, --conf PATH         Override the config file path. Overrides
#                           $JAILMGR_CONF and the built-in search path.
#
#   -h, --help              Show this help and exit.
#
# What this script does:
#   * Resolves config (see "Configuration" below) and validates inputs.
#   * Refuses to run if the jail is currently running — stop it first.
#   * Prompts the user to type the jail name to confirm destruction
#     (skipped with -y/--yes).
#   * Releases any ZFS holds on snapshots under the jail's dataset
#     (the same pattern as misc/zfs-nuke.sh, inlined here).
#   * Destroys the jail's ZFS dataset recursively.
#   * Removes /etc/jail.conf.d/$NAME.fstab if present.
#
# What this script does NOT do:
#   * Stop a running jail — refuse with instructions instead
#   * Touch /etc/jail.conf or /etc/jail.conf.d/*.conf
#   * Unmount anything (assumes the jail is stopped; no nullfs mounts active)
#   * Touch base release datasets (/usr/jails/.releases/*)
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
# Requirements: FreeBSD 14.0+ base, ZFS, /bin/sh, jls(8).

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

JAIL_NAME=
ASSUME_YES=0
CONF_PATH=

usage() {
	_end=$(grep -n '^set -u$' "$0" | head -n 1 | cut -d: -f1)
	[ -z "$_end" ] && _end=999
	_end=$((_end - 1))
	sed -n "2,${_end}p" "$0" | sed 's/^# \{0,1\}//; s/^# *$/ /'
}

err() {
	printf 'destroy-jail.sh: %s\n' "$*" >&2
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
			-y|--yes)
				ASSUME_YES=1
				shift
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

	if ! zfs list -Ho name "$JAIL_PARENT_ZFS/$JAIL_NAME" >/dev/null 2>&1; then
		err "jail dataset does not exist: $JAIL_PARENT_ZFS/$JAIL_NAME"
		exit 1
	fi
}

is_jail_running() {
	_out=$(jls -j "$JAIL_NAME" name 2>/dev/null) || return 1
	[ "$_out" = "$JAIL_NAME" ]
}

confirm_destruction() {
	[ "$ASSUME_YES" -eq 1 ] && return 0

	printf 'About to destroy jail "%s" (dataset %s).\n' "$JAIL_NAME" "$JAIL_PARENT_ZFS/$JAIL_NAME"
	printf 'Type the jail name to confirm: '
	read _input || { err "aborted (no input)"; exit 1; }
	if [ "$_input" != "$JAIL_NAME" ]; then
		err "input did not match; cancelled"
		exit 1
	fi
}

release_holds_and_destroy() {
	DATASET="$JAIL_PARENT_ZFS/$JAIL_NAME"

	printf '=== %s: releasing ZFS holds on snapshots ===\n' "$JAIL_NAME"
	zfs list -Hr -t snapshot -o name "$DATASET" 2>/dev/null | while read -r _snap; do
		[ -z "$_snap" ] && continue
		zfs holds -H "$_snap" 2>/dev/null | while read -r _snap_name _tag _ts; do
			[ -z "$_tag" ] && continue
			printf 'releasing hold "%s" on %s\n' "$_tag" "$_snap"
			zfs release "$_tag" "$_snap" || {
				err "warning: failed to release hold '$_tag' on $_snap"
			}
		done
	done

	printf '=== %s: destroying ZFS dataset %s ===\n' "$JAIL_NAME" "$DATASET"
	zfs destroy -rf "$DATASET" || {
		err "zfs destroy failed for $DATASET"
		exit 1
	}
}

remove_fstab() {
	FSTAB="/etc/jail.conf.d/$JAIL_NAME.fstab"
	if [ -f "$FSTAB" ]; then
		printf '=== %s: removing fstab %s ===\n' "$JAIL_NAME" "$FSTAB"
		rm -- "$FSTAB" || { err "failed to remove fstab: $FSTAB"; exit 1; }
	else
		printf '=== %s: fstab %s not present (skipping) ===\n' "$JAIL_NAME" "$FSTAB" >&2
	fi
}

print_summary() {
	cat <<EOF

=== $JAIL_NAME: destruction complete ===

Dataset destroyed: $JAIL_PARENT_ZFS/$JAIL_NAME
Fstab:             /etc/jail.conf.d/$JAIL_NAME.fstab (removed or was already gone)

Not done (by design):
  * /etc/jail.conf or /etc/jail.conf.d/$JAIL_NAME.conf was NOT touched.
    Remove that yourself if you no longer need it.
  * Any base release under $JAIL_PARENT/.releases/ was NOT touched.
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

	if is_jail_running; then
		err "jail '$JAIL_NAME' is currently running"
		err "stop it first with: jail -r $JAIL_NAME"
		exit 1
	fi

	confirm_destruction
	release_holds_and_destroy
	remove_fstab
	print_summary
}

main "$@"
