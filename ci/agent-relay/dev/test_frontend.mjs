import test from 'node:test';
import assert from 'node:assert/strict';
import { options, runtimePlugin, validateFinalServer } from './frontend.mjs';
import { allowed, validate } from './sync.mjs';

test('HMR stays on the approved HTTPS cookie origin and preserves strict filesystem access', () => {
  const c = options('https://dev.example.test:8443/');
  assert.deepEqual(c.server.allowedHosts, ['dev.example.test']);
  assert.equal(c.server.hmr.protocol, 'wss');
  assert.equal(c.server.hmr.clientPort, 8443);
  assert.equal(c.server.cors.origin, 'https://dev.example.test:8443');
  assert.deepEqual(c.server.proxy, {});
  assert.equal(c.server.fs.strict, true);
  assert.equal(c.configLoader, 'runner');
  assert.equal(c.cacheDir, '/tmp/kind-dev-vite');
});

test('insecure, credential-bearing and path-bearing origins refuse', () => {
  for (const x of ['http://dev.test', 'https://u:p@dev.test', 'https://dev.test/login', 'https://dev.test/?secret=x'])
    assert.throws(() => options(x));
});

test('final merged config refuses inherited proxies and widened filesystem access', () => {
  const config = options('https://dev.example.test/');
  validateFinalServer({ config });
  config.server.proxy['/login'] = { target: 'https://other.example.test' };
  assert.throws(() => validateFinalServer({ config }), /merged_proxy_refused/);
  config.server.proxy = {};
  config.server.fs.allow.push('/');
  assert.throws(() => validateFinalServer({ config }), /merged_filesystem_override_refused/);
});

test('same-origin middleware handles only health and the unchanged generated runtime config', async () => {
  let handler;
  const plugin = runtimePlugin(async path => { assert.equal(path, '/usr/share/nginx/html/runtime-config.js'); return Buffer.from('original-config'); });
  plugin.configureServer({ middlewares: { use: h => { handler = h; } } });
  let next = 0;
  await handler({ url: '/cloud/api/v1/account' }, {}, () => next++);
  await handler({ url: '/login' }, {}, () => next++);
  assert.equal(next, 2);
  const res = { headers: {}, setHeader(k,v) { this.headers[k] = v; }, end(v) { this.body = v; } };
  await handler({ url: '/runtime-config.js' }, res, () => assert.fail());
  assert.equal(res.body.toString(), 'original-config');
  assert.equal(res.headers['Cache-Control'], 'no-store');
});

test('source sync validates the whole batch before writing and refuses paths outside the app', () => {
  const valid = { files: { 'src/App.tsx': Buffer.from('valid').toString('base64'), 'public/icon.svg': '' }, removed: ['src/old.ts'] };
  assert.equal(validate(valid), valid);
  for (const path of ['../other', '/tmp/key', 'public/.env', 'src/../key', 'node_modules/pkg/a', 'public//a', '.git/config']) {
    assert.equal(allowed(path), false, path);
    assert.throws(() => validate({ files: { [path]: '' }, removed: [] }), path);
  }
});

test('sync rejects invalid encodings, conflicting removals and oversized inputs', () => {
  assert.throws(() => validate({ files: { 'src/a.ts': 'not-base64!' }, removed: [] }));
  assert.throws(() => validate({ files: { 'src/a.ts': '' }, removed: ['src/a.ts'] }));
  assert.throws(() => validate({ files: { 'src/a.ts': Buffer.alloc(25 * 1024 * 1024).toString('base64') }, removed: [] }));
  assert.throws(() => validate({ files: null, removed: [] }));
});
