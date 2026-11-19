# Agent Relay 2026.11.18

## RDS upgrade action required

The shared `external-rds.yaml` and `aws-rds-native.yaml` profiles now default
to `rdsLayout: separate-database` for fresh installs that use the dedicated
`hoopdb_owner` login. An existing administrator-owned RDS install must run
`scripts/selfhost/rds-setup.sh pre` and pass the generated
`hoopdb-layout-values.yaml` on its first upgrade with these profiles. That
overlay selects `rdsLayout: master-owner`; omitting it makes the migrator fail
closed before applying a migration.

The upgrader handles this automatically with `--rds-setup`. It creates the
temporary `hoopdb-admin-jobs` Secret before Helm, retains the old long-lived
keys until Helm, Jobs, and Deployments succeed, then removes those keys and the
temporary Secret. Existing-install ownership transfer is a follow-up under
#480.

Cloud SQL and Azure legacy flows use the same rollback-safe ordering.
`prepare-admin-jobs` creates only the temporary copy. After Helm, every Job and
all Deployments succeed, run `remove-legacy-secret-keys`; on either success or
failure run `delete-admin-jobs`. A failed upgrade therefore leaves the previous
revision's long-lived keys intact while removing the temporary copy.
