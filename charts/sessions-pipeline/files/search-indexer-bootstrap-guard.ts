const CATALOG_RACE = /(?:tuple concurrently updated|concurrent catalog update)/u;

/** PostgreSQL reports concurrent role/catalog DDL as XX000. Match both the
 * stable SQLSTATE and its catalog-update text; unrelated bootstrap failures
 * must reach the Job immediately instead of being retried. */
export function isRetryableCatalogRace(output: string): boolean {
  return /\bXX000\b/u.test(output) && CATALOG_RACE.test(output);
}

function positiveInteger(name: string, maximum: number): number {
  const raw = process.env[name] ?? "";
  if (!/^[1-9][0-9]*$/u.test(raw)) throw new Error(`${name} must be a positive integer`);
  const value = Number(raw);
  if (!Number.isSafeInteger(value) || value > maximum) throw new Error(`${name} is out of range`);
  return value;
}

function boolean(name: string): boolean {
  const raw = process.env[name];
  if (raw === "true") return true;
  if (raw === "false") return false;
  throw new Error(`${name} must be true or false`);
}

async function capture(stream: ReadableStream<Uint8Array>, target: typeof Bun.stdout): Promise<string> {
  const reader = stream.getReader();
  const decoder = new TextDecoder();
  let tail = "";
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    await Bun.write(target, value);
    tail = `${tail}${decoder.decode(value, { stream: true })}`.slice(-65_536);
  }
  return `${tail}${decoder.decode()}`.slice(-65_536);
}

async function runBootstrap(): Promise<{ code: number; output: string }> {
  const child = Bun.spawn(["/entrypoint.sh"], {
    env: process.env,
    stdin: "inherit",
    stdout: "pipe",
    stderr: "pipe",
  });
  const [code, stdout, stderr] = await Promise.all([
    child.exited,
    capture(child.stdout, Bun.stdout),
    capture(child.stderr, Bun.stderr),
  ]);
  return { code, output: `${stdout}\n${stderr}` };
}

type RoleProbe = { query: (sql: string) => Promise<{ rows: Array<{ ready: boolean }> }> };

export async function waitForRuntimeRoleActivation(
  client: RoleProbe,
  waitSeconds: number,
  pollSeconds: number,
  sleep: (milliseconds: number) => Promise<unknown> = Bun.sleep,
  now: () => number = Date.now,
): Promise<void> {
  const deadline = now() + waitSeconds * 1000;
  for (;;) {
    const result = await client.query(
      "SELECT COALESCE((SELECT rolcanlogin FROM pg_catalog.pg_roles WHERE rolname='search_consumer_runtime'), false) AS ready",
    );
    if (result.rows[0]?.ready) return;
    if (now() + pollSeconds * 1000 > deadline) {
      throw new Error("search-indexer bootstrap: search_consumer_runtime did not become LOGIN before the deadline");
    }
    await sleep(pollSeconds * 1000);
  }
}

async function main(): Promise<number> {
  const maxAttempts = positiveInteger("SEARCH_BOOTSTRAP_CATALOG_RETRY_MAX_ATTEMPTS", 10);
  const delaySeconds = positiveInteger("SEARCH_BOOTSTRAP_CATALOG_RETRY_DELAY_SECONDS", 60);
  const waitForRuntimeRole = boolean("SEARCH_BOOTSTRAP_WAIT_FOR_RUNTIME_ROLE_LOGIN");
  const roleWaitSeconds = positiveInteger("SEARCH_BOOTSTRAP_RUNTIME_ROLE_WAIT_SECONDS", 840);
  const rolePollSeconds = positiveInteger("SEARCH_BOOTSTRAP_RUNTIME_ROLE_POLL_SECONDS", 60);
  if (rolePollSeconds > roleWaitSeconds) throw new Error("runtime role poll interval exceeds its wait deadline");
  const rawSecret = process.env.RELAYHISTORY_PIPELINE_CONSUMER_SECRET ?? "";
  let ownerUrl: string;
  try {
    const secret = JSON.parse(rawSecret) as { hoopdb_url?: unknown };
    if (typeof secret.hoopdb_url !== "string" || !secret.hoopdb_url) throw new Error("missing URL");
    ownerUrl = secret.hoopdb_url;
  } catch {
    throw new Error("search-indexer bootstrap owner Secret is invalid");
  }

  const [{ default: pg }, tls] = await Promise.all([
    import("pg"),
    import("/app/src/shared/postgres-tls.ts"),
  ]);
  const lock = new pg.Client({
    connectionString: tls.postgresConnectionString(ownerUrl),
    ssl: tls.postgresTlsOptions(),
    application_name: "search-indexer-bootstrap-guard",
  });
  await lock.connect();
  if (waitForRuntimeRole) {
    console.error("search-indexer bootstrap: waiting for rds-setup post to activate search_consumer_runtime");
    await waitForRuntimeRoleActivation({
      query: async sql => {
        const result = await lock.query<{ ready: boolean }>(sql);
        return { rows: result.rows };
      },
    }, roleWaitSeconds, rolePollSeconds);
  }
  // The Sessions migrator already holds this session lock around every schema
  // step. Holding the same lock keeps its role/catalog DDL from overlapping the
  // search bootstrap transaction, without relying on Helm hooks.
  await lock.query("SELECT pg_advisory_lock(961996, 1)");
  try {
    for (let attempt = 1; attempt <= maxAttempts; attempt += 1) {
      const result = await runBootstrap();
      if (result.code === 0) return 0;
      if (!isRetryableCatalogRace(result.output) || attempt === maxAttempts) return result.code || 1;
      console.error(`search-indexer bootstrap: retrying PostgreSQL catalog race (attempt ${attempt + 1}/${maxAttempts})`);
      await Bun.sleep(delaySeconds * 1000);
    }
    return 1;
  } finally {
    await lock.query("SELECT pg_advisory_unlock(961996, 1)").catch(() => {});
    await lock.end().catch(() => {});
  }
}

if (import.meta.main) process.exitCode = await main();
