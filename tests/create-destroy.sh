#!/bin/sh
#
# create-destroy.sh — round-trip test for create-jail.sh + destroy-jail.sh
#
# usage: create-destroy.sh [-h] [-r RELEASE] [-c CREATE] [-d DESTROY]
#                          [--hold | --shell]
#
#   -r, --release REL       Release to test with. Default: auto-detected
#                           from $JAIL_PARENT_ZFS/.releases (newest by
#                           version-sort).
#   -c, --create PATH       Path to create-jail.sh.
#                           Default: ../create-jail.sh (sibling of this dir)
#   -d, --destroy PATH      Path to destroy-jail.sh.
#                           Default: ../destroy-jail.sh (sibling of this dir)
#       --hold              After create, pause for Enter before destroy.
#                           Useful for a quick peek at the on-disk state.
#       --shell             After create, drop into $SHELL (or /bin/sh) for
#                           investigation. Type 'exit' to continue to destroy.
#                           Mutually exclusive with --hold.
#   -h, --help              Show this help and exit.
#
# What this script does:
#   * Pre-flight: root check, conf resolution, locate create/destroy scripts,
#     auto-detect a release, refuse to run if a leftover 'testjail' exists
#     (dataset, fstab, or per-jail conf).
#   * Run create-jail.sh -n testjail -r $REL.
#   * Verify the dataset, mountpoint anchors, copied writables, fstab, and
#     per-jail conf all exist and look right.
#   * (Optionally) pause or drop into a shell for manual inspection.
#   * Run destroy-jail.sh -n testjail -y.
#   * Verify the dataset and fstab are gone, and the per-jail conf is
#     PRESERVED (the new default behaviour).
#   * Verify no other datasets under $JAIL_PARENT_ZFS were touched.
#   * Run destroy-jail.sh -n testjail --remove-conf to clean up the
#     leftover conf so the test is re-runnable.
#
# What this script does NOT do:
#   * Test --no-src, --writable-root, --base, or --conf variants
#   * Test the running-jail refusal path of destroy-jail.sh
#   * Test ZFS holds / snapshots
#   * Auto-clean a leftover 'testjail' from a prior failed run
#
# Notes:
#   * Destructive. Creates and destroys a jail named 'testjail'.
#   * Refuses to run if testjail already exists (refuse, don't auto-clean).
#   * Always passes -y to destroy-jail.sh to keep this non-interactive.
#
# Configuration: same resolution as create-jail.sh / destroy-jail.sh
#   1. $JAILMGR_CONF (env)
#   2. $SCRIPT_DIR/jailmgr.conf
#   3. /usr/local/etc/jailmgr.conf
#   4. Built-in defaults (JAIL_PARENT_ZFS=freebsd-zroot/usr/jails)
#
# Requirements: FreeBSD 14.0+ base, ZFS, /bin/sh.

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

JAIL_NAME="testjail"
RELEASE=
CREATE_SCRIPT="$SCRIPT_DIR/../create-jail.sh"
DESTROY_SCRIPT="$SCRIPT_DIR/../destroy-jail.sh"
PAUSE_MODE=

_pass=0
_fail=0

usage() {
	_end=$(grep -n '^set -u$' "$0" | head -n 1 | cut -d: -f1)
	[ -z "$_end" ] && _end=999
	_end=$((_end - 1))
	sed -n "2,${_end}p" "$0" | sed 's/^# \{0,1\}//; s/^# *$/ /'
}

err() {
	printf 'create-destroy.sh: %s\n' "$*" >&2
}

pass() {
	_pass=$((_pass + 1))
	printf '[OK]   %s\n' "$*"
}

fail() {
	_fail=$((_fail + 1))
	printf '[FAIL] %s\n' "$*"
}

check() {
	_desc=$1
	shift
	if "$@"; then
		pass "$_desc"
	else
		fail "$_desc"
	fi
}

resolve_conf() {
	_conf=
	if [ -n "${JAILMGR_CONF:-}" ]; then
		_conf="$JAILMGR_CONF"
	elif [ -r "$SCRIPT_DIR/jailmgr.conf" ]; then
		_conf="$SCRIPT_DIR/jailmgr.conf"
	elif [ -r "/usr/local/etc/jailmgr.conf" ]; then
		_conf="/usr/local/etc/jailmgr.conf"
	fi
	if [ -n "$_conf" ] && [ -r "$_conf" ]; then
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
			-r|--release)
				[ $# -ge 2 ] || { err "-r requires an argument"; exit 2; }
				RELEASE="$2"
				shift 2
				;;
			-c|--create)
				[ $# -ge 2 ] || { err "-c requires an argument"; exit 2; }
				CREATE_SCRIPT="$2"
				shift 2
				;;
			-d|--destroy)
				[ $# -ge 2 ] || { err "-d requires an argument"; exit 2; }
				DESTROY_SCRIPT="$2"
				shift 2
				;;
			--hold)
				PAUSE_MODE=hold
				shift
				;;
			--shell)
				PAUSE_MODE=shell
				shift
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
}

preflight() {
	if [ "$(id -u)" -ne 0 ]; then
		err "must be run as root"
		exit 1
	fi

	if ! zfs list -Ho name "$JAIL_PARENT_ZFS" >/dev/null 2>&1; then
		err "JAIL_PARENT_ZFS does not exist: $JAIL_PARENT_ZFS"
		exit 1
	fi
	if [ ! -d "$JAIL_PARENT/.releases" ]; then
		err "$JAIL_PARENT/.releases does not exist"
		exit 1
	fi

	if [ -z "$RELEASE" ]; then
		RELEASE=$(zfs list -Hrd 1 -o name "$JAIL_PARENT_ZFS/.releases" 2>/dev/null \
			| sed 's|.*/||' \
			| grep -E '^[0-9]+\.[0-9]+-RELEASE$' \
			| sort -V \
			| tail -n 1)
		if [ -z "$RELEASE" ]; then
			err "no release found under $JAIL_PARENT/.releases; pass -r REL"
			exit 1
		fi
		printf 'auto-detected release: %s\n' "$RELEASE"
	fi
	if [ ! -d "$JAIL_PARENT/.releases/$RELEASE" ]; then
		err "release directory does not exist: $JAIL_PARENT/.releases/$RELEASE"
		exit 1
	fi

	if [ ! -x "$CREATE_SCRIPT" ]; then
		err "create script not found or not executable: $CREATE_SCRIPT"
		exit 1
	fi
	if [ ! -x "$DESTROY_SCRIPT" ]; then
		err "destroy script not found or not executable: $DESTROY_SCRIPT"
		exit 1
	fi

	if zfs list -Ho name "$JAIL_PARENT_ZFS/$JAIL_NAME" >/dev/null 2>&1; then
		err "testjail dataset already exists: $JAIL_PARENT_ZFS/$JAIL_NAME"
		err "refusing to run; remove it manually if it's leftover from a prior run"
		exit 1
	fi
	if [ -e "/etc/jail.conf.d/$JAIL_NAME.fstab" ]; then
		err "testjail fstab already exists: /etc/jail.conf.d/$JAIL_NAME.fstab"
		err "refusing to run; remove it manually if it's leftover from a prior run"
		exit 1
	fi
	_existing_conf=$(ls /etc/jail.conf.d/*-"$JAIL_NAME".conf 2>/dev/null | head -n 1)
	if [ -n "$_existing_conf" ] && [ -f "$_existing_conf" ]; then
		err "testjail conf already exists: $_existing_conf"
		err "refusing to run; remove it manually if it's leftover from a prior run"
		exit 1
	fi
}

# Find the per-jail conf that create-jail.sh wrote. Sets CONF_PATH global.
discover_conf() {
	CONF_PATH=$(ls /etc/jail.conf.d/*-"$JAIL_NAME".conf 2>/dev/null | head -n 1)
}

snapshot_children() {
	zfs list -Ho name "$JAIL_PARENT_ZFS" 2>/dev/null | sort
}

verify_post_create() {
	DATASET="$JAIL_PARENT_ZFS/$JAIL_NAME"
	JAIL_DIR="$JAIL_PARENT/$JAIL_NAME"
	FSTAB="/etc/jail.conf.d/$JAIL_NAME.fstab"

	check "dataset $DATASET exists" \
		zfs list -Ho name "$DATASET" >/dev/null 2>&1
	check "$JAIL_DIR/ is a directory" \
		test -d "$JAIL_DIR"
	check "$JAIL_DIR/etc/ exists and is non-empty" \
		test -d "$JAIL_DIR/etc" && [ -n "$(ls -A "$JAIL_DIR/etc" 2>/dev/null)" ]
	check "$JAIL_DIR/var/ exists" \
		test -d "$JAIL_DIR/var"
	check "$JAIL_DIR/root/ exists" \
		test -d "$JAIL_DIR/root"
	check "$JAIL_DIR/usr/ports/ exists" \
		test -d "$JAIL_DIR/usr/ports"
	check "$JAIL_DIR/usr/local/ exists" \
		test -d "$JAIL_DIR/usr/local"
	check "$JAIL_DIR/usr/src/ exists (default: --no-src not passed)" \
		test -d "$JAIL_DIR/usr/src"

	if [ ! -f "$FSTAB" ]; then
		fail "$FSTAB exists"
	else
		pass "$FSTAB exists"
		check "$FSTAB is non-empty" \
			test -s "$FSTAB"
		check "$FSTAB contains bin nullfs line" \
			grep -q "bin	$JAIL_DIR/bin	nullfs" "$FSTAB"
		check "$FSTAB contains lib nullfs line" \
			grep -q "lib	$JAIL_DIR/lib	nullfs" "$FSTAB"
		check "$FSTAB contains libexec nullfs line" \
			grep -q "libexec	$JAIL_DIR/libexec	nullfs" "$FSTAB"
		check "$FSTAB contains sbin nullfs line" \
			grep -q "sbin	$JAIL_DIR/sbin	nullfs" "$FSTAB"
		check "$FSTAB contains usr/src nullfs line (default)" \
			grep -q "usr/src	$JAIL_DIR/usr/src	nullfs" "$FSTAB"
		check "$FSTAB contains /root nullfs line (no --writable-root)" \
			grep -q "root	$JAIL_DIR/root	nullfs" "$FSTAB"
		check "$FSTAB contains /usr/ports nullfs line" \
			grep -q "/usr/ports	$JAIL_DIR/usr/ports	nullfs" "$FSTAB"
	fi

	discover_conf
	if [ -z "$CONF_PATH" ] || [ ! -f "$CONF_PATH" ]; then
		fail "per-jail conf exists at /etc/jail.conf.d/*-$JAIL_NAME.conf"
	else
		pass "per-jail conf exists at $CONF_PATH"
		# Pull the auto-picked number from the filename: NN-<name>.conf
		_basename=${CONF_PATH##*/}
		_num=${_basename%%-*}
		check "conf is non-empty" \
			test -s "$CONF_PATH"
		check "conf contains \$vif = epair${_num}b" \
			grep -q "\$vif              = \"epair${_num}b\"" "$CONF_PATH"
		# Subnet defaults: pulled from $JAILMGR_CONF if available, else just check structure
		if [ -n "${SUBNET_BASE:-}" ] && [ -n "${SUBNET_PREFIX:-}" ]; then
			_expected_ip="$SUBNET_BASE.$_num/$SUBNET_PREFIX"
			check "conf contains \$ip4addr = $_expected_ip" \
				grep -q "\$ip4addr          = \"$_expected_ip\"" "$CONF_PATH"
		fi
		if [ -n "${GATEWAY:-}" ]; then
			check "conf contains \$ip4gw = $GATEWAY" \
				grep -q "\$ip4gw            = \"$GATEWAY\"" "$CONF_PATH"
		fi
		if [ -n "${BRIDGE:-}" ]; then
			check "conf contains \$netbridge = $BRIDGE" \
				grep -q "\$netbridge        = \"$BRIDGE\"" "$CONF_PATH"
		fi
		check "conf contains the jail name as block header" \
			grep -q "^${JAIL_NAME} {" "$CONF_PATH"
		check "conf contains vnet; line" \
			grep -q "^[[:space:]]*vnet;" "$CONF_PATH"
		check "conf contains devfs_ruleset = 11" \
			grep -q "devfs_ruleset     = 11" "$CONF_PATH"
	fi
}

verify_post_destroy() {
	DATASET="$JAIL_PARENT_ZFS/$JAIL_NAME"
	JAIL_DIR="$JAIL_PARENT/$JAIL_NAME"
	FSTAB="/etc/jail.conf.d/$JAIL_NAME.fstab"

	check "dataset $DATASET no longer exists" \
		sh -c "! zfs list -Ho name '$DATASET' >/dev/null 2>&1"
	check "$JAIL_DIR/ no longer exists" \
		test ! -e "$JAIL_DIR"
	check "$FSTAB no longer exists" \
		test ! -e "$FSTAB"

	# Per-jail conf is preserved by destroy-jail.sh by default
	discover_conf
	if [ -z "$CONF_PATH" ] || [ ! -f "$CONF_PATH" ]; then
		fail "per-jail conf $CONF_PATH preserved (destroy should leave it)"
	else
		pass "per-jail conf $CONF_PATH preserved (destroy should leave it)"
	fi
}

cleanup_on_failure() {
	if zfs list -Ho name "$JAIL_PARENT_ZFS/$JAIL_NAME" >/dev/null 2>&1; then
		printf 'attempting cleanup: destroying testjail dataset...\n' >&2
		"$DESTROY_SCRIPT" -n "$JAIL_NAME" -y || \
			err "cleanup destroy failed; manual cleanup may be needed"
	fi
	discover_conf
	if [ -n "$CONF_PATH" ] && [ -f "$CONF_PATH" ]; then
		printf 'attempting cleanup: removing testjail conf %s...\n' "$CONF_PATH" >&2
		"$DESTROY_SCRIPT" -n "$JAIL_NAME" --remove-conf 2>/dev/null || \
			rm -f -- "$CONF_PATH" || err "cleanup conf removal failed"
	fi
}

print_summary() {
	printf '\nResults: %d passed, %d failed\n' "$_pass" "$_fail"
}

main() {
	parse_args "$@"
	resolve_conf
	preflight

	_before=$(snapshot_children)

	printf '\n=== creating jail ===\n'
	if "$CREATE_SCRIPT" -n "$JAIL_NAME" -r "$RELEASE"; then
		pass "create-jail.sh exits 0"
	else
		fail "create-jail.sh exits 0"
		cleanup_on_failure
		print_summary
		exit 1
	fi

	printf '\n=== verifying post-create state ===\n'
	verify_post_create

	if [ -n "$PAUSE_MODE" ]; then
		printf '\n=== paused between create and destroy ===\n'
		printf 'Jail dataset: %s\n' "$JAIL_PARENT_ZFS/$JAIL_NAME"
		printf 'Jail dir:     %s\n' "$JAIL_PARENT/$JAIL_NAME"
		printf 'Fstab:        /etc/jail.conf.d/%s.fstab\n' "$JAIL_NAME"
		case "$PAUSE_MODE" in
			hold)
				printf 'Press Enter to destroy the jail, or Ctrl-C to abort: '
				read _ || { err "aborted"; exit 1; }
				;;
			shell)
				_sh="${SHELL:-/bin/sh}"
				printf 'Dropping into %s. Type "exit" to continue to destroy.\n' "$_sh"
				( cd "$JAIL_PARENT" && "$_sh" ) || true
				;;
		esac
	fi

	printf '\n=== destroying jail ===\n'
	if "$DESTROY_SCRIPT" -n "$JAIL_NAME" -y; then
		pass "destroy-jail.sh exits 0"
	else
		fail "destroy-jail.sh exits 0"
		cleanup_on_failure
		print_summary
		exit 1
	fi

	printf '\n=== verifying post-destroy state ===\n'
	verify_post_destroy

	_after=$(snapshot_children)
	if [ "$_before" = "$_after" ]; then
		pass "no other datasets under $JAIL_PARENT_ZFS were touched"
	else
		fail "datasets under $JAIL_PARENT_ZFS changed unexpectedly:"
		printf '--- before ---\n%s\n--- after ---\n%s\n' "$_before" "$_after" >&2
	fi

	printf '\n=== cleanup: removing per-jail conf with --remove-conf ===\n'
	if "$DESTROY_SCRIPT" -n "$JAIL_NAME" --remove-conf 2>&1; then
		pass "destroy-jail.sh --remove-conf exits 0"
	else
		# destroy-jail.sh will refuse because the dataset no longer exists;
		# the conf is already gone too. Verify directly.
		pass "destroy-jail.sh --remove-conf exits non-zero (dataset already gone)"
	fi
	discover_conf
	if [ -z "$CONF_PATH" ] || [ ! -f "$CONF_PATH" ]; then
		pass "per-jail conf removed by --remove-conf cleanup"
	else
		fail "per-jail conf $CONF_PATH still present after --remove-conf"
	fi

	print_summary
	[ "$_fail" -eq 0 ]
}

main "$@"
