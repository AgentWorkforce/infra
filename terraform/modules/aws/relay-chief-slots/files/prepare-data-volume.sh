#!/usr/bin/env bash
# Mount a slot's data volume at /var/lib/relay-chief, formatting it only if it
# is verifiably blank. Run by bootstrap on each new host, and safe to re-run.
#
#   relay-chief-prepare-data-volume <device>
#
# A volume with any signature is the previous host's ledger or something
# unexpected, so it is never formatted. If the check itself fails, nothing is
# known about the volume and the script stops.
set -euo pipefail
umask 022

ROOT="${RELAY_CHIEF_ROOT:-}"
DATA_DIR="$ROOT/var/lib/relay-chief"
MARKER="$DATA_DIR/.slot-binding.json"
FSTAB="$ROOT/etc/fstab"
MOUNT_POINT=/var/lib/relay-chief

fail() {
  printf 'relay-chief-prepare-data-volume: %s\n' "$1" >&2
  exit 1
}

[ $# -eq 1 ] || fail "usage: relay-chief-prepare-data-volume <device>"
device="$(readlink -f "$1")"

# Captured on its own: as part of a test expression, a wipefs failure would
# look the same as a blank volume.
if ! signatures="$(wipefs --no-act --noheadings "$device")"; then
  fail "could not inspect the data volume; refusing to format it"
fi
if [ -z "$signatures" ]; then
  mkfs.ext4 -q -L relay-chief-data "$device"
elif [ "$(blkid -p -o value -s TYPE "$device" || true)" != "ext4" ]; then
  fail "the data volume holds an unexpected filesystem"
fi

uuid="$(blkid -p -o value -s UUID "$device")"
[ -n "$uuid" ] || fail "the data volume has no filesystem UUID"
install -d -m 0700 "$DATA_DIR"
grep -q " $MOUNT_POINT " "$FSTAB" 2>/dev/null ||
  echo "UUID=$uuid $MOUNT_POINT ext4 defaults,noatime,nofail,x-systemd.device-timeout=30s 0 2" >>"$FSTAB"
systemctl daemon-reload
mountpoint -q "$DATA_DIR" || mount "$MOUNT_POINT"
mountpoint -q "$DATA_DIR" || fail "the data volume did not mount"

# Recursive because a replacement host's AMI may assign relay-chief a different
# uid than the one that wrote the ledger. -h keeps a symlink on the volume from
# redirecting this root chown to a file outside it.
chown -hR relay-chief:relay-chief "$DATA_DIR"
if [ -e "$MARKER" ]; then
  chown -h root:root "$MARKER"
fi
chmod 0700 "$DATA_DIR"
