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
missing_state_line="$(line_of 'dedicated-owner HoopDb exists but STATE_DIR lacked trusted saved passwords')"
first_control_write_line="$(line_of '# Control: its own database.')"
[[ -n "$missing_state_line" && -n "$first_control_write_line" && "$missing_state_line" -lt "$first_control_write_line" ]] \
  || fail "missing dedicated-owner credential state can reach an ALTER ROLE, CREATE or GRANT"
grep -Fq '! -s "$PENDING_ACTIVATION_FILE"' <<<"$owner_branch" \
  || fail "an interrupted fresh activation is mistaken for missing dedicated-owner state"
marked_missing_line="$(line_of 'an interrupted activation lacks saved passwords for:')"
password_loop_line="$(line_of 'for p in control_owner control_api_runtime "$OWNER"')"
pending_write_line="$(line_of 'printf '\''%s\n'\'' "${untrusted_passwords# }"')"
[[ -n "$marked_missing_line" && -n "$password_loop_line" && -n "$pending_write_line" \
   && "$password_loop_line" -lt "$marked_missing_line" && "$marked_missing_line" -lt "$pending_write_line" ]] \
  || fail "a marked Azure retry does not refuse an actually absent password before state or database writes"
grep -Fq 'no replacements were generated and the database and Secrets were left unchanged' "$SCRIPT" \
  || fail "a marked Azure refusal does not stop before generating replacement passwords"
pending_names_line="$(line_of 'printf '\''%s\n'\'' "${untrusted_passwords# }"')"
password_generation_line="$(last_line_of 'password_for "$p"')"
[[ -n "$pending_names_line" && -n "$password_generation_line" && "$pending_names_line" -lt "$password_generation_line" ]] \
  || fail "Azure can generate a password before recording its name as pending"
activation_mark_line="$(line_of 'cp "$activation_target" "$PENDING_ACTIVATION_FILE"')"
first_database_write_line="$(line_of '# Control: its own database.')"
owner_transaction_line="$(line_of "printf 'BEGIN;")"
[[ -n "$activation_mark_line" && -n "$first_database_write_line" && -n "$owner_transaction_line" \
   && "$activation_mark_line" -lt "$first_database_write_line" && "$activation_mark_line" -lt "$owner_transaction_line" ]] \
  || fail "the target-bound fresh-activation marker is not durable before database writes"
grep -Fq "printf 'context=%s\\nnamespace=%s\\ncluster=%s\\n'" "$SCRIPT" \
  || fail "Azure activation state is not bound to context, namespace and cluster"
grep -Fq 'cmp -s "$activation_target" "$PENDING_ACTIVATION_FILE"' "$SCRIPT" \
  || fail "Azure retry does not refuse activation state from another cluster"
legacy_condition="$(grep -F '[[ "$db_owner" == "$LEGACY_OWNER" && ! -s "$PENDING_ACTIVATION_FILE" ]]' "$SCRIPT")"
[[ -n "$legacy_condition" ]] || fail "Azure retry can classify a pending fresh activation as legacy"
owner_verify_line="$(last_line_of 'verify_saved_owner_credential')"
[[ -n "$owner_verify_line" && "$owner_verify_line" -lt "$first_database_write_line" ]] \
  || fail "Azure retry does not verify its saved owner credential before writes"
grep -Fq 'rm -f "$PENDING_PASSWORDS_FILE" "$PENDING_ACTIVATION_FILE"' "$SCRIPT" \
  || fail "successful setup does not clear both pending-state markers"
pass "dedicated-owner rerun resumes an interrupted fresh activation but refuses missing saved state"

grep -Fq "rolname in ('hoopdb_owner','sessions_pipeline_runtime','search_consumer_runtime','session_directory_search_worker')" "$SCRIPT" \
  || fail "Azure legacy classifier does not detect a partial HoopDb role graph"
grep -Fq "'      roleBootstrap: false'" "$SCRIPT" \
  || fail "Azure dedicated-owner overlay does not disable migrator role bootstrap explicitly"
pass "Azure refuses partial role graphs and explicitly disables migrator role bootstrap"

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

grep -Fq 'any(.metadata.ownerReferences[]?; .kind == "ExternalSecret")' "$SCRIPT" \
  || fail "Azure cleanup does not detect ExternalSecret ownership"
grep -Fq 'has("reconcile.external-secrets.io/managed")' "$SCRIPT" \
  || fail "Azure cleanup does not detect the ESO managed label"
grep -Fq 'remove the $key mapping from the Helm release values and ExternalSecret, delete the backing-store value' "$SCRIPT" \
  || fail "Azure cleanup does not name the ESO mapping and store actions"
key_check_line="$(line_of 'key_present="$(jq -r --arg key "$key"')"
external_check_line="$(line_of 'externally_managed="$(jq -r')"
[[ -n "$key_check_line" && -n "$external_check_line" && "$key_check_line" -lt "$external_check_line" ]] \
  || fail "Azure cleanup checks ESO ownership before seeing that the mapped key is already absent"
grep -Fq 'external_secret_mapping_active "$secret" "$key"' "$SCRIPT" \
  || fail "Azure cleanup does not check for an active mapping after the generated key disappears"
grep -Fq '((.spec.target.template.data // {}) | has($key))' "$SCRIPT" \
  || fail "Azure cleanup ignores explicit ExternalSecret template outputs"
grep -Fq '((.spec.target.template.templateFrom // []) | length > 0)' "$SCRIPT" \
  || fail "Azure cleanup accepts uninspectable ExternalSecret templateFrom outputs"
pass "Azure cleanup refuses managed keys and checks active mappings after key removal"

grep -Fq 'rm -f "$PENDING_PASSWORDS_FILE"' "$SCRIPT" \
  || fail "Azure leaves a rejected pending-password marker available to a later retry"
grep -Fq 'for p in $pending_candidates; do rm -f "$PW_DIR/$p"; done' "$SCRIPT" \
  || fail "Azure leaves a rejected pending candidate available to a later retry"
pass "Azure clears rejected pending state before a later retry"

finalize_guard="$(line_of '[[ -s "$LAYOUT_FILE" ]] || die "missing HoopDb layout marker: run')"
finalize_read="$(line_of 'layout="$(<"$LAYOUT_FILE")"')"
[[ -n "$finalize_guard" && -n "$finalize_read" && "$finalize_guard" -lt "$finalize_read" ]] \
  || fail "finalize reads a missing layout file"
pass "finalize fails clearly without pre state"
