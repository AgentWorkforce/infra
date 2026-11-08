/** Managed native contract. No SQL grants or credential discovery. Errors are closed codes. */
import { fileURLToPath } from 'node:url';
import { readFileSync, writeFileSync } from 'node:fs';
const CA_FILE = '/etc/native-consumer-postgres/ca.crt';
const ROLE = 'search_consumer_runtime';
const CA_SOURCE_FILE = '/var/run/native-consumer-ca-source/ca.crt';
const fail = () => { throw new Error('native_consumer_contract_invalid'); };
export function validateTarget(secret, env) {
  let object, url;
  try { object = JSON.parse(secret); url = new URL(object.hoopdb_url); } catch { fail(); }
  if (!object || typeof object.hoopdb_url !== 'string' || object.clickhouse !== undefined) fail();
  const expectedRole = env.NATIVE_CONSUMER_PREFLIGHT_MODE === 'bootstrap' ? env.NATIVE_CONSUMER_EXPECTED_ROLE : ROLE;
  let user, database;
  try { user = decodeURIComponent(url.username); database = decodeURIComponent(url.pathname.slice(1)); } catch { fail(); }
  const keys = [...url.searchParams.keys()];
  if (!['postgres:', 'postgresql:'].includes(url.protocol) || !url.password || url.hash || user !== expectedRole ||
      !database || database !== env.NATIVE_CONSUMER_EXPECTED_DATABASE || url.hostname !== env.NATIVE_CONSUMER_EXPECTED_HOST ||
      Number(url.port || 5432) !== Number(env.NATIVE_CONSUMER_EXPECTED_PORT) || keys.length !== 2 || new Set(keys).size !== 2 || url.searchParams.get('sslmode') !== 'verify-full' ||
      url.searchParams.get('sslrootcert') !== CA_FILE || env.SESSION_POSTGRES_CA_FILE !== CA_FILE) fail();
  return object.hoopdb_url;
}
/** Copies already-validated public CA bytes once. The running container mounts this volume read-only. */
export function freezePublicCa(pem, target = CA_FILE) {
  try { writeFileSync(target, pem, { flag: 'wx', mode: 0o444 }); }
  catch (error) { if (error?.code !== 'EEXIST') throw error; }
  // Init retries may reuse the volume, but may never replace a different CA.
  if (readFileSync(target, 'utf8') !== pem) fail();
}
export async function main(env = process.env) {
  // Static checks fail immediately; no URL/body/error message is ever printed.
  const url = validateTarget(env.RELAYHISTORY_PIPELINE_CONSUMER_SECRET, env);
  const timeout = Number(env.NATIVE_CONSUMER_PREFLIGHT_TIMEOUT_SECONDS);
  if (!Number.isInteger(timeout) || timeout < 30 || timeout > 1800) fail();
  const mode = env.NATIVE_CONSUMER_PREFLIGHT_MODE;
  if (mode !== 'runtime' && mode !== 'bootstrap') fail();
  const { postgresTlsOptions } = await import('/app/src/shared/postgres-tls.ts');
  if (env.NATIVE_CONSUMER_CA_SOURCE_FILE !== CA_SOURCE_FILE) fail();
  const sourceTls = postgresTlsOptions({ ...env, SESSION_POSTGRES_CA_FILE: CA_SOURCE_FILE });
  freezePublicCa(sourceTls.ca);
  // Both factories now use these frozen, pinned bytes. A later ConfigMap update
  // cannot change the generic URL pool's trust without a new init/rollout.
  const tls = postgresTlsOptions(env);
  const { consumerServiceConfig } = await import('/app/src/session-pipeline/consumer-config.ts');
  if (!consumerServiceConfig(env).enabled) fail();
  const { supabasePool } = await import('/app/src/session-pipeline/lambda.ts');
  const { openHoopDb, schemaVerdict, inTransaction } = await import('/app/src/shared/db.ts');
  const { expectedSchema } = await import('/app/src/hoopdb/migrate.ts');
  const { assertRuntimeIdentity, assertServiceSchema, assertSearchTenantGate } = await import('/app/src/session-pipeline/consumer-service.ts');
  const { bootstrapCheckOwner } = await import('/app/src/session-pipeline/consumer-bootstrap.ts');
  const stop = setTimeout(() => { console.error('{"code":"native_consumer_preflight_timeout"}'); process.exit(1); }, timeout * 1000);
  let waiting = false;
  try {
    for (;;) {
      const pinned = supabasePool(url, 1, tls);
      const worker = openHoopDb(url); // the production runWorker pool: URL TLS, not the helper
      for (const db of [pinned, worker]) Object.assign(db.pool.options, { max: 1, connectionTimeoutMillis: 3000, query_timeout: 5000 });
      try {
        for (const db of [pinned, worker]) {
          const { rows } = await db.query(`SELECT current_database() AS database, session_user AS login, current_user AS role,
            (SELECT ssl FROM pg_stat_ssl WHERE pid=pg_backend_pid()) AS tls`);
          const row = rows[0];
          const role = mode === 'runtime' ? ROLE : env.NATIVE_CONSUMER_EXPECTED_ROLE;
          if (!row || row.database !== env.NATIVE_CONSUMER_EXPECTED_DATABASE || row.login !== role || row.role !== role || row.tls !== true) fail();
        }
        if (mode === 'runtime') {
          await assertRuntimeIdentity(pinned);
          await assertServiceSchema(pinned);
          await assertSearchTenantGate(pinned);
          if (!(await schemaVerdict(await expectedSchema(), work => inTransaction(worker, work))).ok) throw new Error('not_ready');
        } else { try { await bootstrapCheckOwner(pinned); } catch { throw Object.assign(new Error('owner_contract'), { permanent: true }); } }
        console.log('{"check":"native-consumer-preflight","ok":true}');
        return;
      } catch (error) {
        if (error?.permanent) throw error;
        if (!waiting) console.log('{"check":"native-consumer-preflight","state":"waiting"}');
        waiting = true;
      } finally { await Promise.allSettled([pinned.end(), worker.end()]); }
      await new Promise(resolve => setTimeout(resolve, 2000));
    }
  } finally { clearTimeout(stop); }
}
if (process.argv[1] === fileURLToPath(import.meta.url)) main().catch(() => { console.error('{"code":"native_consumer_preflight_invalid"}'); process.exit(1); });
