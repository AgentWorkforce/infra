#!/usr/bin/env bash
# Sign CloudFront URLs with a custom policy. Uses only openssl and coreutils.
#
#   sign-url.sh <resource> <expires> <key-pair-id> <private-key-pem-file> [<url-to-sign> ...]
#
# <resource>     the URL the policy covers; it may end in a wildcard, such as
#                https://downloads.example.com/example-channel/latest/*, so one
#                policy covers several files
# <expires>      a UTC epoch (seconds) or any date `date -d` reads, such as
#                2030-01-31T12:00:00Z; a time in the past is refused
# <key-pair-id>  the public_key_id output of the Terraform root
# <private-key>  a path to the RSA private key (a process substitution or FIFO
#                works; it is read once, never printed)
# <url-to-sign>  each is written to stdout as <url>?Policy=...&Signature=...&Key-Pair-Id=...
#                (with no URLs, the resource itself is signed if it has no wildcard)
set -euo pipefail

die() {
  echo "sign-url.sh: $*" >&2
  exit 1
}

if [ $# -lt 4 ]; then
  sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
fi
resource="$1" expires="$2" key_id="$3" key_file="$4"
shift 4

case "$resource" in https://?*) ;; *) die "resource must be an https URL" ;; esac
[[ "$resource" =~ ^[^\"\\[:space:][:cntrl:]]+$ ]] || die "resource must not contain quotes, backslashes or whitespace"
[[ "$key_id" =~ ^[A-Za-z0-9]+$ ]] || die "key-pair-id must be alphanumeric"

if [[ "$expires" =~ ^[0-9]+$ ]]; then
  epoch="$expires"
else
  epoch="$(date -u -d "$expires" +%s 2>/dev/null)" || die "cannot read the expiry: $expires"
fi
now="$(date -u +%s)"
[ "$epoch" -gt "$now" ] || die "the expiry is in the past"

urls=("$@")
if [ ${#urls[@]} -eq 0 ]; then
  [[ "$resource" != *'*'* ]] || die "give the URLs to sign when the resource has a wildcard"
  urls=("$resource")
fi

# CloudFront's URL-safe base64: + - =  _  / ~
cf_b64() { base64 -w0 | tr '+=/' '-_~'; }

policy="{\"Statement\":[{\"Resource\":\"$resource\",\"Condition\":{\"DateLessThan\":{\"AWS:EpochTime\":$epoch}}}]}"
policy_b64="$(printf '%s' "$policy" | cf_b64)"
# CloudFront signed URLs require RSA-SHA1. The key file is read by openssl only.
signature="$(printf '%s' "$policy" | openssl dgst -sha1 -sign "$key_file" | cf_b64)"
[ -n "$signature" ] || die "signing failed"

for url in "${urls[@]}"; do
  sep='?'
  [[ "$url" != *'?'* ]] || sep='&'
  printf '%s%sPolicy=%s&Signature=%s&Key-Pair-Id=%s\n' "$url" "$sep" "$policy_b64" "$signature" "$key_id"
done
