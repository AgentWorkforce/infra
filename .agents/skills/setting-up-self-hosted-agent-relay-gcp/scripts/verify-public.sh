#!/usr/bin/env bash
set -euo pipefail

required_commands=(curl openssl python3 timeout)

die() {
  printf 'verify-public: %s\n' "$*" >&2
  exit 1
}

for command_name in "${required_commands[@]}"; do
  command -v "$command_name" >/dev/null 2>&1 ||
    die "$command_name is required"
done

base_domain=${BASE_DOMAIN:-}
dashboard_url=${DASHBOARD_URL:-}
control_plane_url=${CONTROL_PLANE_URL:-${API_URL:-}}
relaycast_url=${RELAYCAST_URL:-}
relayhistory_url=${RELAYHISTORY_URL:-}

if test -n "${CONTROL_PLANE_URL:-}" &&
  test -n "${API_URL:-}" &&
  test "$CONTROL_PLANE_URL" != "$API_URL"; then
  die "CONTROL_PLANE_URL and API_URL disagree"
fi

if test -z "$base_domain" &&
  { test -z "$dashboard_url" ||
    test -z "$control_plane_url" ||
    test -z "$relaycast_url" ||
    test -z "$relayhistory_url"; }; then
  die "set BASE_DOMAIN or all four public URL variables"
fi

dashboard_url=${dashboard_url:-"https://$base_domain"}
control_plane_url=${control_plane_url:-"https://api.$base_domain"}
relaycast_url=${relaycast_url:-"https://cast.$base_domain"}
relayhistory_url=${relayhistory_url:-"https://history.$base_domain"}

dashboard_health_path=${DASHBOARD_HEALTH_PATH:-/healthz}
control_plane_health_path=${CONTROL_PLANE_HEALTH_PATH:-/healthz}
relaycast_health_path=${RELAYCAST_HEALTH_PATH:-/health}
relayhistory_health_path=${RELAYHISTORY_HEALTH_PATH:-/healthz}

connect_timeout=${VERIFY_CONNECT_TIMEOUT:-10}
max_time=${VERIFY_MAX_TIME:-30}
dns_timeout=${VERIFY_DNS_TIMEOUT:-5}
# Lookups through the system resolver retry: a transient resolver failure on
# the machine running the check is not an install fault. Each attempt applies
# the same public-address check; the last failure still fails the run.
dns_attempts=${VERIFY_DNS_ATTEMPTS:-3}
dns_retry_delay=${VERIFY_DNS_RETRY_DELAY:-2}
tls_timeout=${VERIFY_TLS_TIMEOUT:-15}
dns_resolver=${VERIFY_DNS_RESOLVER:-}
ca_bundle=${VERIFY_CA_BUNDLE:-}

for setting in connect_timeout max_time dns_timeout tls_timeout dns_attempts dns_retry_delay; do
  value=${!setting}
  case "$value" in
    ''|*[!0-9]*) die "$setting must be a positive integer" ;;
    0) die "$setting must be greater than zero" ;;
  esac
done

if test -n "$ca_bundle" && test ! -r "$ca_bundle"; then
  die "VERIFY_CA_BUNDLE is not readable"
fi

parse_origin() {
  python3 -c '
import re
import sys
from urllib.parse import urlsplit

try:
    raw = sys.argv[1]
    # urlsplit drops an empty query or fragment, so a bare trailing "?" or "#"
    # would otherwise pass and turn origin+path into origin?/healthz.
    if any(c in raw for c in "?#\\") or any(c.isspace() for c in raw):
        raise ValueError
    parsed = urlsplit(raw)
    host = parsed.hostname
    port = parsed.port or 443
    if (
        parsed.scheme != "https"
        or not host
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
        or parsed.path not in ("", "/")
        or port < 1
        or port > 65535
    ):
        raise ValueError
    host = host.encode("idna").decode("ascii").lower()
    labels = host.split(".")
    if (
        len(host) > 253
        or len(labels) < 2
        or any(
            not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", label)
            for label in labels
        )
    ):
        raise ValueError
except (UnicodeError, ValueError):
    sys.exit(1)

print(f"{host}\t{port}")
' "$1"
}

validate_health_path() {
  local label=$1
  local path=$2

  case "$path" in
    /*) ;;
    *) die "$label health path must start with /" ;;
  esac
  case "$path" in
    *'?'*|*'#'*|*$'\r'*|*$'\n'*)
      die "$label health path must not contain a query, fragment, or newline"
      ;;
  esac
}

resolve_dns() {
  local label=$1
  local host=$2
  local records
  local addresses
  local resolver_args=()

  if test -n "$dns_resolver"; then
    command -v dig >/dev/null 2>&1 ||
      die "dig is required when VERIFY_DNS_RESOLVER is set"
    resolver_args=("@$dns_resolver")

    if ! records=$(
      dig "${resolver_args[@]}" "+time=$dns_timeout" +tries=1 +short "$host" A
      dig "${resolver_args[@]}" "+time=$dns_timeout" +tries=1 +short "$host" AAAA
    ); then
      die "$label DNS lookup failed for $host"
    fi

    if ! addresses=$(
      printf '%s\n' "$records" |
        python3 -c '
import ipaddress
import sys

addresses = []
for line in sys.stdin:
    value = line.strip()
    try:
        address = ipaddress.ip_address(value)
    except ValueError:
        continue
    if not address.is_global:
        print(f"non-public DNS address: {address}", file=sys.stderr)
        sys.exit(1)
    rendered = str(address)
    if rendered not in addresses:
        addresses.append(rendered)

if not addresses:
    print("no public A or AAAA records", file=sys.stderr)
    sys.exit(1)

print(",".join(addresses))
'
    ); then
      die "$label DNS is not public for $host"
    fi
  else
    local attempt=1
    while ! addresses=$(
      timeout "$dns_timeout" python3 -c '
import ipaddress
import socket
import sys

try:
    results = socket.getaddrinfo(sys.argv[1], 443, type=socket.SOCK_STREAM)
except socket.gaierror:
    sys.exit(1)

addresses = []
for result in results:
    address = ipaddress.ip_address(result[4][0])
    if not address.is_global:
        print(f"non-public DNS address: {address}", file=sys.stderr)
        sys.exit(1)
    rendered = str(address)
    if rendered not in addresses:
        addresses.append(rendered)

if not addresses:
    sys.exit(1)

print(",".join(addresses))
' "$host"
    ); do
      if test "$attempt" -ge "$dns_attempts"; then
        die "$label DNS lookup failed or returned a non-public address for $host (after $dns_attempts attempts)"
      fi
      printf 'verify-public: %s: DNS lookup for %s failed (attempt %d/%d); retrying in %ss\n' \
        "$label" "$host" "$attempt" "$dns_attempts" "$dns_retry_delay" >&2
      attempt=$((attempt + 1))
      sleep "$dns_retry_delay"
    done
  fi

  printf 'verify-public: %s: DNS %s -> %s\n' "$label" "$host" "$addresses"
}

verify_tls() {
  local label=$1
  local host=$2
  local port=$3
  local openssl_args=(
    s_client
    -connect "$host:$port"
    -servername "$host"
    -verify_hostname "$host"
    -verify_return_error
  )

  if test -n "$ca_bundle"; then
    openssl_args+=(-CAfile "$ca_bundle")
  fi

  if ! timeout "$tls_timeout" openssl "${openssl_args[@]}" \
    </dev/null >/dev/null 2>&1; then
    die "$label TLS verification failed for $host:$port"
  fi

  printf 'verify-public: %s: TLS OK for %s:%s\n' "$label" "$host" "$port"
}

verify_health() {
  local label=$1
  local origin=${2%/}
  local path=$3
  local health_url="${origin}${path}"
  local status
  local curl_args=(
    --silent
    --show-error
    --output /dev/null
    --write-out '%{http_code}'
    --proto '=https'
    --tlsv1.2
    --connect-timeout "$connect_timeout"
    --max-time "$max_time"
  )

  if test -n "$ca_bundle"; then
    curl_args+=(--cacert "$ca_bundle")
  fi

  if ! status=$(curl "${curl_args[@]}" "$health_url"); then
    die "$label health request failed"
  fi

  case "$status" in
    2??) ;;
    *) die "$label health returned HTTP $status" ;;
  esac

  printf 'verify-public: %s: health %s HTTP %s\n' \
    "$label" "$health_url" "$status"
}

verify_endpoint() {
  local label=$1
  local origin=$2
  local health_path=$3
  local parsed
  local host
  local port

  if ! parsed=$(parse_origin "$origin"); then
    die "$label URL must be an HTTPS origin without credentials, path, query, or fragment"
  fi
  IFS=$'\t' read -r host port <<<"$parsed"

  validate_health_path "$label" "$health_path"
  resolve_dns "$label" "$host"
  verify_tls "$label" "$host" "$port"
  verify_health "$label" "$origin" "$health_path"
}

verify_endpoint dashboard "$dashboard_url" "$dashboard_health_path"
verify_endpoint control-plane "$control_plane_url" "$control_plane_health_path"
verify_endpoint relaycast "$relaycast_url" "$relaycast_health_path"
verify_endpoint relayhistory "$relayhistory_url" "$relayhistory_health_path"

printf 'verify-public: OK\n'
