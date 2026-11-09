# Preparatory source and IO checkpoint

> **Superseded for the guest flow.** This records validation of the earlier guest composition, which could not be recovered. The guest now runs `rds-activation/v1`; see README "F1 status".

This new example is in progress; it has no operational admission yet. The first
stage resolves source-import/password IO before building the Terraform/parent
transport. No AWS API, credentials, actual-RDS library SQL, protected SQL edits,
application deployment or provider/full-app proof occurred.

The clean Sessions source is pinned to
`292359f0c68b1e4615704fd51d303b7f6b4db445`. All 11 RDS and 23 portable owner
input files are byte-checked against the exact reviewed heads. A real `npm ci`
was attempted in the new source worktree and refused the absent npm lockfile;
a real Bun 1.4.2 frozen installation then succeeded. No invented npm lockfile or
cross-worktree node_modules link exists. Helm itself has no npm manifest; its
requested `npm ci` attempt likewise refused without creating one.

The preparer copies original TypeScript/relative SQL assets without bundling or
rewriting import.meta.url. Only `@rhc/lib/scrub.ts` from shared/log.ts is resolved
by a closed Node hook. Unknown aliases and that alias from a different parent
are refused. The exact pg 8.23.1 Bun-lock closure has 14 packages; all production
bytes are regular archive members. The outer manifest includes transitive source
files beyond the library's own 65-file manifest. The 34-owner-file check includes
metadata for the rejected emulation harness, but its bytes are NEVER packaged,
imported or run.

Native Darwin arm64 Node 24.22.2 and installed Linux arm64 Node 24.11.1 imported
the original guest successfully, reading all embedded source/SQL generation
assets (52 planned steps, generation
`7d64ae1f74670530fd6443fad7d6cc9ac11776055941821ef79f8501fb2d7879`).
Two fresh source preparations packed byte-identically: 214 regular members,
459263 bytes, SHA256
`8e43ca212e61b38f6941d90f5fb5d6592225687e980cf6aa0ac1d68992e481b5`.
This is a preparatory guest-source archive; final transport/CA bytes and committed
Helm provenance will be bound again before final freeze.

Exact inspected Linux arm64 images:

- Node `node@sha256:48abc13a19400ca3985071e287bd405a1d99306770eb81d61202fb6b65cf0b57`
  reports Node 24.11.1.
- PostgreSQL client/server
  `postgres@sha256:748a18a54d3842d43bc156f0840d78029b8d349e0feca98c12b9c4ce3404a6b3`
  reports psql 17.11 (Debian 17.11-1.pgdg13+2). A floating tag was used only for
  initial public discovery; execution uses the exact inspected digest.

The bounded local synthetic fixture passes eight checks: installed original-TS
import, detached psql17 -W/-f owner prompt over stdin, initial fresh TLS login,
psql client-side SCRAM password change, fresh OLD-password failure with exact
28P01 after rotation, rotated fresh TLS login, wrong-hostname refusal and
wrong-CA refusal. It does not invoke the RDS guest SQL or emulate RDS catalogs.
Node pg overwrites a supplied SSL servername with its actual DNS host, so the
meaningful negative uses a second Docker DNS alias to the same owned server;
its hostname mismatch is actually rejected. Production must use only the native
verified endpoint as host, not rely on an injected servername override.

The Docker context is selected per command. No host/VM mount, global context
change, existing service change or SSH/auth enrollment occurred. Public source
streams through bounded stdin because Docker cp into running tmpfs was refused.
Newly generated synthetic credentials remain only in RAM/pipes. The sensitive
subprocess helper caps input/output/time, emits only typed errors and reaps its
owned process group. Raw client/SM-like output never reaches generic command
logs. Local tests contain no actual credential loader.

Initial failed runs are retained as evidence: tmpfs copy refusal, read-only
Unix-socket path, private pg_hba setup and a too-weak hostname-negative injection
were repaired before the final passing run. The initial create/rm cleanup also
missed anonymous volumes declared by the PostgreSQL image. The fixture now
mounts tmpfs over the entire declared VOLUME set, refuses any volume mount and
uses rm --volumes. A separate stopped-container counterexample captures the
implicit mount and proves rm --volumes retires it. Four old volumes were removed
only after Docker mount events linked them to exact owned container IDs. Two
older volumes without retained events were preserved for the parent's whole
owned-VM retirement; no claim of their independent absence is made here. Final
passing run proves its own containers/network absent and no NEW volumes; the
parent owns VM/storage cleanup. Exact IDs/receipts remain in private T7 evidence,
not committed customer examples.

Final Terraform/transport, CA source, original-version restore continuity,
application runtime readiness and native whole-instance/secret retirement remain
subsequent source/live gates. Two independent source reviews precede any AWS run.
