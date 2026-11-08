#!/usr/bin/env bash
# Download a checksum-pinned artifact for bootstrap. An https:// URL uses curl;
# an s3:// URI uses the instance role through the AWS CLI.
#
#   relay-chief-fetch-artifact <url> <sha256> <region> <destination>
#
# The destination appears only after the checksum matched: the download goes to
# a .part file beside it, which is removed on any failure. Bootstrap runs with
# set -e, so it cannot unpack an unverified file.
set -euo pipefail
umask 077

# A new instance role can take a while to work everywhere, and bootstrap runs
# only once, so a failed S3 download is retried for about two minutes.
S3_ATTEMPTS=12
S3_RETRY_DELAY=10

fail() {
  printf 'relay-chief-fetch-artifact: %s\n' "$1" >&2
  exit 1
}

[ $# -eq 4 ] || fail "usage: relay-chief-fetch-artifact <url> <sha256> <region> <destination>"
url="$1" sha256="$2" region="$3" destination="$4"
part="$destination.part"

trap 'rm -f -- "$part"' EXIT
rm -f -- "$destination" "$part"

download_s3() {
  local attempt
  for ((attempt = 1; attempt <= S3_ATTEMPTS; attempt++)); do
    rm -f -- "$part"
    if aws --region "$region" s3 cp --only-show-errors "$url" "$part"; then
      return 0
    fi
    if [ "$attempt" -lt "$S3_ATTEMPTS" ]; then
      sleep "$S3_RETRY_DELAY"
    fi
  done
  return 1
}

case "$url" in
s3://*)
  download_s3 || fail "could not download the artifact from S3"
  ;;
https://*)
  curl -fsSL --proto '=https' --tlsv1.2 --retry 5 -o "$part" "$url" || fail "could not download the artifact over HTTPS"
  ;;
*)
  fail "unsupported artifact URL scheme"
  ;;
esac

# Checked once, outside the retry: a mismatch is a wrong file, not a transient
# failure, and must never be retried into success.
if ! printf '%s  %s\n' "$sha256" "$part" | sha256sum --check --strict --quiet >/dev/null 2>&1; then
  fail "the artifact does not match its sha256; refusing to install it"
fi
mv -f -- "$part" "$destination"
