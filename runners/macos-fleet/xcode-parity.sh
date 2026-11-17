#!/bin/bash
# Checks that this Mac matches the toolchain the routed CI lanes assume.
# Exit 0 = at parity. Any other exit = do not take jobs. Reads parity.env
# (repo default) and /etc/fleet-runner/parity.env (per-Mac override) if present.
#
#   xcode-parity.sh            check, print a one-line verdict per item
#   xcode-parity.sh --print    print what this Mac has, no verdict
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
for f in "$here/parity.env" /etc/fleet-runner/parity.env; do
  # shellcheck disable=SC1090 # per-Mac override, same KEY=value shape
  [ -f "$f" ] && . "$f"
done
: "${EXPECTED_ARCH:=arm64}" "${EXPECTED_MACOS_MIN_MAJOR:=15}"
: "${EXPECTED_XCODE_VERSION:?parity.env must set EXPECTED_XCODE_VERSION}"
: "${EXPECTED_XCODE_BUILD:?parity.env must set EXPECTED_XCODE_BUILD}"
: "${DEVELOPER_DIR:?parity.env must set DEVELOPER_DIR}"
export DEVELOPER_DIR

arch=$(uname -m)
macos=$(sw_vers -productVersion)
xcode_version=""; xcode_build=""
if [ -d "$DEVELOPER_DIR" ]; then
  out=$(xcodebuild -version 2>/dev/null || true)
  xcode_version=$(printf '%s\n' "$out" | awk '/^Xcode /{print $2}')
  xcode_build=$(printf '%s\n' "$out" | awk '/^Build version /{print $3}')
fi

if [ "${1:-}" = "--print" ]; then
  printf 'arch=%s\nmacos=%s\ndeveloper_dir=%s\nxcode_version=%s\nxcode_build=%s\n' \
    "$arch" "$macos" "$DEVELOPER_DIR" "${xcode_version:-missing}" "${xcode_build:-missing}"
  exit 0
fi

rc=0
check() { # name actual expected
  if [ "$2" = "$3" ]; then echo "ok   $1: $2"; else echo "FAIL $1: have '$2', want '$3'"; rc=1; fi
}
check arch "$arch" "$EXPECTED_ARCH"
if [ "${macos%%.*}" -ge "$EXPECTED_MACOS_MIN_MAJOR" ]; then
  echo "ok   macos: $macos (>= $EXPECTED_MACOS_MIN_MAJOR)"
else
  echo "FAIL macos: have '$macos', want >= $EXPECTED_MACOS_MIN_MAJOR"; rc=1
fi
check xcode_version "${xcode_version:-missing}" "$EXPECTED_XCODE_VERSION"
check xcode_build "${xcode_build:-missing}" "$EXPECTED_XCODE_BUILD"
if xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1; then
  echo "ok   xcode_first_launch: done"
else
  echo "FAIL xcode_first_launch: run 'sudo xcodebuild -license accept && sudo xcodebuild -runFirstLaunch'"; rc=1
fi
if command -v git >/dev/null 2>&1; then echo "ok   git: $(git --version | awk '{print $3}')"; else echo "FAIL git: missing"; rc=1; fi
exit "$rc"
