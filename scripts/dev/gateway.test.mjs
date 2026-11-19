import assert from 'node:assert/strict';
import http from 'node:http';
import net from 'node:net';
import { once } from 'node:events';
import { test } from 'node:test';
import { createGateway, route } from './gateway.mjs';

test('routes marketing Google start to the real Control OIDC flow and preserves invite/next', () => {
  const result = route('/cloud/api/auth/google/start?next=%2Fcloud%2Fdevice%3Fuser_code%3DABCD&invite_token=abc');
  const url = new URL(result.redirect, 'http://localhost');
  assert.equal(url.pathname, '/login/oidc/start');
  assert.equal(url.searchParams.get('next'), '/cloud/device?user_code=ABCD');
  assert.equal(url.searchParams.get('invite'), 'abc');
  assert.equal(route('/login').target, 'next');
  assert.equal(route('/login/oidc/callback?code=x&state=y').target, 'control');
  assert.equal(route('/cloud/api/v1/auth/device/start').target, 'control');
  assert.equal(route('/cloud/dashboard/@vite/client').target, 'dashboard');
  assert.equal(route('/_next/webpack-hmr').target, 'next');
  assert.equal(route('/signup?invite_token=abc').redirect, '/login?invite_token=abc');
});

test('Desktop Google return uses the session cookie mount and preserves handoff parameters', () => {
  const handoff = new URLSearchParams({
    redirect_uri: 'http://127.0.0.1:51058/callback/test-state',
    state: 'test-state', client: 'desktop', workspace_selection: 'desktop',
    code_challenge: 'test-challenge', code_challenge_method: 'S256',
    desktop_host_name: 'Local-Mac',
  });
  for (const path of ['/api/v1/cli/login', '/cloud/api/v1/cli/login']) {
    const input = new URLSearchParams({ next: `${path}?${handoff}`, invite_token: 'test-invite' });
    const result = route(`/cloud/api/auth/google/start?${input}`);
    const oidc = new URL(result.redirect, 'http://localhost:3100');
    const next = new URL(oidc.searchParams.get('next'), oidc.origin);
    assert.equal(next.pathname, '/cloud/api/v1/cli/login');
    assert.deepEqual([...next.searchParams], [...handoff]);
    assert.equal(oidc.searchParams.get('invite'), 'test-invite');
  }
  const dashboard = route('/cloud/api/auth/google/start');
  assert.equal(new URL(dashboard.redirect, 'http://localhost').searchParams.get('next'), '/cloud/dashboard/');
});

test('same-origin proxy preserves POST, query, cookies, redirects and multiple Set-Cookie headers', async t => {
  const upstream = http.createServer(async (req, res) => {
    let body = '';
    for await (const chunk of req) body += chunk;
    res.writeHead(303, { location: '/cloud/dashboard/', 'set-cookie': ['one=x; HttpOnly; Secure; Path=/cloud', 'two=y; HttpOnly; Path=/login/oidc'] });
    res.end(JSON.stringify({ method: req.method, url: req.url, body, host: req.headers.host, cookie: req.headers.cookie }));
  });
  upstream.listen(0, '127.0.0.1'); await once(upstream, 'listening');
  t.after(() => { upstream.closeAllConnections(); upstream.close(); });
  const p = upstream.address().port;
  const gateway = createGateway({ port: 3100, nextPort: p, dashboardPort: p, controlPort: p });
  gateway.listen(0, '127.0.0.1'); await once(gateway, 'listening');
  t.after(() => { gateway.closeAllConnections(); gateway.close(); });
  const request = (host = 'localhost:3100') => new Promise((resolve, reject) => {
    const req = http.request({ host: '127.0.0.1', port: gateway.address().port, method: 'POST', path: '/cloud/api/test?q=1', headers: { host, cookie: 'session=test', 'content-type': 'application/json' } }, res => {
      let body = ''; res.on('data', chunk => body += chunk); res.on('end', () => resolve({ res, body }));
    });
    req.on('error', reject); req.end('{"hello":"world"}');
  });
  const { res, body } = await request();
  assert.equal(res.statusCode, 303);
  assert.equal(res.headers['set-cookie'].length, 2);
  assert.match(res.headers['set-cookie'][0], /HttpOnly; Secure/);
  assert.equal(res.headers.location, '/cloud/dashboard/');
  assert.deepEqual(JSON.parse(body), { method: 'POST', url: '/cloud/api/test?q=1', body: '{"hello":"world"}', host: 'localhost:3100', cookie: 'session=test' });
  assert.equal((await request('attacker.invalid')).res.statusCode, 400);
});

test('websocket upgrade and buffered bytes reach the HMR backend', async t => {
  const upstream = http.createServer();
  const peers = new Set();
  upstream.on('connection', socket => { peers.add(socket); socket.on('close', () => peers.delete(socket)); });
  upstream.on('upgrade', (req, peer, head) => {
    assert.equal(req.url, '/_next/webpack-hmr');
    peer.write('HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n');
    if (head.length) peer.write(head);
    peer.on('data', data => peer.write(data));
  });
  upstream.listen(0, '127.0.0.1'); await once(upstream, 'listening');
  t.after(() => { for (const socket of peers) socket.destroy(); upstream.close(); });
  const p = upstream.address().port;
  const gateway = createGateway({ port: 3100, nextPort: p, dashboardPort: p, controlPort: p });
  gateway.listen(0, '127.0.0.1'); await once(gateway, 'listening');
  t.after(() => { gateway.closeDevConnections(); gateway.close(); });
  const req = http.request({ host: '127.0.0.1', port: gateway.address().port, path: '/_next/webpack-hmr', headers: { host: 'localhost:3100', connection: 'Upgrade', upgrade: 'websocket' } });
  req.end();
  const [, socket] = await once(req, 'upgrade');
  t.after(() => socket.destroy());
  socket.write('hmr-payload');
  const [data] = await once(socket, 'data');
  assert.equal(data.toString(), 'hmr-payload');
});

async function startGateway(t, p) {
  const gateway = createGateway({ port: 3100, nextPort: p, dashboardPort: p, controlPort: p });
  gateway.listen(0, '127.0.0.1'); await once(gateway, 'listening');
  t.after(() => { gateway.closeDevConnections(); gateway.close(); });
  return gateway;
}

function rawRequest(port, text) {
  return new Promise((resolve, reject) => {
    const socket = net.connect(port, '127.0.0.1', () => socket.write(text));
    let data = '';
    socket.on('data', chunk => { data += chunk; });
    socket.on('close', () => resolve(data));
    socket.on('error', reject);
  });
}

test('a target WHATWG URL cannot parse gets 400 and the gateway keeps serving', async t => {
  const upstream = http.createServer((req, res) => res.end('ok'));
  upstream.listen(0, '127.0.0.1'); await once(upstream, 'listening');
  t.after(() => { upstream.closeAllConnections(); upstream.close(); });
  const gateway = await startGateway(t, upstream.address().port);
  const port = gateway.address().port;
  const bad = await rawRequest(port, 'GET /\\ HTTP/1.1\r\nHost: localhost:3100\r\nConnection: close\r\n\r\n');
  assert.match(bad, /^HTTP\/1\.1 400/);
  const upgrade = await rawRequest(port, 'GET /\\ HTTP/1.1\r\nHost: localhost:3100\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n');
  assert.equal(upgrade, '');
  const good = await rawRequest(port, 'GET /x HTTP/1.1\r\nHost: localhost:3100\r\nConnection: close\r\n\r\n');
  assert.match(good, /^HTTP\/1\.1 200/);
});

test('an upstream body cut short ends the browser response instead of leaving it loading', async t => {
  const upstream = http.createServer((req, res) => {
    res.writeHead(200, { 'content-length': '100' });
    res.write('partial');
    setTimeout(() => res.socket.destroy(), 20);
  });
  upstream.listen(0, '127.0.0.1'); await once(upstream, 'listening');
  t.after(() => { upstream.closeAllConnections(); upstream.close(); });
  const gateway = await startGateway(t, upstream.address().port);
  const outcome = await new Promise(resolve => {
    const req = http.get({ host: '127.0.0.1', port: gateway.address().port, path: '/x', headers: { host: 'localhost:3100' } }, res => {
      res.on('data', () => {});
      res.on('end', () => resolve('end'));
      res.on('error', () => resolve('error'));
      res.on('aborted', () => resolve('aborted'));
    });
    req.on('error', () => resolve('error'));
  });
  assert.notEqual(outcome, 'end');
});

test('a client leaving during the HMR handshake releases the pending upstream request', async t => {
  let upstreamClosed;
  const closed = new Promise(resolve => { upstreamClosed = resolve; });
  const upstream = http.createServer();
  // Never answers the handshake; the gateway's request arrives as FIN (half-open) or close.
  upstream.on('upgrade', (req, peer) => { peer.on('end', upstreamClosed); peer.on('close', upstreamClosed); });
  upstream.listen(0, '127.0.0.1'); await once(upstream, 'listening');
  t.after(() => { upstream.closeAllConnections(); upstream.close(); });
  const gateway = await startGateway(t, upstream.address().port);
  const socket = net.connect(gateway.address().port, '127.0.0.1', () =>
    socket.write('GET /_next/webpack-hmr HTTP/1.1\r\nHost: localhost:3100\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n'));
  await once(upstream, 'upgrade');
  socket.destroy();
  await closed;
});
