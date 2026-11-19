#!/usr/bin/env bash
# 0-START-HERE.md step 15: the first admin's sign-in, done by whoever runs the
# install, when the admin can't reach the cluster (for example a private
# control plane). Neither the setup key nor the password is printed or put on
# a command line.
#
#   bash first-admin.sh <app hostname> <project id> [namespace]
#
# Optional environment:
#   API_HOST       the API's host name. Default: api.<app hostname>. Set it when
#                  the API has another name. The Origin header stays the app
#                  hostname.
#   PASSWORD_FILE  keep the password in this new local file (mode 0600) instead
#                  of Secret Manager. gcloud is then not needed and <project id>
#                  is not used (pass -). The file must not exist yet.
#
# It generates a password, stores it in Secret Manager as
# agent-relay-first-admin-password (before using it, so it is never lost), then
# posts it with the setup key from the agent-relay-secrets Secret. On 200 the
# admin reads the password with
#   gcloud secrets versions access latest --secret agent-relay-first-admin-password --project <project id>
# and signs in at https://<app hostname>/login. Without PASSWORD_FILE this
# needs secretmanager.googleapis.com enabled and permission to create a secret
# in the project.
#
# The setup key works once, within 24 hours of the install: this script never
# retries. A 403 csrf_rejected is refused before the key is read, so the key
# stays unused; any other failure: read its message, fix the cause, run again.
# Needs kubectl (on the cluster), curl, jq and openssl, and gcloud unless
# PASSWORD_FILE is set.
set -euo pipefail
USAGE='usage: [API_HOST=<api hostname>] [PASSWORD_FILE=<new file>] bash first-admin.sh <app hostname> <project id> [namespace]'
DOMAIN="${1:?$USAGE}"
PROJECT="${2:?$USAGE}"
NAMESPACE="${3:-agent-relay}"
API_HOST="${API_HOST:-api.$DOMAIN}"
PASSWORD_FILE="${PASSWORD_FILE:-}"
SECRET=agent-relay-first-admin-password
case "$DOMAIN" in *[!A-Za-z0-9.-]*|"") echo "app hostname must be a bare host name, e.g. relay.example.com" >&2; exit 2 ;; esac
case "$API_HOST" in *[!A-Za-z0-9.-]*|"") echo "API_HOST must be a bare host name, e.g. relay-api.example.com" >&2; exit 2 ;; esac
tools="kubectl curl jq openssl"
[ -n "$PASSWORD_FILE" ] || tools="gcloud $tools"
for tool in $tools; do
  command -v "$tool" >/dev/null || { echo "$tool is required" >&2; exit 2; }
done

# 1. The setup key must exist before anything is stored.
kubectl -n "$NAMESPACE" get secret agent-relay-secrets -o jsonpath='{.data.selfhost-setup-key}' | grep -q . ||
  { echo "agent-relay-secrets in namespace $NAMESPACE has no selfhost-setup-key (step 10)" >&2; exit 1; }

# 2. Store the password first. An existing secret means a run already stored
#    one: stop rather than replace a password the admin may already use.
if [ -n "$PASSWORD_FILE" ]; then
  if [ -e "$PASSWORD_FILE" ] || [ -L "$PASSWORD_FILE" ]; then
    echo "$PASSWORD_FILE already exists: the first sign-in may already be done." >&2
    echo "Sign in with that password; to start over, delete the file yourself first." >&2
    exit 1
  fi
  STORED="the file $PASSWORD_FILE"
elif gcloud secrets describe "$SECRET" --project "$PROJECT" >/dev/null 2>&1; then
  echo "Secret Manager already holds $SECRET in $PROJECT: the first sign-in may already be done." >&2
  echo "Sign in with that password; to start over, delete the secret yourself first." >&2
  exit 1
else
  STORED="$SECRET"
fi
PW="$(openssl rand -base64 33 | tr -d '\n/+=' | cut -c1-32)"
if [ -n "$PASSWORD_FILE" ]; then
  # noclobber: never write through a file or link created since the check.
  (umask 077; set -o noclobber; printf '%s\n' "$PW" > "$PASSWORD_FILE")
  echo "stored the password in $PASSWORD_FILE (mode 0600)"
else
  printf '%s' "$PW" | gcloud secrets create "$SECRET" --project "$PROJECT" \
    --replication-policy automatic --labels app=agent-relay --data-file=- >/dev/null
  echo "stored $SECRET in $PROJECT"
fi

# 3. Post the key and password. The Origin header is required: sign-in routes
#    refuse a request without the dashboard's origin (403 csrf_rejected).
BODY="$(mktemp)"; chmod 600 "$BODY"; trap 'rm -f "$BODY"' EXIT
CODE="$(PW="$PW" KEY="$(kubectl -n "$NAMESPACE" get secret agent-relay-secrets -o jsonpath='{.data.selfhost-setup-key}' | base64 -d)" \
  jq -n '{setupKey:env.KEY,password:env.PW}' |
  curl -sS -o "$BODY" -w '%{http_code}' -X POST \
    -H 'Content-Type: application/json' -H "Origin: https://$DOMAIN" \
    --data-binary @- "https://$API_HOST/api/v1/auth/password/setup-key")" || CODE="${CODE:-000}"
unset PW
if [ "$CODE" = 200 ]; then
  echo "first admin set: sign in at https://$DOMAIN/login with the password in $STORED"
  exit 0
fi
# Error bodies carry a code and a message, never the key or the password.
# 000: curl could not reach the API (DNS, certificate, network); the key was not sent.
echo "setup-key sign-in failed: HTTP $CODE $(jq -c '{error,message}' "$BODY" 2>/dev/null || true)" >&2
echo "The stored password was not accepted (API: https://$API_HOST); delete $STORED before running again." >&2
exit 1
