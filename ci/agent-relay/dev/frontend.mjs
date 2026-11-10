import { cp, mkdir, readdir, readFile, symlink } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';

export function validateFinalServer(server) {
  if (Object.keys(server.config.server.proxy ?? {}).length) throw new Error('merged_proxy_refused');
  if (server.config.server.fs.strict !== true || server.config.server.allowedHosts === true)
    throw new Error('merged_access_override_refused');
  for (const path of server.config.server.fs.allow)
    if (path !== '/devsrc' && !path.startsWith('/devsrc/') &&
        path !== '/seed/node_modules' && !path.startsWith('/seed/node_modules/'))
      throw new Error('merged_filesystem_override_refused');
}

export function options(publicUrl) {
  const url = new URL(publicUrl);
  if (url.protocol !== 'https:' || url.username || url.password || url.pathname !== '/' || url.search || url.hash)
    throw new Error('public_https_origin_required');
  return {
    root: '/devsrc',
    configFile: '/devsrc/vite.config.ts',
    // Reuse the actual app plugins/config; runner avoids writing .vite-temp
    // inside read-only /seed/node_modules. The cache stays in the existing /tmp.
    configLoader: 'runner',
    cacheDir: '/tmp/kind-dev-vite',
    server: {
      host: '0.0.0.0', port: 8080, strictPort: true,
      allowedHosts: [url.hostname],
      cors: { origin: url.origin },
      proxy: {}, // Existing ingress keeps /login and /cloud/api on Control.
      hmr: { protocol: 'wss', host: url.hostname, clientPort: Number(url.port || 443) },
      fs: { strict: true, allow: ['/devsrc', '/seed/node_modules'],
        deny: ['.env', '.env.*', '*.{crt,pem,key}', '**/.git/**', '**/.kind/**'] },
    },
  };
}

export function runtimePlugin(read = readFile) {
  return {
    name: 'kind-dev-existing-runtime-config',
    configureServer(server) {
      server.middlewares.use(async (req, res, next) => {
        const path = req.url?.split('?')[0];
        if (path === '/healthz') { res.end('ok\n'); return; }
        if (path !== '/runtime-config.js') { next(); return; }
        try {
          const bytes = await read('/usr/share/nginx/html/runtime-config.js');
          res.setHeader('Content-Type', 'application/javascript');
          res.setHeader('Cache-Control', 'no-store');
          res.end(bytes);
        } catch { res.statusCode = 503; res.end('runtime_config_unavailable'); }
      });
    },
  };
}

async function main() {
  const config = options(process.env.DASHBOARD_PUBLIC_URL);
  await mkdir('/devsrc', { recursive: true });
  // No copy of node_modules, no host mounts or new cluster storage.
  for (const name of await readdir('/seed')) {
    if (name === 'node_modules' || name === '__kind_dev') continue;
    await cp('/seed/' + name, '/devsrc/' + name, { recursive: true, force: true });
  }
  try { await symlink('/seed/node_modules', '/devsrc/node_modules'); }
  catch (error) { if (error.code !== 'EEXIST') throw error; }
  const generated = spawnSync('/bin/sh', ['/devsrc/docker/40-runtime-config.sh'], { stdio: 'ignore' });
  if (generated.status !== 0) throw new Error('official_runtime_config_refused');
  const { createServer } = await import('vite');
  const server = await createServer({ ...config, plugins: [runtimePlugin()] });
  // Vite merges nested config objects: {} is not a reliable way to erase an
  // upstream proxy. Refuse a final proxy rather than silently changing auth.
  try { validateFinalServer(server); }
  catch (error) {
    await server.close();
    throw error;
  }
  await server.listen();
  console.log('kind-dev frontend ready; existing HTTPS origin and cookie routes preserved');
  for (const sig of ['SIGTERM', 'SIGINT']) process.once(sig, async () => { await server.close(); process.exit(0); });
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href)
  main().catch(() => { console.error('kind-dev frontend startup refused'); process.exit(1); });
