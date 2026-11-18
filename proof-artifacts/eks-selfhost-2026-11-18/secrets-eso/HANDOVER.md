# Handover A -> B: hand-written ExternalSecrets to the chart's `externalSecrets` block

Run 2026-11-18 on ar-proof-eks: release tag chart 0.7.54 (hand-written SecretStore `ar-proof-ssm` + 5 ExternalSecrets)
to main chart 0.7.57 with `externalSecrets.enabled`, `store.create: true` (chart store `agent-relay-external-secrets`).
Helm 3.22.1 (and Helm 4.3.1 for the Helm 4 row), ESO 2.15.0. The table rows other than the first two were
reproduced on a scratch ExternalSecret with the files in `scratch-repro/` (apply `stores.yaml` and `es-by-hand.yaml`,
then install `chart/`).

## What Helm does with an ExternalSecret that already exists

| Case | Result |
| --- | --- |
| Helm 3, no adoption metadata | Upgrade refused before anything changes: `exists and cannot be imported into the current release: invalid ownership metadata` (release stays at the old revision). |
| Helm 3, adoption label + 2 annotations | Upgrade succeeds, **but the live ExternalSecret is not changed**: it still points at the old store and has no chart labels, while `helm get manifest` shows the new store. Later unchanged upgrades do not fix it. |
| Helm 3, same, plus `--force` | Live object is replaced with the chart's (store repointed). Not used on the real release: `--force` applies to every resource in the release. |
| Helm 4 (server-side apply), adoption metadata | Install/upgrade fails loudly: `conflict with "kubectl-client-side-apply" ... .spec.secretStoreRef.name`. With `--force-conflicts` it succeeds and repoints the store. |
| Delete first with `--cascade=orphan`, then upgrade | Secret stays (same UID, owner reference removed). The chart's new ExternalSecret takes it over: with `creationPolicy: Owner` it becomes the owner again; with `Merge` it syncs and leaves the Secret unowned (the Secret then survives `helm uninstall`). No Helm adoption metadata needed. |
| Delete without `--cascade=orphan` (Owner policy) | ESO's owner reference makes Kubernetes delete the Secret. Do not do this on a running install. |

Why the Helm 3 case is silent: for custom resources Helm 3 sends the difference between the previous release manifest
and the new one. An adopted object was not in the previous release, so Helm compares the new manifest with itself and
sends nothing.

## Path 1 (used on the release): adopt in place, then apply the release's own manifests

1. For each of the 5 ExternalSecrets:
   ```
   kubectl -n agent-relay label externalsecret <n> app.kubernetes.io/managed-by=Helm --overwrite
   kubectl -n agent-relay annotate externalsecret <n> meta.helm.sh/release-name=agent-relay meta.helm.sh/release-namespace=agent-relay --overwrite
   ```
2. `helm upgrade agent-relay <chart> -n agent-relay -f ... -f values-externalsecrets.yaml` (try `--dry-run=server` first).
3. Bring the live objects in line with the release (Helm 3 left them unchanged):
   ```
   helm get manifest agent-relay -n agent-relay | yq 'select(.kind=="ExternalSecret")' > externalsecrets-from-release.yaml
   kubectl -n agent-relay diff -f externalsecrets-from-release.yaml     # expect only the store name and chart labels
   kubectl -n agent-relay apply -f externalsecrets-from-release.yaml
   kubectl -n agent-relay get externalsecret -o custom-columns=NAME:.metadata.name,STORE:.spec.secretStoreRef.name,READY:.status.conditions[0].reason
   ```
   All 5 must show the chart's store and `SecretSynced`.
4. Only then `kubectl -n agent-relay delete secretstore <old store>`; force one sync
   (`kubectl annotate externalsecret <n> force-sync=$(date +%s) --overwrite`) and check `SecretSynced` again.

Measured: Secret UIDs, owner references, key counts (14/1/2/1/1) and data hashes identical before and after; no pod
restarted except the search-indexer rollout that 0.7.57 itself causes; bootstrap Job re-ran (new name) and completed;
the 4 public endpoints answered 200/200/200/401 on every 2-second probe from 20:54:08Z to 21:01:06Z (198 probes).

## Path 2 (proven on a scratch ExternalSecret): delete first, keep the Secret

1. `kubectl -n agent-relay delete externalsecret <the 5 names> --cascade=orphan`
2. Check the 5 Secrets are still there (`kubectl get secret`), then `helm upgrade` with the `externalSecrets` block.
   No adoption metadata, no extra apply step. `creationPolicy: Owner` (default) works; `Merge` is not required.
3. Delete the old SecretStore once all 5 show `SecretSynced` against the chart's store.

Between steps 1 and 2 nothing refreshes the Secrets (they keep their values; pods are unaffected).

## Path 3 (not run): keep the existing store

Set `externalSecrets.store.create: false` and `secretStoreRef: {kind: SecretStore, name: <existing store>}`. The manifest
then equals the live objects apart from labels, so the Helm 3 no-change behaviour is harmless and no store is deleted.
