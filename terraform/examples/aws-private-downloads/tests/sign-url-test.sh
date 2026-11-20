#!/usr/bin/env bash
# Signs with a throwaway RSA key, decodes the Policy back and verifies the
# signature with openssl. The key lives in a temp dir that is always deleted.
#   tests/sign-url-test.sh
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
sign="$here/../scripts/sign-url.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}
unb64() { tr '_~-' '=/+' | base64 -d; }

openssl genrsa -out "$tmp/key.pem" 2048 2>/dev/null
openssl rsa -in "$tmp/key.pem" -pubout -out "$tmp/pub.pem" 2>/dev/null

expires=$(($(date -u +%s) + 3600))
resource="https://downloads.example.com/example-channel/latest/*"
u1="https://downloads.example.com/example-channel/latest/Example.dmg"
u2="https://downloads.example.com/example-channel/latest/Example.exe"

# The key is passed as a process substitution (a FIFO) to prove it is read from a path only.
out="$("$sign" "$resource" "$expires" KEXAMPLEKEYID <(cat "$tmp/key.pem") "$u1" "$u2")"
[ "$(wc -l <<<"$out")" -eq 2 ] || fail "expected two URLs"
grep -q "BEGIN" <<<"$out" && fail "output contains key material"

n=0
while IFS= read -r url; do
  n=$((n + 1))
  [[ "$url" == "$u1?"* || "$url" == "$u2?"* ]] || fail "url $n has the wrong base"
  query="${url#*\?}"
  policy_b64="${query#Policy=}"
  policy_b64="${policy_b64%%&*}"
  sig_b64="${query#*&Signature=}"
  sig_b64="${sig_b64%%&*}"
  [ "${query##*&Key-Pair-Id=}" = "KEXAMPLEKEYID" ] || fail "url $n has the wrong Key-Pair-Id"
  [[ "$policy_b64$sig_b64" != *[+=/]* ]] || fail "url $n is not URL-safe base64"

  printf '%s' "$policy_b64" | unb64 >"$tmp/policy.json"
  printf '%s' "$sig_b64" | unb64 >"$tmp/sig.bin"
  expected="{\"Statement\":[{\"Resource\":\"$resource\",\"Condition\":{\"DateLessThan\":{\"AWS:EpochTime\":$expires}}}]}"
  [ "$(cat "$tmp/policy.json")" = "$expected" ] || fail "url $n policy differs from the expected compact JSON"
  openssl dgst -sha1 -verify "$tmp/pub.pem" -signature "$tmp/sig.bin" "$tmp/policy.json" >/dev/null || fail "url $n signature does not verify"
  echo "ok: url $n policy and signature verify"
done <<<"$out"

# An ISO date in the future works; a past one is refused.
"$sign" "$u1" "2099-01-01T00:00:00Z" KEXAMPLEKEYID "$tmp/key.pem" >/dev/null || fail "ISO expiry rejected"
echo "ok: ISO expiry accepted, resource signed when no URL is given"
if "$sign" "$u1" "$(($(date -u +%s) - 10))" KEXAMPLEKEYID "$tmp/key.pem" >/dev/null 2>&1; then
  fail "a past expiry was accepted"
fi
echo "ok: past expiry refused"
if "$sign" "$resource" "$expires" KEXAMPLEKEYID "$tmp/key.pem" >/dev/null 2>&1; then
  fail "a wildcard resource with no URL was accepted"
fi
echo "ok: wildcard without URLs refused"
echo "all sign-url checks passed"
