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
missing_state_line="$(line_of 'dedicated-owner HoopDb exists but STATE_DIR lacked saved passwords')"
first_control_write_line="$(line_of '# Control: its own database.')"
[[ -n "$missing_state_line" && -n "$first_control_write_line" && "$missing_state_line" -lt "$first_control_write_line" ]] \
  || fail "missing dedicated-owner credential state can reach an ALTER ROLE, CREATE or GRANT"
grep -Fq '! -s "$PENDING_ACTIVATION_FILE"' <<<"$owner_branch" \
  || fail "an interrupted fresh activation is mistaken for missing dedicated-owner state"
activation_mark_line="$(line_of "printf 'fresh activation in progress")"
owner_transaction_line="$(line_of "printf 'BEGIN;")"
[[ -n "$activation_mark_line" && -n "$owner_transaction_line" && "$activation_mark_line" -lt "$owner_transaction_line" ]] \
  || fail "the fresh-activation marker is not durable before the owner transaction"
grep -Fq 'rm -f "$PENDING_PASSWORDS_FILE" "$PENDING_ACTIVATION_FILE"' "$SCRIPT" \
  || fail "successful setup does not clear both pending-state markers"
pass "dedicated-owner rerun resumes an interrupted fresh activation but refuses missing saved state"

prepare_body="$(awk '/^do_prepare-admin-jobs\(\)/{capture=1} capture{print} capture && /^}$/{exit}' "$SCRIPT")"
remove_body="$(awk '/^do_remove-legacy-secret-keys\(\)/{capture=1} capture{print} capture && /^}$/{exit}' "$SCRIPT")"
if grep -Fq 'remove_legacy_secret_keys' <<<"$prepare_body"; then
  fail "legacy prepare removes rollback credentials before Helm succeeds"
fi
# The single quotes intentionally preserve the shell source text under test.
# shellcheck disable=SC2016
grep -Fq 'get secret "$ADMIN_JOBS_SECRET" -o name' <<<"$remove_body" \
  || fail "post-success removal does not require the temporary Secret"
grep -Fq 'remove_legacy_secret_keys' <<<"$remove_body" \
  || fail "post-success removal does not remove the live administrator keys"
grep -Fq 'patch secret "$secret" --type=merge' "$SCRIPT" \
  || fail "legacy post-success cleanup does not patch live administrator keys"
pass "legacy keys remain through Helm and are removed only by post-success cleanup"

finalize_guard="$(line_of '[[ -s "$LAYOUT_FILE" ]] || die "missing HoopDb layout marker: run')"
finalize_read="$(line_of 'layout="$(<"$LAYOUT_FILE")"')"
[[ -n "$finalize_guard" && -n "$finalize_read" && "$finalize_guard" -lt "$finalize_read" ]] \
  || fail "finalize reads a missing layout file"
pass "finalize fails clearly without pre state"
