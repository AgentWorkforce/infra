// Shared helpers for the Relaycast benchmark harness. Zero dependencies:
// Node >= 22 (global fetch and WebSocket).
import { readFileSync, writeFileSync, renameSync } from 'node:fs';
import { gunzipSync } from 'node:zlib';

export const env = (name, def) => {
  const v = process.env[name];
  if (v === undefined || v === '') {
    if (def === undefined) throw new Error(`missing env ${name}`);
    return def;
  }
  return v;
};
export const envInt = (name, def) => Number.parseInt(env(name, def === undefined ? undefined : String(def)), 10);
export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
export const now = () => Date.now();
export const hr = () => Number(process.hrtime.bigint() / 1000n) / 1000; // ms, monotonic

export function readSecretFile(path) {
  return readFileSync(path, 'utf8').trim();
}

// Fixtures may be gzipped (fixture.json.gz) to stay under the 1 MiB Secret limit.
export function readFixture(path) {
  const raw = readFileSync(path);
  return JSON.parse((path.endsWith('.gz') ? gunzipSync(raw) : raw).toString('utf8'));
}

export function writeJsonAtomic(path, value) {
  const tmp = `${path}.tmp`;
  writeFileSync(tmp, JSON.stringify(value), { mode: 0o600 });
  renameSync(tmp, path);
}

// Log-linear histogram: 1% relative precision from 0.01 ms to ~1 h. Mergeable
// (bucket counts add), so per-pod histograms combine into fleet percentiles.
const SUB = 100; // buckets per power of two
export class Hist {
  constructor() { this.b = new Map(); this.n = 0; this.sum = 0; this.min = Infinity; this.max = 0; }
  add(ms) {
    if (!(ms >= 0)) return;
    const v = Math.max(ms, 0.01);
    const k = Math.floor(Math.log2(v / 0.01) * SUB);
    this.b.set(k, (this.b.get(k) || 0) + 1);
    this.n++; this.sum += ms; if (ms < this.min) this.min = ms; if (ms > this.max) this.max = ms;
  }
  merge(o) {
    const src = o instanceof Hist ? o : Hist.from(o);
    for (const [k, c] of src.b) this.b.set(k, (this.b.get(k) || 0) + c);
    this.n += src.n; this.sum += src.sum; this.min = Math.min(this.min, src.min); this.max = Math.max(this.max, src.max);
    return this;
  }
  q(p) {
    if (!this.n) return null;
    const target = Math.ceil(p * this.n);
    let acc = 0;
    for (const k of [...this.b.keys()].sort((a, b) => a - b)) {
      acc += this.b.get(k);
      if (acc >= target) return +(0.01 * 2 ** ((k + 0.5) / SUB)).toFixed(3);
    }
    return this.max;
  }
  summary() {
    return { n: this.n, mean: this.n ? +(this.sum / this.n).toFixed(3) : null, min: this.n ? this.min : null,
      p50: this.q(0.5), p95: this.q(0.95), p99: this.q(0.99), p999: this.q(0.999), max: this.n ? this.max : null };
  }
  toJSON() { return { b: [...this.b], n: this.n, sum: this.sum, min: this.min === Infinity ? null : this.min, max: this.max }; }
  static from(j) {
    const h = new Hist();
    h.b = new Map(j.b); h.n = j.n; h.sum = j.sum; h.min = j.min ?? Infinity; h.max = j.max;
    return h;
  }
}

export class HistMap {
  constructor() { this.m = new Map(); }
  get(k) { let h = this.m.get(k); if (!h) this.m.set(k, (h = new Hist())); return h; }
  add(k, v) { this.get(k).add(v); }
  toJSON() { return Object.fromEntries([...this.m].map(([k, h]) => [k, h.toJSON()])); }
}

export class Counter {
  constructor() { this.m = new Map(); }
  inc(k, n = 1) { this.m.set(k, (this.m.get(k) || 0) + n); }
  toJSON() { return Object.fromEntries(this.m); }
}

// Message marker carried in the text of every benchmark message:
//   rcb1 <phase> <producer> <stream> <seq> <sent_epoch_ms> [padding]
// Fields never contain spaces. The receiver reads it from the delivered text.
export const MARKER_RE = /rcb1 (\S+) (\S+) (\S+) (\d+) (\d+)/;
export function marker(phase, producer, stream, seq, sentMs, sizeBytes = 0) {
  const base = `rcb1 ${phase} ${producer} ${stream} ${seq} ${sentMs}`;
  return sizeBytes > base.length + 1 ? `${base} ${'x'.repeat(sizeBytes - base.length - 1)}` : base;
}

// HTTP client: returns {status, ms, body, headers}; never throws on HTTP
// errors, records network errors as status 0.
export function httpClient(baseUrl, { timeoutMs = 30000 } = {}) {
  return async function call(method, path, token, body, extraHeaders) {
    const t0 = hr();
    try {
      const res = await fetch(baseUrl + path, {
        method,
        headers: { 'content-type': 'application/json', ...(token ? { authorization: `Bearer ${token}` } : {}), ...(extraHeaders || {}) },
        body: body === undefined ? undefined : (typeof body === 'string' || body instanceof Uint8Array ? body : JSON.stringify(body)),
        signal: AbortSignal.timeout(timeoutMs),
      });
      const text = await res.text();
      let json = null;
      try { json = text ? JSON.parse(text) : null; } catch { /* non-JSON */ }
      return { status: res.status, ms: hr() - t0, body: json, retryAfter: res.headers.get('retry-after') };
    } catch (e) {
      return { status: 0, ms: hr() - t0, body: null, error: e.name === 'TimeoutError' ? 'timeout' : (e.cause?.code || e.name) };
    }
  };
}

// Strips credentials from anything that might be logged.
export function redact(s) {
  return String(s).replace(/\b(rk|at|nt|ot)_live_[A-Za-z0-9_-]+/g, '$1_live_REDACTED')
    .replace(/\bar_(ws|ag|nd|ob|wh)_[A-Za-z0-9_-]+/g, 'ar_$1_REDACTED')
    .replace(/token=[^&\s"]+/g, 'token=REDACTED');
}

export function log(...a) {
  process.stderr.write(`${new Date().toISOString()} ${redact(a.map((x) => (typeof x === 'string' ? x : JSON.stringify(x))).join(' '))}\n`);
}
