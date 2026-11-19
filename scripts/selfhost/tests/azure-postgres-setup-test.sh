#!/usr/bin/env bash
# Structural fail-closed tests for the documented Azure/CNPG setup helper.
# The Cloud SQL behavioral test exercises the same interrupted-pre state; this
# file pins the Azure ordering so ownership alone can never become its return
# condition again.
set -euo pipefail
# shellcheck disable=SC2016 # Match literal shell source, not expanded values.

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$(cd -- "$TEST_DIR/../../.." && pwd)/docs/azure-install/postgres-setup.sh"

fail() { printf 'not ok - azure-postgres-setup: %s\n' "$*" >&2; exit 1; }
pass() { printf 'ok - azure-postgres-setup: %s\n' "$*"; }
line_of() { grep -n -F "$1" "$SCRIPT" | head -1 | cut -d: -f1; }
last_line_of() { grep -n -F "$1" "$SCRIPT" | tail -1 | cut -d: -f1; }
before() {
  local a b
  a="$(line_of "$1")"; b="$(line_of "$2")"
  [[ -n "$a" && -n "$b" && "$a" -lt "$b" ]]
}

owner_branch="$(awk '
  /if \[\[ "\$db_owner" == "\$OWNER" \]\]; then/ { capture=1 }
  capture { print }
  capture && /^  fi$/ { exit }
' "$SCRIPT")"
grep -Fq 'existing_dedicated=true' <<<"$owner_branch" \
  || fail "a pre interrupted after ownership is not classified for continuation"
if grep -Eq '^[[:space:]]*return([[:space:]]|$)' <<<"$owner_branch"; then
  fail "the dedicated-owner rerun returns before finishing prerequisites"
fi
before 'existing_dedicated=true' 'for f in session_directory_search_worker session_token_verifier session_ingest_roles session_read_api_roles legacy_export_privacy_roles' \
  || fail "phase-1 roles do not run after interrupted ownership"
before 'if [[ "$existing_dedicated" == false ]]; then' 'sql_file hoopdb_runtime_role.sql' \
  || fail "runtime-role convergence is not after the conditional owner transaction"
before 'sql_file hoopdb_runtime_role.sql' 'sql_file hoopdb_function_default_revoke.sql' \
  || fail "function-default convergence is not after runtime-role convergence"
before 'sql_file hoopdb_function_default_revoke.sql' 'protected role membership edges:' \
  || fail "membership verification is not after all dedicated prerequisites"
membership_line="$(line_of 'protected role membership edges:')"
credentials_line="$(last_line_of 'write_credential_files')"
[[ -n "$membership_line" && -n "$credentials_line" && "$membership_line" -lt "$credentials_line" ]] \
  || fail "credentials can be written before membership verification"
pass "dedicated-owner rerun resumes after an interrupted owner transaction"

secret_create_line="$(last_line_of 'create secret generic "$ADMIN_JOBS_SECRET"')"
secret_cleanup_line="$(last_line_of 'remove_legacy_secret_keys')"
[[ -n "$secret_create_line" && -n "$secret_cleanup_line" && "$secret_create_line" -lt "$secret_cleanup_line" ]] \
  || fail "legacy live keys can be removed before the temporary Secret exists"
grep -Fq 'patch secret "$secret" --type=merge' "$SCRIPT" \
  || fail "legacy prepare does not remove live administrator keys"
pass "legacy prepare creates the temporary Secret before removing live keys"

finalize_guard="$(line_of '[[ -s "$LAYOUT_FILE" ]] || die "missing HoopDb layout marker: run')"
finalize_read="$(line_of 'layout="$(<"$LAYOUT_FILE")"')"
[[ -n "$finalize_guard" && -n "$finalize_read" && "$finalize_guard" -lt "$finalize_read" ]] \
  || fail "finalize reads a missing layout file"
pass "finalize fails clearly without pre state"
