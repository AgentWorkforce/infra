# Accept catalog-exact legacy creator edges after HoopDb ownership transfer

Target repository: `AgentWorkforce/relayhistory-pipeline`

Audited release commit: `b96e1e1e97185f212d86928dd1eff6b599000892`

## Problem

An existing managed-PostgreSQL install was bootstrapped with the provider
administrator as the HoopDb migration owner. On PostgreSQL 16 and 17, roles
created by a non-superuser `CREATEROLE` administrator retain an automatic
ADMIN-only creator edge. Transferring the database, schemas and objects to a
new unprivileged owner does not transfer or remove those shared-catalog edges.

The current guards correctly reject arbitrary membership, but they also reject
these catalog-exact legacy edges when the new owner runs an upgrade:

| Path | Exact statement/guard | Why transfer is refused |
|---|---|---|
| RDS migrator | `src/hoopdb/migrate-guards.ts:505-533`, `isRdsCreatorEdge` requires `cfg.rdsLayout !== "separate-database"` and requires the edge member to equal the connected migration owner | The transferred layout must select `HOOPDB_RDS_LAYOUT=separate-database`, while the surviving edge member is the former RDS master. Every edge is therefore rejected. |
| Search bootstrap | `supabase/bootstrap/session_consumer_role.sql:115-138` permits only a creator edge whose member is `current_user` | After transfer, `current_user` is the dedicated owner but the surviving member is the former provider administrator. |
| Search verification | `supabase/bootstrap/session_consumer_role_verify.sql:28-44` repeats the same `current_user` requirement | The bootstrap cannot converge after transfer even when the role and edge are otherwise exact. |

Dropping and recreating live runtime roles is not an acceptable migration: the
roles are shared cluster identities, carry passwords and settings, and may be
serving pods while the transfer runs.

## Smallest compatible change

Add an explicit, transfer-only legacy-edge policy selected independently from
the fresh `separate-database` layout. The policy must be fixed to each provider;
it must not take an arbitrary administrator role name from an environment
variable.

For RDS PostgreSQL 16+, accept an incoming runtime/search edge only when all of
these catalog facts hold:

- target is the fixed expected role;
- member is the recorded legacy database owner captured by the transfer
  preflight, is not the new owner, and is a non-superuser `CREATEROLE` member of
  `rds_superuser`;
- grantor is the fixed `rdsadmin` role and is still `SUPERUSER`;
- `admin_option=true`, `inherit_option=false`, `set_option=false`;
- target is a member of no role and no second incoming edge exists;
- the dedicated owner remains `NOSUPERUSER NOCREATEROLE NOCREATEDB
  NOREPLICATION NOBYPASSRLS`, owns the current database and required schemas,
  and has no membership in the provider administrator roles.

Apply the same policy through one shared SQL predicate/helper in
`session_consumer_role.sql` and `session_consumer_role_verify.sql`, so bootstrap
and verification cannot drift. Cloud SQL should have a separate fixed shape
(`cloudsqlsuperuser` membership and the fixed platform grantor observed by its
managed-service proof); do not infer it from the RDS rule.

The default remains strict: without the explicit transfer policy, the current
fresh `separate-database` path continues to require an empty edge set.

## PostgreSQL 16 and 17 tests

Run the same integration matrix on both major versions:

1. Create a provider-shaped non-superuser administrator and platform grantor,
   then create runtime and search roles as that administrator so PostgreSQL
   records the automatic creator edges.
2. Migrate once as the administrator and assert the legacy layout still passes.
3. Transfer database, schemas, tables, sequences, functions, types, default
   privileges and the migrations ledger to a dedicated owner without dropping
   either runtime role.
4. With the transfer policy selected, run a second migrate, search bootstrap
   and search verification as the dedicated owner; all must pass.
5. Prove the runtime and search logins still read/write through their existing
   grants and passwords.
6. Negative cases must reject: wrong member, wrong grantor, non-superuser
   grantor, ADMIN false, INHERIT or SET true, a second edge, a reverse edge,
   target membership, new-owner membership in the provider group, or the same
   legacy edge when the transfer policy is absent.
7. Prove a fresh activation still finishes with zero creator edges and needs no
   compatibility policy.

The managed Cloud SQL and RDS grantor shapes must additionally be exercised on
their real services before enabling their transfer modes; local superuser
emulation proves PostgreSQL semantics but not provider-maintained catalog
roles.

## Contract question

Will a later activation contract accept the migration-owner and database names
as explicit inputs, so an infra-owned install can use `hoopdb_owner` and its
selected database name without claiming the fixed-name `rds-activation/v1`
contract? If so, do the pipeline owners intend to preserve the current
name-agnostic migrator preflight (`current_user` / `current_database()`) for
those later contracts?
