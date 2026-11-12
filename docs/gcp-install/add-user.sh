#!/usr/bin/env bash
# 0-START-HERE.md step 15: add a user with a temporary password, without SMTP.
#
#   bash add-user.sh <app hostname> [member|admin|owner]
#
# Run as the owner, after the setup-key sign-in. It asks for your email and
# password (nothing is echoed or put on a command line), then for the new user's
# email, and prints a temporary password to give them. They sign in at
# https://<app hostname>/login with it and choose their own; the temporary one
# then stops working. Needs curl and jq.
set -euo pipefail
DOMAIN="${1:?usage: bash add-user.sh <app hostname> [member|admin|owner]}"
ROLE="${2:-member}"
case "$ROLE" in member|admin|owner) ;; *) echo "role must be member, admin or owner" >&2; exit 2 ;; esac
API="https://api.$DOMAIN"
JAR="$(mktemp)"; chmod 600 "$JAR"; trap 'rm -f "$JAR"' EXIT

# 1. Sign in as the owner. The session cookie lands in $JAR; the response names
#    your organization.
read -r -p 'Your (owner) email: ' OWNER
read -rs -p 'Your password: ' PW; echo
ORG="$(jq -n --arg e "$OWNER" --arg p "$PW" '{email:$e,password:$p}' |
  curl -fsS -c "$JAR" -H "Origin: https://$DOMAIN" -H 'Content-Type: application/json' --data-binary @- \
    "$API/api/v1/auth/password/login" | jq -r .organizationId)"
unset PW
[ -n "$ORG" ] && [ "$ORG" != null ] || { echo "sign-in failed" >&2; exit 1; }

# 2. Invite with a temporary password. The /cloud prefix (the cookie's path) and
#    the Origin header are both required.
while read -r -p 'New user email (empty to finish): ' NEW && [ -n "$NEW" ]; do
  jq -n --arg e "$NEW" --arg r "$ROLE" '{email:$e,role:$r,temporaryPassword:true}' |
    curl -fsS -b "$JAR" -H "Origin: https://$DOMAIN" -H 'Content-Type: application/json' --data-binary @- \
      "$API/cloud/api/v1/organizations/$ORG/invitations" |
    jq -r '"Give \(.invitation.email) this temporary password (expires \(.temporaryPasswordExpiresAt)): \(.temporaryPassword)"'
done
