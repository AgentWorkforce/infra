# shellcheck shell=bash
# Sourced: the caller defines the variables this file reads.
# shellcheck disable=SC2154
# Relaycast PostgreSQL -> durable-actors migration, sourced by
# agent-relay-upgrade.sh for --relaycast-actors credentials|cutover. Design:
# docs/relaycast-postgres-to-actors-migration.md. Uses the caller's verified
# release ($chart, $manifest), render command ($render, $base), kubectl/helm
# arrays ($kube, $helmx), $work, $state_dir, say/die and wait_jobs.
#
#   credentials  (online) switch the PostgreSQL release to ar_ credentials with
#                the keyring the actors will use, then re-key every Relaycast
#                credential relay-control holds (relaycast-rekey). Legacy
#                credentials keep working for the engine's grace period.
#   cutover      (messaging down) preflight, quiesce, export, helm upgrade onto
#                values-eks-actors.yaml, copy files, import, verify. Refuses
#                rather than drop anything.

rta_state() { printf '%s/relaycast-actors/%s-%s' "$state_dir" "$namespace" "$release"; }

# live_values JSON path -> value of the deployed release (computed values).
rta_live() { yq -r "$1 // \"\"" "$work/rta-live-values.yaml"; }
# the cutover's target render.
rta_target_values() { "${render[@]}" "${base[@]}" "${rta_actor_files[@]}"; }

rta_check() { # plan-time guards, shared by both phases
  [ "$profile" = eks-rds-native ] || die "--relaycast-actors needs --profile eks-rds-native (Relaycast on RDS)"
  ! $first_install || die "--relaycast-actors migrates an existing release; it cannot be combined with --first-install"
  "${helmx[@]}" get values "$release" -a -o yaml > "$work/rta-live-values.yaml" \
    || die "could not read the deployed values of $release"
  live_chart=$("${helmx[@]}" list --filter "^${release}\$" -o json | jq -r '.[0].chart // empty')
  [ "$live_chart" = "agent-relay-$chart_version" ] \
    || die "--relaycast-actors runs on the deployed chart version (deployed $live_chart, release $chart_version): upgrade first, then migrate"
  [ "$(rta_live .relaycast.runtime.backend)" = postgres ] \
    || die "Relaycast in $release is not on runtime.backend=postgres; nothing to migrate"
  rta_secret=$(rta_live .relaycast.existingSecret)
  [ -n "$rta_secret" ] || die "relaycast.existingSecret is not set in $release"
  rta_keyring_key=$(rta_live .relaycast.secretKeys.credentialKeyring); rta_keyring_key=${rta_keyring_key:-credential-keyring}
  "${kube[@]}" get secret "$rta_secret" -o json | jq -e --arg k "$rta_keyring_key" '.data[$k] // empty | length > 0' >/dev/null \
    || die "Secret $rta_secret has no $rta_keyring_key key: create the credential keyring (the same one the actors will use) first"
}

rta_check_cutover() {
  [ -f "$chart/values-eks-actors.yaml" ] || die "release $version does not ship values-eks-actors.yaml"
  [ "${#rta_actor_values[@]}" -gt 0 ] || die "cutover needs --actors-values <file>: your values-eks-actors.yaml overrides (bucket, publicUrl, zone, components set back on)"
  [ "$(rta_live .relaycast.credentials.format)" = ar ] \
    || die "Relaycast still issues legacy credentials: run --relaycast-actors credentials first"
  [ -s "$(rta_state).ar-since" ] || die "no record of the credentials phase under $state_dir (run --relaycast-actors credentials with this STATE_DIR)"
  rta_actor_files=(-f "$chart/values-eks-actors.yaml")
  for v in "${rta_actor_values[@]}"; do [ -f "$v" ] || die "actors values file not found: $v"; rta_actor_files+=(-f "$v"); done
  rta_target_values > "$work/rta-target.yaml" || die "the actors values do not render"
  # Nothing running may disappear: values-eks-actors.yaml turns every other
  # component off unless the overrides turn it back on.
  "${kube[@]}" get deploy -l "$release_selector" -o json | jq -r '.items[].metadata.name' | sort -u > "$work/rta-live-deploys"
  yq -N -r 'select(.kind == "Deployment") | .metadata.name' "$work/rta-target.yaml" | sort -u > "$work/rta-target-deploys"
  missing=$(comm -23 "$work/rta-live-deploys" "$work/rta-target-deploys")
  [ -z "$missing" ] || die "the actors values would remove running components (set them back on in --actors-values):
$missing"
  gw=$(yq -N -r 'select(.kind == "Deployment" and .metadata.name == "relaycast") | .spec.template.spec.containers[0].name' "$work/rta-target.yaml")
  [ "$gw" = gateway ] || die "the actors values do not put Relaycast on durable-actors"
  [ "$(yq -N -r 'select(.kind == "Deployment" and .metadata.name == "relaycast") | .spec.template.spec.volumes[] | select(.name == "secrets") | .secret.secretName' "$work/rta-target.yaml")" = "$rta_secret" ] \
    || die "the actors gateway must read the same Secret ($rta_secret) as the PostgreSQL release: the routing tags come from its keyring"
  # The durable-actors control plane keeps its state in PostgreSQL (RDS here)
  # and must verify the server certificate: refuse a control plane without a
  # CA bundle (relaycast-actors-bench found the shipped chart has none).
  # Every durable-actors Deployment (control plane, pool manager) must mount it.
  without_ca=$(yq -N -r 'select(.kind == "Deployment" and (.metadata.name | test("-durable-actors(-pool-manager)?$"))) | select(([.spec.template.spec.volumes[]? | select(.name == "postgres-ca")] | length) == 0) | .metadata.name' "$work/rta-target.yaml")
  cp_count=$(yq -N -r 'select(.kind == "Deployment" and (.metadata.name | test("-durable-actors(-pool-manager)?$"))) | .metadata.name' "$work/rta-target.yaml" | grep -c . || true)
  [ "$cp_count" -gt 0 ] || die "the actors values render no durable-actors control plane"
  [ -z "$without_ca" ] || die "these durable-actors Deployments would reach RDS without a CA bundle (verify-full TLS is required; no postgres-ca volume):
$without_ca"
}

rta_render_step() { # step [extra helm args]: render one migration Job to $work/rta-<step>.yaml, echo its name
  local step=$1 files=(); shift
  case "$step" in files|import) files=("${rta_actor_files[@]}") ;; esac
  "${render[@]}" "${base[@]}" "${files[@]}" --show-only charts/relaycast/templates/migration-job.yaml \
    --set relaycast.migration.enabled=true --set relaycast.migration.step="$step" \
    --set relaycast.migration.runId="$rta_run" "$@" > "$work/rta-$step.yaml"
  yq -N -r 'select(.kind == "Job") | .metadata.name' "$work/rta-$step.yaml"
}

rta_run_step() { # step [extra helm args]: apply one migration Job and wait for it
  local step=$1 job; shift
  job=$(rta_render_step "$step" "$@")
  [ -n "$job" ] || { say "   no $step Job rendered"; return 1; }
  "${kube[@]}" delete job "$job" --ignore-not-found >/dev/null
  "${kube[@]}" apply -f "$work/rta-$step.yaml" >/dev/null
  say "   $step: Job $job"
  wait_jobs "$job"
  "${kube[@]}" logs "job/$job" --tail=-1 > "$work/rta-$step.log" 2>&1 || true
  sed 's/^/     /' "$work/rta-$step.log" | tail -40
}

rta_preflight() { # refuses unless every workspace can move whole
  local since; since=$(cat "$(rta_state).ar-since")
  rta_run_step preflight --set relaycast.migration.arSince="$since" \
    || die "preflight failed: missing file objects, an unmigrated database or a workspace that cannot move (see the logs above)"
  legacy=$(grep '^{' "$work/rta-preflight.log" | jq -s '[.[].legacy_principals // {} | to_entries[].value] | add // 0')
  if [ "$legacy" -gt 0 ] && ! $rta_reregister_legacy; then
    die "$legacy principals still hold legacy credentials (created before the credentials phase, never upgraded).
   Wait for their holders to upgrade (SDKs do on use), or pass --reregister-legacy to accept that they re-register after the cutover (their data still moves)."
  fi
}

rta_credentials() {
  say "== R1. Switch $release's Relaycast to ar_ credentials (legacy ones keep working during the grace period)"
  mkdir -p "$(dirname "$(rta_state)")"; chmod 700 "$(dirname "$(rta_state)")"
  date -u +%s > "$(rta_state).ar-since"
  cat > "$work/rta-credentials.yaml" <<EOF
relaycast:
  credentials:
    format: ar
    authority: self
  secretKeys:
    credentialKeyring: $rta_keyring_key
EOF
  "${helmx[@]}" upgrade "$release" "$chart" "${base[@]}" -f "$work/rta-credentials.yaml" --wait --wait-for-jobs --timeout 15m
  "${kube[@]}" rollout status deployment/relaycast --timeout 10m
  say "== R2. Re-key the Relaycast credentials relay-control holds (relaycast-rekey)"
  "${kube[@]}" exec deployment/relay-control -- node /app/node_modules/relay-control/dist/relaycast-rekey-cli.js \
    | sed 's/^/     /'
  say ""
  say "Credentials phase done. Keep your values in step: add to them"
  sed 's/^/   /' "$work/rta-credentials.yaml"
  say "Then run --relaycast-actors cutover (plan mode first). Its preflight reports principals still on legacy credentials."
}

rta_cutover() {
  say "== R1. Preflight (read-only)"
  rta_preflight
  say "== R2. Quiesce: relay-control and Relaycast to 0 replicas (messaging is down from here)"
  "${kube[@]}" scale deployment/relay-control deployment/relaycast --replicas=0 >/dev/null
  "${kube[@]}" wait --for=delete pod -l app.kubernetes.io/name=relaycast --timeout=5m 2>/dev/null || true
  say "== R3. Export from one snapshot"
  rta_run_step export
  say "== R4. helm upgrade $release onto durable-actors (same chart $chart_version)"
  "${helmx[@]}" upgrade "$release" "$chart" "${base[@]}" "${rta_actor_files[@]}" --wait --wait-for-jobs --timeout 20m
  say "== R5. Copy files, then import every workspace (each verified by count and digest)"
  rta_run_step files
  rta_run_step import
  say "== R6. Verify"
  "${kube[@]}" rollout status deployment/relaycast --timeout 10m
  "${kube[@]}" rollout status deployment/relay-control --timeout 10m
  grep -q 'verified' "$work/rta-import.log" || die "the import did not report verified workspaces"
  say "   every workspace imported and verified; Relaycast serves from durable-actors"
}

rta_rollback_hint() {
  say "   Relaycast migration ($rta_phase): PostgreSQL was never written after the export, so the old state is intact."
  say "   - before the helm upgrade: scale back up: kubectl -n $namespace scale deployment/relay-control deployment/relaycast --replicas=1"
  say "   - after it: helm rollback as above, then abort half-imported workspaces with"
  say "     relaycast-migrate abort --dir /data/migration/$rta_run --gateway <url> --workspace <id> (the import Job's image)"
  say "   - relay-control re-key: relaycast-rekey --undo <run id> in the relay-control pod"
}
