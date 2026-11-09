import pg from 'pg';
import { createHash, createHmac } from 'node:crypto';
import { checkServerIdentity } from 'node:tls';
import assert from 'node:assert/strict';

export async function refused(operation, codes) {
  let failure;
  try { await operation(); } catch (error) { failure = error; }
  assert.ok(failure && codes.includes(failure.code), 'Expected exact refusal class');
}
export async function prove(config) {
  assert.equal(process.platform, 'linux');
  assert.equal(process.arch, 'arm64');
  assert.match(process.version, /^v24\./);
  assert.match(config.marker, /^[a-f0-9]{64}$/);
  assert.equal(config.database, 'moduleproof');
  assert.ok(['seed', 'restore'].includes(config.phase));
  assert.equal(createHash('sha256').update(config.ca).digest('hex'), config.ca_sha256);
  const base = { host: config.host, port: 5432, database: config.database, connectionTimeoutMillis: 15000, statement_timeout: 15000 };
  const verified = { ca: config.ca, rejectUnauthorized: true };
  const connect = async (options) => {
    const client = new pg.Client({ ...base, ...options });
    try { await client.connect(); return client; } catch (error) { await client.end().catch(() => {}); throw error; }
  };
  const readerPassword = createHmac('sha256', config.password).update(config.marker).digest('hex');
  const reader = 'proof_reader';
  const master = { user: config.username, password: config.password };
  let admin, limited;
  try {
    admin = await connect({ ...master, ssl: verified });
    const status = (await admin.query("SELECT current_setting('server_version_num')::int AS version, (SELECT ssl FROM pg_stat_ssl WHERE pid=pg_backend_pid()) AS tls, (SELECT version FROM pg_stat_ssl WHERE pid=pg_backend_pid()) AS tls_version")).rows[0];
    assert.ok(status.version >= 170000 && status.version < 180000 && status.tls === true && ['TLSv1.2', 'TLSv1.3'].includes(status.tls_version));
    const logging = (await admin.query("SELECT current_setting('log_statement') AS statements, current_setting('log_min_error_statement') AS error_statements, current_setting('log_parameter_max_length_on_error') AS error_parameters")).rows[0];
    assert.deepEqual(logging, { statements: 'none', error_statements: 'panic', error_parameters: '0' });
    if (config.phase === 'seed') {
      // Fresh, exclusively owned disposable DB: never adopt an existing schema/role.
      assert.equal((await admin.query("SELECT 1 FROM pg_roles WHERE rolname=$1", [reader])).rowCount, 0);
      await admin.query('BEGIN');
      try {
        await admin.query('CREATE EXTENSION pg_trgm');
        await admin.query('CREATE EXTENSION vector');
        await admin.query('CREATE SCHEMA fixture');
        await admin.query('CREATE TABLE fixture.marker (value text PRIMARY KEY)');
        await admin.query('CREATE TABLE fixture.denied (value text)');
        await admin.query('INSERT INTO fixture.marker VALUES ($1)', [config.marker]);
        // Generated hex only; credentials are never emitted in receipts or errors.
        await admin.query(`CREATE ROLE ${reader} LOGIN PASSWORD '${readerPassword}' NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION`);
        await admin.query('REVOKE ALL ON DATABASE moduleproof FROM PUBLIC');
        await admin.query('REVOKE CREATE ON SCHEMA public FROM PUBLIC');
        await admin.query(`GRANT CONNECT ON DATABASE moduleproof TO ${reader}`);
        await admin.query(`GRANT USAGE ON SCHEMA fixture, public TO ${reader}`);
        await admin.query(`GRANT SELECT ON fixture.marker TO ${reader}`);
        await admin.query('COMMIT');
      } catch (error) { await admin.query('ROLLBACK'); throw error; }
    }
    const extensions = (await admin.query("SELECT extname, extversion FROM pg_extension WHERE extname IN ('vector','pg_trgm') ORDER BY extname")).rows;
    assert.deepEqual(extensions.map(row => row.extname), ['pg_trgm', 'vector']);
    // A broken force_ssl setting must never cause a real password to cross a
    // plaintext connection. Invalid synthetic credentials still distinguish
    // no-encryption HBA refusal (28000) from password refusal (28P01).
    await refused(async () => { const c = await connect({ user: 'plaintext_refusal_probe', password: 'synthetic-only', ssl: false }); await c.end(); }, ['28000']);
    await refused(async () => { const c = await connect({ ...master, ssl: { ca: config.wrong_ca, rejectUnauthorized: true } }); await c.end(); }, ['SELF_SIGNED_CERT_IN_CHAIN', 'UNABLE_TO_VERIFY_LEAF_SIGNATURE', 'UNABLE_TO_GET_ISSUER_CERT_LOCALLY']);
    await refused(async () => { const c = await connect({ ...master, ssl: { ...verified, checkServerIdentity: (_host, cert) => checkServerIdentity('wrong.invalid', cert) } }); await c.end(); }, ['ERR_TLS_CERT_ALTNAME_INVALID']);
    limited = await connect({ user: reader, password: readerPassword, ssl: verified });
    assert.deepEqual((await limited.query('SELECT value FROM fixture.marker')).rows, [{ value: config.marker }]);
    const identity = (await limited.query('SELECT current_user AS name, rolsuper, rolcreatedb, rolcreaterole, rolreplication FROM pg_roles WHERE rolname=current_user')).rows[0];
    assert.equal(identity.name, reader);
    for (const key of ['rolsuper', 'rolcreatedb', 'rolcreaterole', 'rolreplication']) assert.equal(identity[key], false);
    const acl = (await limited.query("SELECT has_table_privilege(current_user,'fixture.marker','SELECT') AS can_read, has_table_privilege(current_user,'fixture.marker','INSERT,UPDATE,DELETE') AS can_write, has_schema_privilege(current_user,'public','CREATE') AS can_create, pg_has_role(current_user,'rds_superuser','MEMBER') AS privileged_member")).rows[0];
    assert.deepEqual(acl, { can_read: true, can_write: false, can_create: false, privileged_member: false });
    assert.deepEqual((await limited.query("SELECT similarity('abc','abc') AS trigram, '[1,2]'::vector <-> '[1,2]'::vector AS distance")).rows, [{ trigram: 1, distance: 0 }]);
    for (const sql of ['INSERT INTO fixture.marker VALUES (\'refused\')', 'SELECT * FROM fixture.denied', 'CREATE TABLE public.refused(value int)', 'CREATE ROLE refused']) {
      await limited.query('BEGIN');
      try { await refused(() => limited.query(sql), ['42501']); } finally { await limited.query('ROLLBACK'); }
    }
    await refused(async () => { const c = await connect({ user: reader, password: 'deliberately-wrong', ssl: verified }); await c.end(); }, ['28P01']);
    return { ok: true, phase: config.phase, marker: config.marker, postgres_version_num: status.version, tls: true, tls_version: status.tls_version, extensions, least_privilege: true, platform: process.platform, arch: process.arch, node: process.version, scope: 'synthetic module/schema/ACL marker only; application bootstrap not proved' };
  } finally { await limited?.end().catch(() => {}); await admin?.end().catch(() => {}); }
}

if (process.argv[1]?.endsWith('db-proof.mjs')) {
  try {
    let input = ''; for await (const chunk of process.stdin) { input += chunk; assert.ok(input.length < 2 * 1024 * 1024); }
    console.log(JSON.stringify(await prove(JSON.parse(input))));
  } catch (error) {
    // Do not print messages, query objects or connection configuration.
    console.error(JSON.stringify({ ok: false, code: typeof error.code === 'string' ? error.code : 'PROOF_FAILED' }));
    process.exitCode = 1;
  }
}
