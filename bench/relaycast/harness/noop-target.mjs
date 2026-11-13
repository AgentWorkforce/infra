#!/usr/bin/env node
// No-op Relaycast stand-in used to prove the load generator is not the limit:
// answers every route immediately (201 for sends, 200 otherwise) with the
// response shapes producer.mjs reads. Run it on the app node group and point
// a producer fixture at it (run-arm.sh loadgen-check).
import http from 'node:http';
let n = 0;
const created = (res, body) => { res.writeHead(201, { 'content-type': 'application/json' }); res.end(JSON.stringify({ ok: true, data: body })); };
http.createServer((req, res) => {
  req.resume();
  req.on('end', () => {
    n++;
    if (req.method === 'POST' && req.url === '/v1/dm') return created(res, { id: String(n), conversation_id: 'dm_noop', delivery: { status: 'queued' } });
    if (req.method === 'POST' && /^\/v1\/channels\/[^/]+\/messages$/.test(req.url)) return created(res, { id: String(n), deliveries: [], deliveries_truncated: false });
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end('{"ok":true,"data":{}}');
  });
}).listen(Number(process.env.PORT || 8787));
