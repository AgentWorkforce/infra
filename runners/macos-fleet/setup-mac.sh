#!/bin/bash
# One-time install of a fleet slot on an Apple-silicon Mac. Run as root from
# this directory (a checkout of AgentWorkforce/infra):
#
#   sudo ./setup-mac.sh --slot a --broker-url https://fleet-runner-jit.<acct>.workers.dev \
#        --key-file /path/to/this-macs-key [--runner-version 2.338.2] \
#        [--runner-sha256 <hex>] [--quota-gb 120]
#   sudo ./setup-mac.sh --slot a --uninstall
#
# What it creates: a hidden standard user ghrunner-<slot> (no password login,
# member of _developer so xcodebuild works), optionally an APFS volume with a
# quota as its home, /usr/local/libexec/fleet-runner/{supervisor,parity},
# /usr/local/share/fleet-runner/actions-runner-<ver>.tar.gz (sha256-checked),
# /etc/fleet-runner/<slot>.env (0600) and <slot>.auth (0400, the Mac's key),
# and the LaunchDaemon com.agentworkforce.fleet-runner.<slot>. It then prints
# the manual steps that remain (Xcode license, Remote Login, power settings).
set -euo pipefail

RUNNER_VERSION=2.338.2
RUNNER_SHA256=25a065af409ffa317ab4d5a3b614dd15fc9c40f2172bc1b35a1b1258e919a388
slot="" broker_url="" key_file="" quota_gb="" uninstall=0
while [ $# -gt 0 ]; do
  case "$1" in
    --slot) slot=$2; shift 2 ;;
    --broker-url) broker_url=$2; shift 2 ;;
    --key-file) key_file=$2; shift 2 ;;
    --runner-version) RUNNER_VERSION=$2; shift 2 ;;
    --runner-sha256) RUNNER_SHA256=$2; shift 2 ;;
    --quota-gb) quota_gb=$2; shift 2 ;;
    --uninstall) uninstall=1; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
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
volume="fleet-$slot"

if [ "$uninstall" = 1 ]; then
  launchctl bootout system "$plist" 2>/dev/null || true
  rm -f "$plist"
  pkill -KILL -u "$user" 2>/dev/null || true
  if id "$user" >/dev/null 2>&1; then sysadminctl -deleteUser "$user" >/dev/null 2>&1 || dscl . -delete "/Users/$user"; fi
  if diskutil info "$volume" >/dev/null 2>&1; then diskutil apfs deleteVolume "$volume"; fi
  rm -rf "/Users/$user" "$etc/$slot.env" "$etc/$slot.auth" "/var/run/fleet-runner/$slot".*
  echo "removed slot $slot (logs kept in /var/log/fleet-runner/$slot, shared files in $libexec and $share kept)"
  exit 0
fi

[ -n "$broker_url" ] || { echo "--broker-url is required" >&2; exit 64; }
[ -r "$key_file" ] || { echo "--key-file must be a readable file holding this Mac's key" >&2; exit 64; }
[ "$(wc -c <"$key_file")" -ge 32 ] || { echo "key file looks too short" >&2; exit 64; }
if [ -n "$quota_gb" ] && ! [[ "$quota_gb" =~ ^[0-9]+$ ]]; then echo "--quota-gb must be an integer" >&2; exit 64; fi
for f in fleet-runner-supervisor.sh xcode-parity.sh parity.env com.agentworkforce.fleet-runner.plist.template; do
  [ -f "$here/$f" ] || { echo "missing $here/$f; run from runners/macos-fleet in a repo checkout" >&2; exit 64; }
done

echo "== parity check (the slot never takes jobs while this fails)"
"$here/xcode-parity.sh" || echo "   parity FAILED: install/select the expected Xcode, then rerun or just let the supervisor retry"

echo "== runner user $user"
home=/Users/$user
if [ -n "$quota_gb" ]; then
  container=$(diskutil info / | awk -F': *' '/APFS Container Reference/{print $2}')
  [ -n "$container" ] || { echo "cannot find the APFS container of /" >&2; exit 70; }
  if ! diskutil info "$volume" >/dev/null 2>&1; then
    diskutil apfs addVolume "$container" APFS "$volume" -quota "${quota_gb}g" >/dev/null
  fi
  home=/Volumes/$volume/home
fi
if ! id "$user" >/dev/null 2>&1; then
  # Random password that nobody keeps: the account is only ever entered via
  # sudo from the supervisor. Hidden from the login window and Users prefs.
  pw=$(head -c 48 /dev/urandom | base64 | tr -d '/+=' | head -c 40)
  sysadminctl -addUser "$user" -fullName "fleet runner $slot" -password "$pw" -home "$home" -shell /bin/bash >/dev/null 2>&1
  unset pw
  dscl . -create "/Users/$user" IsHidden 1
fi
dseditgroup -o edit -a "$user" -t user _developer
mkdir -p "$home"
chown "$user:staff" "$home"; chmod 700 "$home"

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
cat >"$etc/$slot.env" <<ENV
BROKER_URL=$broker_url
RUNNER_USER=$user
RUNNER_HOME=$home
RUNNER_TARBALL=$tarball
ENV
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
  5. tail -f /var/log/fleet-runner/$slot.launchd.log         (expect "runner <name> waiting for a job")
MSG
