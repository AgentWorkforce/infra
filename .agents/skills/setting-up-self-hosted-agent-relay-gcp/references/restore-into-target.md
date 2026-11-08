# Restore into a target


`--no-hooks` does not stop migrations: the RelayHistory, control-plane API and
Sessions Pipeline migration Jobs, and the Sessions Pipeline locker init Job, are plain Jobs, not
Helm hooks. Installing the chart over restored data would run them against
it. For a restore (isolated drill or recovery), first create a non-secret
restore overlay in the operator's configuration location, and pass it last:

Copy [`assets/restore-overlay.yaml`](../assets/restore-overlay.yaml) into the
operator's configuration location and export its path as
`RESTORE_OVERLAY_FILE`. It disables every migration, init and backup Job:

```yaml
# restore-overlay.yaml: no migration, init or backup Jobs during a restore.
relayhistory:
  migrations:
    enabled: false
relay-control:
  migrations:
    enabled: false
sessions-pipeline:
  worker:
    migrations:
      enabled: false
    lockerInit:
      enabled: false
relaycast:
  backup:
    enabled: false
# Relayflows in standalone mode is a Job; keep it off until the restore is
# verified, then re-enable it in a reviewed upgrade.
components:
  relayflows: false
```

```bash
helm install "$RELEASE" "$CHART" \
  --kube-context "$KUBE_CONTEXT" \
  --namespace "$NAMESPACE" --create-namespace --no-hooks \
  -f "$BASE_VALUES" \
  -f "$CUSTOMER_VALUES_FILE" \
  -f "$RESTORE_OVERLAY_FILE" \
  --wait --timeout 20m
```

Render first and confirm the output contains no `Job` objects. Re-enable
migrations only through a reviewed upgrade after the restored data and image
versions are proven compatible.
