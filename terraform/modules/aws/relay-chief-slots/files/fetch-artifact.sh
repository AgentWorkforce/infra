#!/usr/bin/env bash
# Download a checksum-pinned artifact for bootstrap. An https:// URL uses curl;
# an s3:// URI uses the instance role through the AWS CLI.
#
#   relay-chief-fetch-artifact <url> <sha256> <region> <destination>
#
# The destination exists only if the checksum matched, so bootstrap (which runs
# with set -e) cannot unpack an unverified file.
set -euo pipefail
umask 077

fail() {
  printf 'relay-chief-fetch-artifact: %s\n' "$1" >&2
  exit 1
}

[ $# -eq 4 ] || fail "usage: relay-chief-fetch-artifact <url> <sha256> <region> <destination>"
url="$1" sha256="$2" region="$3" destination="$4"

rm -f -- "$destination"
case "$url" in
s3://*)
  aws --region "$region" s3 cp --only-show-errors "$url" "$destination" || fail "could not download the artifact from S3"
  ;;
https://*)
  curl -fsSL --proto '=https' --tlsv1.2 --retry 5 -o "$destination" "$url" || fail "could not download the artifact over HTTPS"
  ;;
*)
  fail "unsupported artifact URL scheme"
  ;;
esac

if ! printf '%s  %s\n' "$sha256" "$destination" | sha256sum --check --strict --quiet >/dev/null 2>&1; then
  rm -f -- "$destination"
  fail "the artifact does not match its sha256; refusing to install it"
fi
