#!/usr/bin/env bash
# Runs scripts/publish.sh against a stand-in `aws` that keeps objects in a
# temp dir. No cloud credentials and no network.
#   tests/publish-test.sh
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
publish="$here/../scripts/publish.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# The stand-in covers only the calls publish.sh makes. s3://<bucket>/<key> is
# the file $FAKE_S3/<bucket>/<key>.
mkdir -p "$tmp/bin" "$tmp/s3"
cat >"$tmp/bin/aws" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail
path() { case "$1" in s3://*) echo "$FAKE_S3/${1#s3://}" ;; *) echo "$1" ;; esac; }
opt() { # opt <name> <args...>: the value after --<name>
  local want="--$1"
  shift
  while [ $# -gt 0 ]; do
    if [ "$1" = "$want" ]; then
      echo "$2"
      return 0
    fi
    shift
  done
  return 1
}
missing() {
  echo "An error occurred (404) when calling the HeadObject operation: Not Found" >&2
  exit 254
}
case "$1 $2" in
  "s3 cp")
    src="$(path "$3")"
    dst="$(path "$4")"
    [ -f "$src" ] || missing
    mkdir -p "$(dirname "$dst")"
    cp "$src" "$dst"
    ;;
  "s3api list-objects-v2")
    [ -z "${FAKE_LIST_EMPTY:-}" ] || { echo 0; exit 0; }
    dir="$FAKE_S3/$(opt bucket "$@")/$(opt prefix "$@")"
    if [ -d "$dir" ] && [ -n "$(ls -A "$dir")" ]; then echo 1; else echo 0; fi
    ;;
  "s3api head-object")
    f="$FAKE_S3/$(opt bucket "$@")/$(opt key "$@")"
    [ -f "$f" ] || missing
    stat -c %s "$f"
    ;;
  "s3api put-object")
    f="$FAKE_S3/$(opt bucket "$@")/$(opt key "$@")"
    [ "$(opt if-none-match "$@")" = "*" ] || { echo "unconditional put-object" >&2; exit 2; }
    if [ -e "$f" ]; then
      echo "An error occurred (PreconditionFailed) when calling the PutObject operation: At least one of the pre-conditions you specified did not hold" >&2
      exit 254
    fi
    mkdir -p "$(dirname "$f")"
    cp "$(opt body "$@")" "$f"
    ;;
  "s3api delete-object")
    rm -f "$FAKE_S3/$(opt bucket "$@")/$(opt key "$@")"
    ;;
  *)
    echo "stand-in aws: unsupported: $*" >&2
    exit 2
    ;;
esac
SHIM
chmod +x "$tmp/bin/aws"
export PATH="$tmp/bin:$PATH" FAKE_S3="$tmp/s3"

root="$tmp/s3/example-bucket/desktop/example-channel"
mkdir "$tmp/dist"
printf 'mac' >"$tmp/dist/Example-1.2.3-arm64.dmg"
printf 'windows' >"$tmp/dist/Example-1.2.3-setup.exe"

# expect_fail <text in stderr> <publish.sh args...>
expect_fail() {
  local want="$1"
  shift
  if "$publish" "$@" >"$tmp/out" 2>"$tmp/err"; then fail "expected a failure: $*"; fi
  grep -q -- "$want" "$tmp/err" || fail "expected '$want' in: $(cat "$tmp/err")"
}
latest_untouched() { [ ! -e "$root/latest" ] || fail "$1 changed latest/"; }

# upload: files, checksums and the claim; a build id is used once.
"$publish" upload example-bucket desktop example-channel build-0001 "$tmp/dist" >/dev/null
for f in Example-1.2.3-arm64.dmg Example-1.2.3-setup.exe SHA256SUMS.txt .claim; do
  [ -f "$root/builds/build-0001/$f" ] || fail "upload did not write $f"
done
(cd "$root/builds/build-0001" && sha256sum --check --quiet SHA256SUMS.txt) || fail "uploaded checksums do not match"
expect_fail "already exists" upload example-bucket desktop example-channel build-0001 "$tmp/dist"
# Two uploads that both saw an empty listing: the conditional claim stops the second.
FAKE_LIST_EMPTY=1 expect_fail "already claimed" upload example-bucket desktop example-channel build-0001 "$tmp/dist"

# promote: a bad map changes nothing, wherever the bad line is.
printf 'Example.dmg\tExample-1.2.3-arm64.dmg\nExample.exe\tNo-such-file.exe\n' >"$tmp/map-missing"
expect_fail "not in the build" promote example-bucket desktop example-channel build-0001 "$tmp/map-missing"
latest_untouched "a map with a missing file"

printf 'Example.dmg\tExample-1.2.3-arm64.dmg\nVERSION.txt\tExample-1.2.3-setup.exe\n' >"$tmp/map-reserved"
expect_fail "VERSION.txt is written by this script" promote example-bucket desktop example-channel build-0001 "$tmp/map-reserved"
latest_untouched "a map with a reserved name"

printf 'Example.dmg\tExample-1.2.3-arm64.dmg\nExample.dmg\tExample-1.2.3-setup.exe\n' >"$tmp/map-twice"
expect_fail "twice" promote example-bucket desktop example-channel build-0001 "$tmp/map-twice"
latest_untouched "a map with a repeated name"

# A file listed in the checksums but gone from the build.
printf 'Example.dmg\tExample-1.2.3-arm64.dmg\nExample.exe\tExample-1.2.3-setup.exe\n' >"$tmp/map"
mv "$root/builds/build-0001/Example-1.2.3-setup.exe" "$tmp/held"
expect_fail "not in the build under" promote example-bucket desktop example-channel build-0001 "$tmp/map"
latest_untouched "a build with a missing object"
mv "$tmp/held" "$root/builds/build-0001/Example-1.2.3-setup.exe"

# A promotion that is already running holds the lock; the refused run leaves it alone.
: >"$root/.promote-lock"
expect_fail "another promotion holds" promote example-bucket desktop example-channel build-0001 "$tmp/map"
latest_untouched "a locked channel"
[ -f "$root/.promote-lock" ] || fail "the refused run removed a lock it did not hold"
rm "$root/.promote-lock"

# A good promotion.
"$publish" promote example-bucket desktop example-channel build-0001 "$tmp/map" >/dev/null
[ "$(cat "$root/latest/Example.dmg")" = "mac" ] || fail "latest/Example.dmg has the wrong content"
[ "$(cat "$root/latest/Example.exe")" = "windows" ] || fail "latest/Example.exe has the wrong content"
(cd "$root/latest" && sha256sum --check --quiet SHA256SUMS.txt) || fail "latest checksums do not match"
[ "$(wc -l <"$root/latest/SHA256SUMS.txt")" -eq 2 ] || fail "latest/SHA256SUMS.txt should list two files"
grep -q '^build: build-0001$' "$root/latest/VERSION.txt" || fail "latest/VERSION.txt does not name the build"
[ ! -e "$root/.promote-lock" ] || fail "the lock was not released"

echo "ok: publish.sh upload and promote"
