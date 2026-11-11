#!/usr/bin/env bash
# Provision a self-hosted site's private Desktop feed for one Desktop site
# profile, hand the publisher token to the profile's GitHub environment, and
# optionally promote a prepared Desktop candidate onto that feed.
#
# Runs against an installed relay-control (docs/desktop-feed.md, "Profile
# administration"). Plan-only by default; nothing is written without --apply.
#
# Secrets: the admin credential is read from RELAY_ADMIN_TOKEN (the Helm
# install's bootstrap token or an organization admin bearer). The minted
# publisher token (sh_dfp_...) is piped straight from the API response into
# `gh secret set`; it is never printed, logged or written to disk.
#
# Usage:
#   RELAY_ADMIN_TOKEN=... scripts/selfhost/desktop-feed-provision.sh \
#     --site https://relay.example.com --org <org-id> --profile <profile-id> \
#     --workspace <workspace-id> --asset-prefix <prefix> \
#     [--candidate-run <desktop-release-run-id> --version <x.y.z>] [--apply]
#
# Requires: curl, jq, gh (authenticated with admin on the Desktop repo), and
# for the candidate key check, hdiutil (macOS).
set -euo pipefail

DESKTOP_REPO="${DESKTOP_REPO:-AgentWorkforce/relay-desktop}"
site="" org="" profile="" workspace="" prefix="" run="" version="" apply=0
while [ $# -gt 0 ]; do
  case "$1" in
    --site) site="${2%/}"; shift 2;;
    --org) org="$2"; shift 2;;
    --profile) profile="$2"; shift 2;;
    --workspace) workspace="$2"; shift 2;;
    --asset-prefix) prefix="$2"; shift 2;;
    --candidate-run) run="$2"; shift 2;;
    --version) version="$2"; shift 2;;
    --apply) apply=1; shift;;
    -h|--help) sed -n '2,22p' "$0"; exit 0;;
    *) echo "unknown argument: $1" >&2; exit 2;;
  esac
done
for v in site org profile workspace prefix; do
  [ -n "${!v}" ] || { echo "--${v/prefix/asset-prefix} is required" >&2; exit 2; }
done
[[ "$site" == https://* ]] || { echo "--site must be https" >&2; exit 2; }
[[ "$profile" =~ ^[a-z0-9]{1,32}$ ]] || { echo "--profile must be a lowercase id" >&2; exit 2; }
[ -n "${RELAY_ADMIN_TOKEN:-}" ] || { echo "RELAY_ADMIN_TOKEN is required (never pass it as an argument)" >&2; exit 2; }
[[ "$RELAY_ADMIN_TOKEN" =~ ^[A-Za-z0-9._~+/=-]+$ ]] || {
  echo "RELAY_ADMIN_TOKEN contains unsupported bearer-token characters" >&2
  exit 2
}
# Keep the bearer in shell memory only. Child processes must not inherit it in
# their environment, and curl receives it through its stdin config below.
admin_token="$RELAY_ADMIN_TOKEN"
unset RELAY_ADMIN_TOKEN
if [ -n "$run" ] && [ -z "$version" ]; then echo "--version is required with --candidate-run" >&2; exit 2; fi
env_name="desktop-$profile"
base="$site/api/v1/organizations/$org/desktop-feed/profiles"

api() { # method path [json]; streams body and fails on non-2xx
  local method="$1" url="$2" body="${3:-}"
  local -a curl_args
  curl_args=(-sS --fail -X "$method" "$url"
    -H 'Accept: application/json')
  if [ -n "$body" ]; then
    curl_args+=(-H 'Content-Type: application/json' --data "$body")
  fi
  printf 'header = "Authorization: Bearer %s"\n' "$admin_token" |
    curl --config - "${curl_args[@]}"
}
api_with_status() { # method path [json]; streams body followed by a final HTTP status line
  local method="$1" url="$2" body="${3:-}"
  local -a curl_args
  curl_args=(-sS -w $'\n%{http_code}' -X "$method" "$url"
    -H 'Accept: application/json')
  if [ -n "$body" ]; then
    curl_args+=(-H 'Content-Type: application/json' --data "$body")
  fi
  printf 'header = "Authorization: Bearer %s"\n' "$admin_token" |
    curl --config - "${curl_args[@]}"
}
say() { printf '%s\n' "$*"; }

say "== plan ($([ $apply = 1 ] && echo APPLY || echo plan-only)): site=$site profile=$profile env=$env_name"

# 1. Profile: reuse when present, otherwise register.
profile_response=$(api_with_status GET "$base/$profile")
profile_code="${profile_response##*$'\n'}"
profile_json="${profile_response%$'\n'*}"
case "$profile_code" in
  2??)
    say "profile exists"
    ;;
  404)
    profile_json=""
    if [ $apply = 1 ]; then
      profile_json=$(api POST "$base" "$(jq -nc --arg id "$profile" --arg p "$prefix" '{id:$id, asset_prefix:$p}')")
      say "profile registered"
    else
      say "would register profile (asset_prefix=$prefix)"
    fi
    ;;
  *)
    echo "GET $base/$profile -> HTTP $profile_code" >&2
    exit 1
    ;;
esac

# 2. The signing public key the site will sign with (public, safe to print).
pub=$(printf '%s' "$profile_json" | jq -r '.signing_key.public_key // .signing_keys[0].public_key // empty' 2>/dev/null || true)
key_id=$(printf '%s' "$profile_json" | jq -r '.signing_key.key_id // .signing_keys[0].key_id // empty' 2>/dev/null || true)
[ -n "$pub" ] && say "signing key $key_id public_key=$pub"

# 3. Workspace binding (idempotent PUT).
if [ $apply = 1 ]; then api PUT "$base/$profile/workspaces/$workspace" >/dev/null; say "workspace bound"; else say "would bind workspace $workspace"; fi

# 4. The candidate must carry this site's public key, or the app refuses its own feed.
if [ -n "$run" ] && [ -n "$pub" ]; then
  candidate_dir=$(mktemp -d)
  candidate_mnt="$candidate_dir/mnt"
  candidate_attached=0
  cleanup_candidate() {
    if [ "$candidate_attached" = 1 ]; then
      if ! hdiutil detach "$candidate_mnt" -quiet; then
        echo "failed to detach candidate volume at $candidate_mnt" >&2
        return 1
      fi
      candidate_attached=0
    fi
    rm -rf "$candidate_dir"
  }
  cleanup_candidate_on_exit() {
    local rc="$1"
    trap - EXIT
    cleanup_candidate || rc=1
    exit "$rc"
  }
  trap 'cleanup_candidate_on_exit "$?"' EXIT
  gh run download "$run" -R "$DESKTOP_REPO" -n dmg-arm64 -D "$candidate_dir" >/dev/null
  dmg=$(find "$candidate_dir" -maxdepth 1 -type f -name '*.dmg' -print -quit)
  [ -n "$dmg" ] || { echo "candidate run $run did not contain a dmg-arm64 DMG" >&2; exit 1; }
  mkdir "$candidate_mnt"
  hdiutil attach -nobrowse -readonly -mountpoint "$candidate_mnt" "$dmg" >/dev/null
  candidate_attached=1
  if grep -rqF -- "$pub" "$candidate_mnt" 2>/dev/null; then say "candidate $run embeds this site's feed key: OK"; key_ok=1
  else say "candidate $run does NOT embed this site's feed key: rebuild the candidate after step 5"; key_ok=0; fi
  if ! cleanup_candidate; then
    trap - EXIT
    exit 1
  fi
  trap - EXIT
fi

# 5. Keep the profile environment's public key in step with the site, then mint
#    the publisher token straight into the environment secret.
if [ $apply = 1 ]; then
  [ -n "$pub" ] && printf '%s' "$pub" | gh secret set DESKTOP_FEED_PUBLIC_KEY -R "$DESKTOP_REPO" --env "$env_name"
  api POST "$base/$profile/publisher-tokens" '{"label":"desktop-ci"}' \
    | jq -er '.token // .publisher_token // .value' \
    | gh secret set DESKTOP_FEED_PUBLISHER_TOKEN -R "$DESKTOP_REPO" --env "$env_name"
  say "publisher token minted and stored in $env_name (value not shown)"
else
  say "would set DESKTOP_FEED_PUBLIC_KEY and mint DESKTOP_FEED_PUBLISHER_TOKEN into $env_name"
fi

# 6. Promote the prepared candidate onto the site's feed.
if [ -n "$run" ]; then
  if [ "${key_ok:-0}" != 1 ]; then say "skipping promote: candidate key check did not pass"; exit 0; fi
  if [ $apply = 1 ]; then
    gh workflow run desktop-promote.yml -R "$DESKTOP_REPO" -f profile="$profile" -f candidate-run-id="$run" -f version="$version" -f channel=stable
    say "Desktop Promote dispatched for run $run version $version"
  else
    say "would dispatch Desktop Promote for run $run version $version"
  fi
fi
