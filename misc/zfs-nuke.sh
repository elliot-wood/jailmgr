#!/bin/sh

if [ $# -ne 1 ]; then
		echo "usage: $0 dataset" >&2
		exit 1
fi

dataset="$1"

if ! zfs list -Ho name "$dataset" >/dev/null 2>&1; then
		echo "error: dataset '$dataset' does not exist." >&2
		exit 1
fi

zfs list -Hr -t snapshot -o name "$dataset" | while read -r snapshot; do
		zfs holds -H "$snapshot" 2>/dev/null | while read -r snap_name tag timestamp; do
				echo "Releasing hold '$tag' on $snapshot" >&2
				zfs release "$tag" "$snapshot" || {
						echo "Warning: failed to release hold '$tag' on $snapshot" >&2
				}
		done
done

echo "Destroying dataset: $dataset"
zfs destroy -rf "$dataset"
