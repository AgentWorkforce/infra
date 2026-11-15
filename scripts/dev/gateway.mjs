// Local-only front door. No auth implementation, token rewriting or cloud fallback.
import http from 'node:http';
import { pathToFileURL } from 'node:url';

export function route(raw) {
  const url = new URL(raw, 'http://localhost');
  if (url.pathname === '/cloud/api/auth/google/start') {
    const query = new URLSearchParams();
    let next = url.searchParams.get('next') || '/cloud/dashboard/';
    // Match Control's cloudPathForNext: its browser cookie has Path=/cloud.
    // Desktop supplies the unmounted /api/v1/cli/login return path.
    if (next === '/api/v1' || next.startsWith('/api/v1/') || next.startsWith('/api/v1?')) {
      next = `/cloud${next}`;
    }
    query.set('next', next);
    const invite = url.searchParams.get('invite_token');
    if (invite) query.set('invite', invite);
    return { redirect: `/login/oidc/start?${query}` };
  }
  if (url.pathname === '/cloud/api/auth/microsoft/start') return { unsupported: true };
  if (url.pathname === '/signup' || url.pathname === '/signup/') return { redirect: `/login${url.search}` };
  if (url.pathname === '/cloud' || url.pathname === '/cloud/') return { redirect: '/cloud/dashboard/' };
  if (url.pathname === '/runtime-config.js') return { runtime: true };
  if (url.pathname === '/cloud/api' || url.pathname.startsWith('/cloud/api/') ||
      url.pathname === '/api' || url.pathname.startsWith('/api/') ||
      url.pathname.startsWith('/login/') || url.pathname === '/healthz' || url.pathname === '/readyz') {
    return { target: 'control' };
  }
  if (url.pathname === '/operator-login') {
    if (!url.searchParams.has('next')) url.searchParams.set('next', '/cloud/dashboard/');
    return { target: 'control', path: `/login?${url.searchParams}` };
  }
  if (url.pathname.startsWith('/cloud/dashboard/') || url.pathname === '/cloud/dashboard') {
    return { target: 'dashboard' };
  }
  return { target: 'next' };
}

export function createGateway({ port, nextPort, dashboardPort, controlPort }) {
  const targets = { next: nextPort, dashboard: dashboardPort, control: controlPort };
  const authority = `localhost:${port}`;
  function permitted(req) {
    // Do not become a proxy for arbitrary hosts (including DNS rebinding).
    return req.headers.host === authority && req.url?.startsWith('/') && !req.url.startsWith('//');
  }
  function headers(req) {
    return { ...req.headers, host: authority, 'x-forwarded-host': authority,
      'x-forwarded-proto': 'http', 'x-forwarded-for': '127.0.0.1' };
  }
  const server = http.createServer((req, res) => {
    if (!permitted(req)) { res.writeHead(400).end('Use the printed localhost URL.'); return; }
    const selected = route(req.url);
    if (selected.redirect) { res.writeHead(302, { location: selected.redirect, 'cache-control': 'no-store' }).end(); return; }
    if (selected.unsupported) { res.writeHead(501).end('This local environment configures Google OIDC only.'); return; }
    if (selected.runtime) {
      res.writeHead(200, { 'content-type': 'application/javascript', 'cache-control': 'no-store' });
      res.end('window.__AGENT_RELAY_DASHBOARD_CONFIG__=' + JSON.stringify({
        appPath: '/cloud/dashboard', loginPath: '/login', sessionVisualizations: true,
        customerProfile: { desktop: { siteUrl: `http://${authority}`, urlScheme: 'agentrelay-dev' } },
      }) + ';');
      return;
    }
    const upstream = http.request({ hostname: '127.0.0.1', port: targets[selected.target],
      path: selected.path || req.url, method: req.method, headers: headers(req) }, incoming => {
      // Keep Set-Cookie separate and retain HttpOnly/Secure/SameSite/Path exactly.
      res.writeHead(incoming.statusCode, incoming.headers);
      incoming.pipe(res);
    });
    upstream.on('error', () => {
      if (!res.headersSent) res.writeHead(502, { 'content-type': 'text/plain' });
      res.end(`Local ${selected.target} is unavailable. Check the dev.sh log.`);
    });
    req.on('aborted', () => upstream.destroy());
    req.pipe(upstream);
  });
  server.on('upgrade', (req, socket, head) => {
    if (!permitted(req)) { socket.destroy(); return; }
    const selected = route(req.url);
    if (!selected.target) { socket.destroy(); return; }
    const upstream = http.request({ hostname: '127.0.0.1', port: targets[selected.target],
      path: req.url, headers: headers(req) });
    upstream.on('upgrade', (response, peer, peerHead) => {
      socket.write(`HTTP/1.1 ${response.statusCode} ${response.statusMessage}\r\n`);
      for (let i = 0; i < response.rawHeaders.length; i += 2) socket.write(`${response.rawHeaders[i]}: ${response.rawHeaders[i + 1]}\r\n`);
      socket.write('\r\n');
      if (peerHead.length) socket.write(peerHead);
      if (head.length) peer.write(head);
      peer.on('error', () => socket.destroy());
      socket.on('error', () => peer.destroy());
      socket.on('close', () => peer.destroy());
      peer.on('close', () => socket.destroy());
      peer.pipe(socket).pipe(peer);
    });
    upstream.on('response', () => { upstream.destroy(); socket.destroy(); });
    upstream.on('error', () => socket.destroy());
    upstream.end();
  });
  const sockets = new Set();
  server.on('connection', socket => {
    sockets.add(socket);
    socket.on('close', () => sockets.delete(socket));
  });
  // closeAllConnections excludes upgraded sockets; HMR must shut down too.
  server.closeDevConnections = () => { for (const socket of sockets) socket.destroy(); };
  return server;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const config = JSON.parse(process.env.RELAY_DEV_PORTS);
  for (const key of ['port', 'nextPort', 'dashboardPort', 'controlPort']) {
    if (!Number.isInteger(config[key]) || config[key] < 1024 || config[key] > 65535) throw new Error(`Invalid ${key}`);
  }
  const server = createGateway(config);
  server.listen(config.port, '127.0.0.1', () => console.log(`Local front door: http://localhost:${config.port}`));
  for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => { server.closeDevConnections(); server.close(() => process.exit(0)); });
}
