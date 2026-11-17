#!/bin/bash
# One-time install of a fleet slot on an Apple-silicon Mac. Run as root from
# this directory (a checkout of AgentWorkforce/infra):
#
#   sudo ./setup-mac.sh --slot a --broker-url https://fleet-runner-jit.<acct>.workers.dev \
#        --key-file /path/to/this-macs-key --data-volume /Volumes/<external drive> \
#        --quota-gb 300 | --whole-volume [--max-gb 250] [--runner-version 2.338.2] [--runner-sha256 <hex>]
#   sudo ./setup-mac.sh --slot a --uninstall
#
# Everything a job touches lives on the external drive named by --data-volume:
# the slot user's home (<volume>/gh-runner/<slot>: runner, _work, _tool,
# caches, DerivedData, cargo, tmp). With --quota-gb the home is instead an
# APFS volume "fleet-<slot>" with that quota, created in the drive's APFS
# container (mounted at /Volumes/fleet-<slot>), and only that volume gets
# ownership enabled and Spotlight off. --whole-volume does that to the
# drive named by --data-volume itself (every file on it starts showing its
# real on-disk owner): only for a drive dedicated to the fleet, never a
# drive people work from. One of the two is required. The internal disk is
# never used for job data; --allow-internal-disk is the only way to say otherwise.
#
# What it creates: a hidden standard user ghrunner-<slot> (no password login,
# member of _developer so xcodebuild works), the data dir/volume with
# ownership enabled, Spotlight off and a Time Machine exclusion,
# /usr/local/libexec/fleet-runner/{supervisor,parity}, the sha256-checked
# runner tarball under /usr/local/share/fleet-runner, /etc/fleet-runner/<slot>.env
# (0600) and <slot>.auth (0400, the Mac's key), and the LaunchDaemon
# com.agentworkforce.fleet-runner.<slot>. It then prints the remaining
# manual steps (Xcode license, Remote Login, power settings).
set -euo pipefail

RUNNER_VERSION=2.338.2
RUNNER_SHA256=25a065af409ffa317ab4d5a3b614dd15fc9c40f2172bc1b35a1b1258e919a388
slot="" broker_url="" key_file="" data_volume="" quota_gb="" max_gb="" uninstall=0 allow_internal=0 whole_volume=0
while [ $# -gt 0 ]; do
  case "$1" in
    --slot) slot=$2; shift 2 ;;
    --broker-url) broker_url=$2; shift 2 ;;
    --key-file) key_file=$2; shift 2 ;;
    --data-volume) data_volume=${2%/}; shift 2 ;;
    --quota-gb) quota_gb=$2; shift 2 ;;
    --max-gb) max_gb=$2; shift 2 ;;
    --allow-internal-disk) allow_internal=1; shift ;;
    --whole-volume) whole_volume=1; shift ;;
    --runner-version) RUNNER_VERSION=$2; shift 2 ;;
    --runner-sha256) RUNNER_SHA256=$2; shift 2 ;;
    --uninstall) uninstall=1; shift ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 64 ;;
  esac
done
[ "$(id -u)" = 0 ] || { echo "run as root (sudo)" >&2; exit 64; }
if [ "$(uname -s)" != Darwin ] || [ "$(uname -m)" != arm64 ]; then echo "Apple-silicon macOS only" >&2; exit 64; fi
[[ "$slot" =~ ^[a-z0-9]{1,8}$ ]] || { echo "--slot must be 1-8 lowercase letters/digits" >&2; exit 64; }

here=$(cd "$(dirname "$0")" && pwd)
user=ghrunner-$slot
label=com.agentworkforce.fleet-runner.$slot
plist=/Library/LaunchDaemons/$label.plist
etc=/etc/fleet-runner
libexec=/usr/local/libexec/fleet-runner
share=/usr/local/share/fleet-runner
volume_name="fleet-$slot"

dev_of() { df -P "$1" 2>/dev/null | awk 'NR==2{print $1}'; }

# A value from the installed env file (shell-quoted by this script, so source it).
# shellcheck disable=SC1090 # the file this script writes below
installed_value() { ( set +u; . "$etc/$slot.env" 2>/dev/null; eval "printf '%s' \"\${$1:-}\"" ); }

if [ "$uninstall" = 1 ]; then
  launchctl bootout system "$plist" 2>/dev/null || true
  rm -f "$plist"
  pkill -KILL -u "$user" 2>/dev/null || true
  home=$(installed_value RUNNER_HOME)
  if id "$user" >/dev/null 2>&1; then sysadminctl -deleteUser "$user" >/dev/null 2>&1 || dscl . -delete "/Users/$user"; fi
  if diskutil info "$volume_name" >/dev/null 2>&1; then diskutil apfs deleteVolume "$volume_name"; fi
  case "$home" in */gh-runner/"$slot") rm -rf "$home" ;; esac
  rm -rf "$etc/$slot.env" "$etc/$slot.auth" "/var/run/fleet-runner/$slot".*
  echo "removed slot $slot (logs kept in /var/log/fleet-runner/$slot, shared files in $libexec and $share kept)"
  exit 0
fi

[ -n "$broker_url" ] || { echo "--broker-url is required" >&2; exit 64; }
[ -r "$key_file" ] || { echo "--key-file must be a readable file holding this Mac's key" >&2; exit 64; }
[ "$(wc -c <"$key_file")" -ge 32 ] || { echo "key file looks too short" >&2; exit 64; }
for v in quota_gb max_gb; do
  if [ -n "${!v}" ] && ! [[ "${!v}" =~ ^[0-9]+$ ]]; then echo "--${v/_/-} must be an integer" >&2; exit 64; fi
done
for f in fleet-runner-supervisor.sh xcode-parity.sh parity.env com.agentworkforce.fleet-runner.plist.template; do
  [ -f "$here/$f" ] || { echo "missing $here/$f; run from runners/macos-fleet in a repo checkout" >&2; exit 64; }
done
if [ -f "$etc/$slot.env" ]; then
  # Re-run (runner upgrade, new key): keep the installed data location unless
  # the admin asks for the same one again; moving a slot means --uninstall first.
  installed_volume=$(installed_value DATA_VOLUME)
  installed_home=$(installed_value RUNNER_HOME)
  if [ -z "$data_volume" ] && [ -z "$quota_gb" ] && [ -n "$installed_home" ]; then
    whole_volume=1 # ownership/Spotlight were settled at install; nothing changes now
    echo "slot $slot already installed with home $installed_home; keeping it"
    data_volume=$installed_volume
    [ "$installed_volume" = /Users ] && allow_internal=1
  fi
fi
if [ -z "$data_volume" ]; then
  if [ "$allow_internal" = 1 ]; then data_volume=/Users; else
    echo "--data-volume /Volumes/<external drive> is required (job data never goes on the internal disk); external drives here:" >&2
    diskutil list external physical >&2 || true
    exit 64
  fi
fi
[ -d "$data_volume" ] || { echo "$data_volume does not exist" >&2; exit 64; }
if [ "$allow_internal" != 1 ] && [ "$(dev_of "$data_volume")" = "$(dev_of /)" ]; then
  echo "$data_volume is on the internal disk (not a mounted volume); mount the drive or pass --allow-internal-disk" >&2; exit 64
fi

echo "== parity check (the slot never takes jobs while this fails)"
"$here/xcode-parity.sh" || echo "   parity FAILED: install/select the expected Xcode, then rerun or just let the supervisor retry"

echo "== data location"
# Job data goes on the external drive, but the runner tarball, diag copies,
# the slot user's /var/folders, Xcode's first-launch packages and swap all
# land on the internal disk; a Mac that is already full fails in ways that
# take its other sessions down with it.
internal_free_gb=$(df -g /System/Volumes/Data 2>/dev/null | awk 'NR==2{print $4}')
[ -n "$internal_free_gb" ] || internal_free_gb=$(df -g / | awk 'NR==2{print $4}')
if [ "$internal_free_gb" -lt "${INTERNAL_MIN_FREE_GB:-20}" ]; then
  echo "internal disk has ${internal_free_gb} GiB free; the fleet needs at least ${INTERNAL_MIN_FREE_GB:-20} GiB there (INTERNAL_MIN_FREE_GB overrides)" >&2; exit 70
fi
mount_point=$data_volume
if [ "$allow_internal" != 1 ] && [ -z "$quota_gb" ] && [ "$whole_volume" != 1 ]; then
  cat >&2 <<EOT
choose how $data_volume is used:
  --quota-gb N     APFS only: a separate volume fleet-$slot (quota N GB) in the drive's container;
                   ownership and Spotlight change only on that volume (the choice for a shared drive)
  --whole-volume   enable ownership and turn Spotlight off on $data_volume itself; every file on
                   it then shows its real owner: only for a drive dedicated to the fleet
EOT
  exit 64
fi
if [ -n "$quota_gb" ]; then
  # Read the plist, not the text report: macOS 26 renamed the text field
  # ("APFS Container Reference" became "APFS Container"); the plist key is stable.
  container=$(diskutil info -plist "$data_volume" | plutil -extract APFSContainerReference raw -o - - 2>/dev/null || true)
  [ -n "$container" ] || { echo "$data_volume is not APFS; --quota-gb needs an APFS drive (or omit it and use --max-gb)" >&2; exit 70; }
  if ! diskutil info "$volume_name" >/dev/null 2>&1; then
    diskutil apfs addVolume "$container" APFS "$volume_name" -quota "${quota_gb}g" >/dev/null
  fi
  mount_point=/Volumes/$volume_name
  [ -d "$mount_point" ] || { echo "$mount_point did not mount" >&2; exit 70; }
fi
if [ "$allow_internal" != 1 ]; then
  # External drives default to "ignore ownership"; jobs need real uids.
  diskutil enableOwnership "$mount_point" >/dev/null 2>&1 || true
  fs=$(diskutil info -plist "$mount_point" | plutil -extract FilesystemName raw -o - - 2>/dev/null || true)
  case "$fs" in *"Case-sensitive"*) echo "   note: $mount_point is case-sensitive; hosted runners are not, so builds may differ" ;; esac
  mdutil -i off "$mount_point" >/dev/null 2>&1 || true
fi
home=$mount_point/gh-runner/$slot
if [ "$allow_internal" = 1 ]; then home=/Users/$user; fi
if [ -n "${installed_home:-}" ] && [ "$installed_home" != "$home" ]; then
  echo "slot $slot is installed with home $installed_home; run --uninstall before moving it to $home" >&2; exit 64
fi
# The parent stays root-owned so the slot user can never replace its home
# with a link (the supervisor wipes the home as root between jobs).
install -d -o root -g wheel -m 755 "$(dirname "$home")"
install -d -m 700 "$home"
tmutil addexclusion -p "$home" >/dev/null 2>&1 || true
echo "   home: $home ($(df -Pg "$home" | awk 'NR==2{print $4}') GB free)"

echo "== runner user $user"
if ! id "$user" >/dev/null 2>&1; then
  # Random password that nobody keeps: the account is only ever entered via
  # sudo from the supervisor. Hidden from the login window and Users prefs.
  pw=$(head -c 48 /dev/urandom | base64 | tr -d '/+=' | head -c 40)
  sysadminctl -addUser "$user" -fullName "fleet runner $slot" -password "$pw" -home "$home" -shell /bin/bash >/dev/null 2>&1
  unset pw
  dscl . -create "/Users/$user" IsHidden 1
fi
dscl . -create "/Users/$user" NFSHomeDirectory "$home"
dseditgroup -o edit -a "$user" -t user _developer
chown "$user:staff" "$home"; chmod 700 "$home"
[ "$(stat -f %Su "$home")" = "$user" ] || { echo "$home is not owned by $user; ownership on $mount_point is still ignored" >&2; exit 70; }

echo "== files"
install -d -m 755 "$libexec" "$share"
install -d -m 700 "$etc" /var/log/fleet-runner /var/run/fleet-runner
install -m 755 "$here/fleet-runner-supervisor.sh" "$here/xcode-parity.sh" "$libexec/"
install -m 644 "$here/parity.env" "$libexec/parity.env"
tarball=$share/actions-runner-osx-arm64-$RUNNER_VERSION.tar.gz
if [ ! -f "$tarball" ] || ! printf '%s  %s\n' "$RUNNER_SHA256" "$tarball" | shasum -a 256 -c --status; then
  curl -fsSL -o "$tarball.part" "https://github.com/actions/runner/releases/download/v$RUNNER_VERSION/actions-runner-osx-arm64-$RUNNER_VERSION.tar.gz"
  printf '%s  %s\n' "$RUNNER_SHA256" "$tarball.part" | shasum -a 256 -c --status || { rm -f "$tarball.part"; echo "runner tarball sha256 mismatch" >&2; exit 70; }
  mv "$tarball.part" "$tarball"
fi
chmod 644 "$tarball"
umask 077
# Shell-quoted (%q): the supervisor sources this file and volume names may contain spaces.
{
  printf '%s=%q\n' BROKER_URL "$broker_url" RUNNER_USER "$user" RUNNER_HOME "$home" \
    RUNNER_TARBALL "$tarball" DATA_VOLUME "$mount_point" DATA_MAX_GB "${max_gb:-${quota_gb:-0}}"
} >"$etc/$slot.env"
printf 'Authorization: Bearer %s\n' "$(tr -d '[:space:]' <"$key_file")" >"$etc/$slot.auth"
chmod 400 "$etc/$slot.auth"
umask 022
sed "s/__SLOT__/$slot/g" "$here/com.agentworkforce.fleet-runner.plist.template" >"$plist"
chown root:wheel "$plist"; chmod 644 "$plist"
plutil -lint "$plist" >/dev/null

echo "== launchd"
launchctl bootout system "$plist" 2>/dev/null || true
launchctl bootstrap system "$plist"
launchctl print "system/$label" | grep -E 'state|pid' | head -3

cat <<MSG

Slot $slot installed. Remaining manual steps on this Mac:
  1. rm -P "$key_file"            # the key now lives only in $etc/$slot.auth
  2. sudo xcodebuild -license accept && sudo xcodebuild -runFirstLaunch   (if parity printed that hint)
  3. System Settings > General > Sharing: Remote Login / Screen Sharing restricted to admins, never to $user
  4. sudo pmset -a sleep 0 disksleep 0 autorestart 1 womp 1     (stay up, come back after power loss)
  5. sudo defaults write /Library/Preferences/SystemConfiguration/autodiskmount AutomountDisksWithoutUserLogin -bool true
     (external drives otherwise mount only after someone logs in; until then the slot sits in state volume-unavailable)
  6. tail -f /var/log/fleet-runner/$slot.launchd.log         (expect "runner <name> waiting for a job")
  Optional: ALERT_URL='https://...' (quoted) in $etc/$slot.env to get volume/parity/mint problems POSTed somewhere.
MSG
