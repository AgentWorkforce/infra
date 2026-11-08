#!/usr/bin/env bash
# Mount a slot's data volume at /var/lib/relay-chief, formatting it only if it
# is verifiably blank. Run by bootstrap on each new host, and safe to re-run.
#
#   relay-chief-prepare-data-volume <device>
#
# A volume with any signature is the previous host's ledger or something
# unexpected, so it is never formatted. Formatting needs positive proof of a
# blank device; if a check fails, nothing is known and the script stops.
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
  # wipefs also reports nothing, and exits 0, when the device cannot be read, so
  # an empty result alone does not mean blank. cmp exits 0 only if the first 4 KiB
  # was read and is all zeros, 1 if it differs, and 2 on a read error. That range
  # holds the ext4 superblock. Do not widen it: a new encrypted EBS volume was
  # seen returning non-zero data from byte 4097 onward.
  zero_status=0
  cmp -s -n 4096 "$device" /dev/zero || zero_status=$?
  if [ "$zero_status" -ne 0 ]; then
    fail "the data volume is not verifiably blank (cmp status $zero_status); refusing to format it"
  fi
  # An ext4 volume whose first blocks were zeroed still has its first backup
  # superblock: group 1 at 4 KiB blocks, with the 0xEF53 magic 56 bytes in. An
  # empty read means the device is too small to have one.
  if ! backup_magic="$(dd if="$device" bs=4096 iflag=skip_bytes,count_bytes skip=$((32768 * 4096 + 56)) count=2 status=none | od -An -tx1 | tr -d ' \n')"; then
    fail "could not read the backup superblock location; refusing to format it"
  fi
  if [ "$backup_magic" = "53ef" ]; then
    fail "the data volume is not verifiably blank (backup ext4 superblock found); refusing to format it"
  fi
  mkfs.ext4 -q -b 4096 -L relay-chief-data "$device"
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
