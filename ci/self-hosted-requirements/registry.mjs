#!/usr/bin/env node
// The self-hosted requirements and options registry (self-hosted/requirements.yaml):
// renders docs/self-hosted-requirements.md and checks the registry against the
// charts. Node stdlib only; YAML is read through yq (mikefarah v4), as in the
// other ci/ scripts.
//
//   node ci/self-hosted-requirements/registry.mjs render         write the doc
//   node ci/self-hosted-requirements/registry.mjs check [name..] run checks
//
// Checks (all by default):
//   schema    every entry/profile/row is well formed; local source refs resolve
//   coverage  (a) every env var, literal Secret key and Secret-bearing values
//             path in charts/*/templates is in the registry
//   shipped   (a) every shipped entry exists in the charts: values paths in
//             values.yaml, env vars in templates or as real {name, value} env
//             entries in values.yaml (never a comment), Secret names/keys equal the
//             resolved values of each profile it lists
//   planned   (c) no chart's templates (the umbrella included, through
//             .Values.<subchart>.x or index) reference a planned entry's env var
//             or values path; {{/* */}} comments are not references
//   matrix    (d) the compatibility matrix equals the pins: services image
//             digests (matrix.sh, chart defaults, profiles), the services commit
//             and migration generation, chart versions and release tags, and the
//             dbMode/boundary combinations of the profiles
//   doc       (b) docs/self-hosted-requirements.md is what `render` writes
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const REGISTRY = 'self-hosted/requirements.yaml';
const DOC = 'docs/self-hosted-requirements.md';
const rel = (p) => path.relative(ROOT, p);
const abs = (p) => path.join(ROOT, p);

function yq(args, input) {
  return execFileSync('yq', args, { cwd: ROOT, encoding: 'utf8', input, maxBuffer: 64 << 20, stdio: ['pipe', 'pipe', 'pipe'] });
}
const loadYaml = (file) => JSON.parse(yq(['-o=json', 'explode(.)', file]));
// Deep-merge YAML files left to right, the way Helm layers -f files (maps merge,
// everything else replaces; anchors and merge keys are expanded first).
const isMap = (v) => v && typeof v === 'object' && !Array.isArray(v);
const deepMerge = (a, b) => {
  if (!isMap(a) || !isMap(b)) return b;
  const o = { ...a };
  for (const [k, v] of Object.entries(b)) o[k] = k in o ? deepMerge(o[k], v) : v;
  return o;
};
const mergeYaml = (files) => files.map(loadYaml).reduce(deepMerge, {});

let errors = 0;
const err = (check, msg) => { errors++; console.log(`::error::${check}: ${msg}`); };

// ---------------------------------------------------------------------------
// Registry model
// ---------------------------------------------------------------------------
const reg = loadYaml(REGISTRY);
const entries = reg.entries || [];
const profiles = reg.profiles || [];
const profileById = Object.fromEntries(profiles.map((p) => [p.id, p]));
const KINDS = ['requirement', 'option'];
const STATUSES = ['shipped', 'planned'];
const PROVIDERS = ['operator', 'chart', 'migrator', 'stack'];

// Umbrella value paths under worker./alleyoop. belong to the subcharts.
const UMBRELLA_ALIASES = { worker: 'sessions-pipeline-worker', alleyoop: 'session-ingest-api', sessionReadApi: 'session-read-api' };
function normPath(chart, p) {
  let c = chart, q = p;
  const m = /^([a-z0-9-]+):(.+)$/.exec(p);
  if (m) { c = m[1]; q = m[2]; }
  if (c === 'sessions-pipeline') {
    const head = q.split('.')[0];
    if (UMBRELLA_ALIASES[head] && q.includes('.')) { c = UMBRELLA_ALIASES[head]; q = q.slice(head.length + 1); }
  }
  return `${c}:${q}`;
}
const asList = (v) => (v == null ? [] : Array.isArray(v) ? v : [v]);
const entryCharts = (e) => asList(e.chart);
const entryValues = (e) => asList(e.values).map((p) => normPath(entryCharts(e)[0], p));
const entryEnv = (e) => asList(e.env);
const perProfile = (v, p) => (v && typeof v === 'object' && !Array.isArray(v) ? (p in v ? v[p] : v.default) : v);
// The charts whose templates an entry's chart covers (the umbrella renders its subcharts).
const chartFamily = (c) => (c === 'sessions-pipeline' ? ['sessions-pipeline', 'sessions-pipeline-worker', 'session-ingest-api', 'session-read-api'] : [c]);

// ---------------------------------------------------------------------------
// Template scan
// ---------------------------------------------------------------------------
function walk(dir) {
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap((d) =>
    d.isDirectory() ? walk(path.join(dir, d.name)) : [path.join(dir, d.name)]);
}
const CHARTS = fs.readdirSync(abs('charts')).filter((c) => fs.existsSync(abs(`charts/${c}/Chart.yaml`))).sort();

// A values path segment that carries or names Secret material.
const SECRETISH = /secret|credential|token|^keys?$|jwks|^tls$|summaryEncryption|password/i;
const isSecretPath = (p) => p.split('.').some((s) => SECRETISH.test(s) && s !== 'automountServiceAccountToken');

// Template text with {{/* ... */}} comments (any trim markers) blanked out,
// newlines kept so line numbers stay right. A comment is never a reference.
const stripTemplateComments = (t) => t.replace(/\{\{-?\s*\/\*[\s\S]*?\*\/\s*-?\}\}/g, (m) => m.replace(/[^\n]/g, ' '));
const readTemplate = (f) => stripTemplateComments(fs.readFileSync(f, 'utf8'));

function scanChart(chart) {
  const env = new Map(); // name -> [file:line]
  const keys = new Map(); // literal Secret key -> [file:line]
  const paths = new Map(); // normalized values path -> [file:line]
  const allPaths = new Map();
  const add = (m, k, where) => { if (!m.has(k)) m.set(k, []); m.get(k).push(where); };
  for (const f of walk(abs(`charts/${chart}/templates`))) {
    const lines = readTemplate(f).split('\n');
    const alias = {}; // $var -> values path prefix ('' = .Values)
    const VALUES = String.raw`(?:\$\.Values|\.context\.Values|\$ctx\.Values|\.root\.Values|\$\.root\.Values|\.Values)`;
    lines.forEach((line, i) => {
      const where = `${rel(f)}:${i + 1}`;
      // Aliases: $v := .Values[.x.y] and $y := get $x "k".
      for (const m of line.matchAll(new RegExp(String.raw`\$(\w+)\s*:?=\s*${VALUES}((?:\.[A-Za-z_]\w*)*)`, 'g'))) alias[m[1]] = m[2].replace(/^\./, '');
      for (const m of line.matchAll(/\$(\w+)\s*:?=\s*get\s+\$(\w+)\s+"(\w+)"/g)) if (m[2] in alias) alias[m[1]] = [alias[m[2]], m[3]].filter(Boolean).join('.');
      for (const m of line.matchAll(/\bget\s+\$(\w+)\s+"(\w+)"/g)) if (m[1] in alias) {
        const p = [alias[m[1]], m[2]].filter(Boolean).join('.');
        add(allPaths, normPath(chart, p), where);
      }
      for (const m of line.matchAll(new RegExp(String.raw`${VALUES}((?:\.[A-Za-z_]\w*)+)`, 'g'))) add(allPaths, normPath(chart, m[1].slice(1)), where);
      // index <values path> "k" ["k2" ...]: keys a dotted path cannot spell (e.g. "bob-costas").
      for (const m of line.matchAll(new RegExp(String.raw`\bindex\s+(?:${VALUES}((?:\.[A-Za-z_]\w*)*)|\$(\w+)((?:\.[A-Za-z_]\w*)*))((?:\s+"[^"]+")+)`, 'g'))) {
        let base;
        if (m[2] !== undefined) { if (!(m[2] in alias)) continue; base = [alias[m[2]], (m[3] || '').slice(1)].filter(Boolean).join('.'); }
        else base = (m[1] || '').slice(1);
        const ks = [...m[4].matchAll(/"([^"]+)"/g)].map((x) => x[1]);
        add(allPaths, normPath(chart, [base, ...ks].filter(Boolean).join('.')), where);
      }
      for (const m of line.matchAll(/\$(\w+)((?:\.[A-Za-z_]\w*)+)/g)) {
        if (!(m[1] in alias) || m[2].startsWith('.Values')) continue;
        add(allPaths, normPath(chart, [alias[m[1]], m[2].slice(1)].filter(Boolean).join('.')), where);
      }
      // Env var names: `- name: X`, `{ name: X, value: ... }`, and quoted names
      // in reserved-name lists.
      for (const m of line.matchAll(/\bname:\s*"?([A-Z][A-Z0-9_]+)"?\s*(?:,|}|$)/g)) add(env, m[1], where);
      for (const m of line.matchAll(/"([A-Z][A-Z0-9]*_[A-Z0-9_]+)"/g)) add(env, m[1], where);
      // Literal Secret keys: secretKeyRef keys and generated Secret data keys.
      const km = /^\s*key:\s*"?([A-Za-z0-9_.-]+)"?\s*$/.exec(line);
      if (km && lines.slice(Math.max(0, i - 3), i).some((l) => /secretKeyRef:/.test(l))) add(keys, km[1], where);
      const sd = /^\s{2}([A-Z][A-Z0-9_]+):\s*\{\{/.exec(line);
      if (sd && lines.some((l) => /^stringData:/.test(l))) add(keys, sd[1], where);
    });
  }
  for (const [p, w] of allPaths) if (isSecretPath(p.split(':')[1])) paths.set(p, w);
  return { env, keys, paths, allPaths };
}
const scans = Object.fromEntries(CHARTS.map((c) => [c, scanChart(c)]));

// ---------------------------------------------------------------------------
// Values resolution
// ---------------------------------------------------------------------------
const getPath = (obj, p) => p.split('.').reduce((o, k) => (o == null ? undefined : o[k]), obj);
const hasPath = (obj, p) => {
  let o = obj;
  for (const k of p.split('.')) { if (o == null || typeof o !== 'object' || !(k in o)) return false; o = o[k]; }
  return true;
};
const chartValues = Object.fromEntries(CHARTS.map((c) => [c, loadYaml(`charts/${c}/values.yaml`)]));
const mergedCache = {};
function profileValues(pid) {
  if (mergedCache[pid]) return mergedCache[pid];
  const p = profileById[pid];
  const files = [`charts/${p.chart}/values.yaml`, ...asList(p.values_file).map((f) => `charts/${p.chart}/${f}`)];
  return (mergedCache[pid] = mergeYaml(files));
}
// Resolve an entry path (umbrella-relative for sessions-pipeline) in a profile.
function resolve(pid, p) {
  const prof = profileById[pid];
  const v = getPath(profileValues(pid), p.replace(/^[a-z0-9-]+:/, ''));
  if (v !== undefined) return v;
  const n = normPath(prof.chart, p);
  const [c, q] = n.split(':');
  return c === prof.chart ? undefined : getPath(chartValues[c], q);
}
const firstSet = (pid, paths) => {
  for (const p of asList(paths)) { const v = resolve(pid, p); if (v !== undefined && v !== null && v !== '') return v; }
  return undefined;
};

// ---------------------------------------------------------------------------
// Checks
// ---------------------------------------------------------------------------
const checks = {};

checks.schema = () => {
  const c = 'schema';
  const ids = new Set();
  for (const p of profiles) {
    if (!p.id || !p.chart || !p.title) err(c, `profile ${JSON.stringify(p.id)}: id, chart and title are required`);
    if (!CHARTS.includes(p.chart)) err(c, `profile ${p.id}: unknown chart ${p.chart}`);
    for (const f of asList(p.values_file)) if (!fs.existsSync(abs(`charts/${p.chart}/${f}`))) err(c, `profile ${p.id}: charts/${p.chart}/${f} does not exist`);
  }
  for (const e of entries) {
    const id = e.id || '(no id)';
    if (!/^(req|opt)\.[a-z0-9.-]+$/.test(e.id || '')) err(c, `${id}: id must match (req|opt).<name>`);
    if (ids.has(e.id)) err(c, `${id}: duplicate id`);
    ids.add(e.id);
    if (!KINDS.includes(e.kind)) err(c, `${id}: kind must be ${KINDS.join('|')}`);
    if ((e.kind === 'requirement') !== e.id?.startsWith('req.')) err(c, `${id}: req.* ids are requirements, opt.* ids are options`);
    if (!STATUSES.includes(e.status)) err(c, `${id}: status must be ${STATUSES.join('|')}`);
    for (const f of ['title', 'description', 'verify']) if (!e[f]) err(c, `${id}: ${f} is required`);
    if (!asList(e.sources).length) err(c, `${id}: at least one source ref is required`);
    if (!entryCharts(e).every((x) => CHARTS.includes(x))) err(c, `${id}: unknown chart ${e.chart}`);
    const ps = asList(e.profiles);
    if (!ps.length) err(c, `${id}: profiles is required`);
    for (const p of ps) if (!profileById[p]) err(c, `${id}: unknown profile ${p}`);
    for (const p of ps) {
      const who = perProfile(e.provided_by, p);
      if (!PROVIDERS.includes(who)) err(c, `${id}: provided_by for ${p} must be ${PROVIDERS.join('|')} (got ${JSON.stringify(who)})`);
    }
    if (e.kind === 'option') {
      if (!asList(e.choices).length) err(c, `${id}: an option lists its choices`);
      if (!('default' in e)) err(c, `${id}: an option states its default (null when there is none)`);
      for (const ch of asList(e.choices)) if (ch.status && !STATUSES.includes(ch.status)) err(c, `${id}: choice ${ch.value} status must be ${STATUSES.join('|')}`);
    }
    for (const s of asList(e.sources)) checkRef(c, id, s);
  }
  for (const r of asList(reg.compatibility?.releases)) {
    if (!STATUSES.includes(r.status) && r.status !== 'unreleased') err(c, `release ${r.id}: status must be shipped|unreleased|planned`);
    for (const s of asList(r.sources)) checkRef(c, `release ${r.id}`, s);
  }
};

// Local refs (path:line[-line]) must resolve; upstream refs are repo@sha:path:line.
function checkRef(c, id, s) {
  if (/^[\w.-]+@[0-9a-f]{7,40}:/.test(s)) return;
  const m = /^([^:]+?)(?::(\d+)(?:-(\d+))?)?$/.exec(s);
  if (!m) return err(c, `${id}: bad source ref ${s}`);
  const f = abs(m[1]);
  if (!fs.existsSync(f)) return err(c, `${id}: source ${s}: no such file`);
  if (m[2]) {
    const n = fs.readFileSync(f, 'utf8').split('\n').length;
    if (+m[2] > n || (m[3] && +m[3] > n)) err(c, `${id}: source ${s}: past the end of the file (${n} lines)`);
  }
}

checks.coverage = () => {
  const c = 'coverage';
  const covEnv = new Set([...entries.flatMap(entryEnv), ...asList(reg.internal_env).map((x) => x.name)]);
  const covKeys = new Set(entries.flatMap((e) => asList(e.secrets).flatMap((s) => asList(s.keys).flatMap((k) => (typeof k.key === 'object' ? Object.values(k.key) : [k.key])))));
  const covPaths = new Set(entries.flatMap((e) => [...entryValues(e), ...asList(e.secrets).flatMap((s) => [
    ...asList(s.name_paths), ...asList(s.keys).flatMap((k) => asList(k.key_path))].map((p) => normPath(entryCharts(e)[0], p)))]));
  const covered = (p) => covPaths.has(p) || [...covPaths].some((r) => r.endsWith('.*') && (p === r.slice(0, -2) || p.startsWith(r.slice(0, -1))));
  for (const chart of CHARTS) {
    const s = scans[chart];
    for (const [n, w] of s.env) if (!covEnv.has(n)) err(c, `env ${n} (${w[0]}) is not in ${REGISTRY}: add it to an entry's env, or to internal_env if it is pod plumbing`);
    for (const [k, w] of s.keys) if (!covKeys.has(k)) err(c, `Secret key ${k} (${w[0]}) is not in ${REGISTRY}`);
    for (const [p, w] of s.paths) if (!covered(p)) err(c, `Secret values path ${p} (${w[0]}) is not in ${REGISTRY}`);
  }
};

const templateText = Object.fromEntries(CHARTS.map((c) => [c, walk(abs(`charts/${c}/templates`)).map(readTemplate).join('\n')]));
// Env var names a chart's values.yaml really defines: the name of an EnvVar map
// ({name, value|valueFrom}) anywhere in the parsed values. Comments are gone after parsing.
function valuesEnvNames(v, out = new Set()) {
  if (Array.isArray(v)) v.forEach((x) => valuesEnvNames(x, out));
  else if (isMap(v)) {
    if (typeof v.name === 'string' && ('value' in v || 'valueFrom' in v)) out.add(v.name);
    Object.values(v).forEach((x) => valuesEnvNames(x, out));
  }
  return out;
}
const valuesEnv = Object.fromEntries(CHARTS.map((c) => [c, valuesEnvNames(chartValues[c])]));

checks.shipped = () => {
  const c = 'shipped';
  for (const e of entries.filter((x) => x.status === 'shipped')) {
    const fam = entryCharts(e).flatMap(chartFamily);
    for (const p of entryValues(e)) {
      const [ch, q] = p.split(':');
      const qq = q.replace(/\.\*$/, '');
      if (!hasPath(chartValues[ch], qq) && !scans[ch].allPaths.has(`${ch}:${qq}`)) err(c, `${e.id}: values path ${p} is neither in charts/${ch}/values.yaml nor read by its templates`);
    }
    for (const n of entryEnv(e)) {
      if (!fam.some((ch) => scans[ch].env.has(n) || valuesEnv[ch].has(n))) err(c, `${e.id}: env ${n} is neither rendered by ${fam.join('/')} templates nor an env entry ({name, value}) in their values.yaml`);
    }
    for (const s of asList(e.secrets)) {
      for (const pid of asList(e.profiles)) {
        const want = perProfile(s.name, pid);
        if (s.name_paths && want && !String(want).startsWith('<')) {
          const got = firstSet(pid, s.name_paths);
          if (got !== want) err(c, `${e.id}: Secret name in ${pid} resolves to ${JSON.stringify(got)} (${asList(s.name_paths).join(' | ')}), registry says ${want}`);
        }
        for (const k of asList(s.keys)) {
          const wk = perProfile(k.key, pid);
          // An optional key with no default (key "<operator-chosen ...>"): the
          // profile must leave key_path unset; the operator names the data key.
          if (k.optional && String(wk).startsWith('<')) {
            const got = k.key_path ? firstSet(pid, k.key_path) : undefined;
            if (!k.key_path) err(c, `${e.id}: optional Secret key ${wk} needs a key_path`);
            else if (got !== undefined && got !== null && got !== '') err(c, `${e.id}: optional Secret key ${k.key_path} in ${pid} defaults to ${JSON.stringify(got)}; record it as the key`);
            continue;
          }
          if (k.key_path) {
            const got = firstSet(pid, k.key_path);
            if (got !== wk) err(c, `${e.id}: Secret key in ${pid} resolves to ${JSON.stringify(got)} (${k.key_path}), registry says ${wk}`);
          } else if (!fam.some((ch) => scans[ch].keys.has(wk) || templateText[ch].includes(wk))) {
            err(c, `${e.id}: literal Secret key ${wk} is not in ${fam.join('/')} templates`);
          }
        }
      }
    }
    for (const pid of asList(e.profiles)) for (const [p, want] of Object.entries(e.profile_values?.[pid] || {})) {
      const got = resolve(pid, p);
      if (JSON.stringify(got ?? null) !== JSON.stringify(want)) err(c, `${e.id}: ${p} in ${pid} is ${JSON.stringify(got)}, registry says ${JSON.stringify(want)}`);
    }
  }
};

checks.planned = () => {
  const c = 'planned';
  for (const e of entries.filter((x) => x.status === 'planned')) {
    // A planned env name may already be shipped by an unrelated chart (for
    // example Relay History can use OPENAI_API_KEY while the Sessions Pipeline model
    // worker remains planned). Enforce absence only in the entry's chart
    // family; normalized value paths still catch umbrella/subchart reads.
    const plannedCharts = [...new Set(entryCharts(e).flatMap(chartFamily))];
    for (const ch of plannedCharts) {
      for (const n of entryEnv(e)) if (scans[ch].env.has(n) || new RegExp(`\\b${n}\\b`).test(templateText[ch])) err(c, `${e.id} is planned, but charts/${ch}/templates references env ${n}: ship it (status: shipped) or remove the reference`);
    }
    // Paths are normalized (an umbrella .Values.worker.x is sessions-pipeline-worker:x),
    // so scan every chart: a planned sessions-pipeline-worker path read only by the
    // sessions-pipeline umbrella templates (or any other consumer) is still caught.
    for (const p of entryValues(e)) {
      const want = p.replace(/\.\*$/, '');
      for (const ch of CHARTS) {
        for (const [tp, where] of scans[ch].allPaths) if (tp === want || tp.startsWith(`${want}.`)) err(c, `${e.id} is planned, but charts/${ch}/templates reads ${tp} (${where[0]})`);
      }
    }
  }
};

checks.matrix = () => {
  const c = 'matrix';
  const comp = reg.compatibility || {};
  const img = comp.services_images || {};
  const matrixSh = fs.readFileSync(abs('ci/sessions-pipeline-profiles/matrix.sh'), 'utf8');
  const shConst = (n) => (new RegExp(`^${n}="([^"]+)"`, 'm').exec(matrixSh) || [])[1];
  const ref = (r) => `${r.repository}@${r.digest}`;
  for (const [k, n] of [['ghcr', 'GHCR'], ['ecr', 'ECR']]) {
    if (!img[k]) { err(c, `compatibility.services_images.${k} is missing`); continue; }
    if (shConst(n) !== ref(img[k])) err(c, `services image ${k} is ${ref(img[k])}, ci/sessions-pipeline-profiles/matrix.sh ${n} is ${shConst(n)}`);
  }
  const file = (p) => fs.readFileSync(abs(p), 'utf8').trim();
  if (file('ci/sessions-pipeline-search-worker-role/services-commit') !== img.source_commit) err(c, `services source_commit ${img.source_commit} != ci/sessions-pipeline-search-worker-role/services-commit`);
  if (file('ci/sessions-pipeline-search-worker-role/services-generation') !== img.migration_generation) err(c, `migration_generation ${img.migration_generation} != ci/sessions-pipeline-search-worker-role/services-generation`);
  for (const ch of ['sessions-pipeline-worker', 'session-ingest-api']) if (chartValues[ch].image.digest !== img.ghcr?.digest) err(c, `charts/${ch}/values.yaml image.digest is ${chartValues[ch].image.digest}, not the registry GHCR digest`);
  // Every sessions-pipeline profile pins the image the registry names for it.
  for (const p of profiles.filter((x) => x.chart === 'sessions-pipeline')) {
    const want = img[p.services_image];
    if (!want) { err(c, `profile ${p.id}: services_image must be ghcr or ecr`); continue; }
    const pinned = (k) => getPath(profileValues(p.id), k);
    for (const k of ['worker.image.digest', 'alleyoop.image.digest', 'privilegedSql.sqlImage.digest']) {
      const v = pinned(k);
      if (k.startsWith('privilegedSql') && !v) continue;
      const eff = v || chartValues[UMBRELLA_ALIASES[k.split('.')[0]]]?.image.digest;
      if (eff !== want.digest) err(c, `profile ${p.id}: ${k} is ${eff}, registry ${p.services_image} digest is ${want.digest}`);
    }
    if (p.services_image === 'ecr' && pinned('worker.image.repository') !== want.repository) err(c, `profile ${p.id}: worker.image.repository is not ${want.repository}`);
    // dbMode / boundary / backend as the registry states them.
    const v = profileValues(p.id);
    const got = { hoopdb: v.hoopdb?.enabled ? 'cnpg' : 'external', db_mode: getPath(v, 'worker.migrations.databaseMode'), boundary: getPath(v, 'worker.migrations.functionBoundaryMode') || null };
    for (const k of Object.keys(got)) if ((p.db?.[k] ?? null) !== got[k]) err(c, `profile ${p.id}: db.${k} is ${JSON.stringify(p.db?.[k])}, the values render ${JSON.stringify(got[k])}`);
  }
  // Every sessions-pipeline values file in the render matrix is a registry profile or ci_only.
  const rows = [...matrixSh.matchAll(/^\s+"([^"|]+\.yaml)\|/gm)].map((m) => m[1]);
  const known = new Set([...profiles.filter((x) => x.chart === 'sessions-pipeline').flatMap((x) => asList(x.values_file)), ...asList(reg.ci_only_values).map((x) => x.file)]);
  for (const r of rows) if (!known.has(r)) err(c, `ci/sessions-pipeline-profiles/matrix.sh row ${r} is neither a registry profile nor in ci_only_values`);
  for (const k of known) if (!rows.includes(k)) err(c, `${k} is in the registry but has no ci/sessions-pipeline-profiles/matrix.sh row`);

  // Releases.
  const releases = asList(comp.releases);
  const tagExists = (t) => { try { execFileSync('git', ['rev-parse', '-q', '--verify', `refs/tags/${t}`], { cwd: ROOT, stdio: 'pipe' }); return true; } catch { return false; } };
  const atTag = (t, f) => execFileSync('git', ['show', `${t}:${f}`], { cwd: ROOT, encoding: 'utf8' });
  const yqStr = (expr, text) => yq(['-r', expr, '-'], text).trim();
  const imageOf = (vals) => ({ repository: vals.image?.repository ?? '', digest: vals.image?.digest || undefined, tag: vals.image?.tag || undefined });
  const sameImage = (want, got) => ['repository', 'digest', 'tag'].every((k) => want[k] === undefined || want[k] === got[k]);
  for (const r of releases) {
    if (r.status === 'planned') continue;
    for (const [chart, version] of Object.entries(r.charts || {})) {
      const tag = `${chart}-${version}`;
      // shipped rows are checked against the release tag, unreleased rows against the tree.
      let chartYaml, vals;
      if (r.status === 'shipped') {
        if (!tagExists(tag)) { err(c, `release ${r.id}: tag ${tag} does not exist (fetch tags: git fetch --tags)`); continue; }
        chartYaml = JSON.parse(yq(['-o=json', '.', '-'], atTag(tag, `charts/${chart}/Chart.yaml`)));
        vals = JSON.parse(yq(['-o=json', '.', '-'], atTag(tag, `charts/${chart}/values.yaml`)));
      } else {
        chartYaml = loadYaml(`charts/${chart}/Chart.yaml`);
        vals = chartValues[chart];
        if (tagExists(tag)) console.log(`::warning::matrix: release ${r.id}: tag ${tag} exists; set status: shipped`);
        if (chartYaml.version !== version) err(c, `release ${r.id}: charts/${chart}/Chart.yaml is ${chartYaml.version}, not ${version}`);
      }
      const want = r.images?.[chart];
      if (want && !sameImage(want, imageOf(vals))) err(c, `release ${r.id}: ${tag} image is ${JSON.stringify(imageOf(vals))}, the matrix says ${JSON.stringify(want)}`);
      const av = r.app_versions?.[chart];
      if (av !== undefined && String(chartYaml.appVersion) !== String(av)) err(c, `release ${r.id}: ${tag} appVersion is ${chartYaml.appVersion}, the matrix says ${av}`);
      for (const [dn, dv] of Object.entries(r.depends?.[chart] || {})) {
        const d = asList(chartYaml.dependencies).find((x) => (x.alias || x.name) === dn);
        if (!d || d.version !== dv) err(c, `release ${r.id}: ${tag} depends on ${dn} ${d?.version}, the matrix says ${dv}`);
      }
      if (r.current) {
        const tree = loadYaml(`charts/${chart}/Chart.yaml`).version;
        if (tree !== version) err(c, `release ${r.id} is marked current, but charts/${chart}/Chart.yaml is ${tree}, not ${version}: add a row for ${chart} ${tree}`);
        if (want && !sameImage(want, imageOf(chartValues[chart]))) err(c, `release ${r.id}: charts/${chart}/values.yaml image differs from the current row`);
      }
    }
    if (r.current && r.services && (r.services.source_commit !== img.source_commit || r.services.migration_generation !== img.migration_generation)) err(c, `release ${r.id}: services pins differ from compatibility.services_images`);
    if (r.current && r.services) for (const ch of ['sessions-pipeline-worker', 'session-ingest-api']) {
      if (r.images?.[ch]?.digest !== img.ghcr?.digest) err(c, `release ${r.id}: ${ch} image digest is not compatibility.services_images.ghcr`);
    }
  }
  for (const chart of CHARTS) {
    const v = loadYaml(`charts/${chart}/Chart.yaml`).version;
    if (!releases.some((r) => r.current && r.charts?.[chart] === v)) err(c, `charts/${chart} ${v} has no current row in compatibility.releases`);
  }
  // Every dbMode/boundary combination a sessions-pipeline profile renders is a supported combination.
  const cur = releases.find((r) => r.current && r.charts?.['sessions-pipeline']);
  const combos = asList(cur?.db_combos);
  for (const p of profiles.filter((x) => x.chart === 'sessions-pipeline')) {
    if (!combos.some((k) => k.db_mode === p.db.db_mode && (k.boundary ?? null) === (p.db.boundary ?? null) && asList(k.profiles).includes(p.id))) err(c, `profile ${p.id} (${p.db.db_mode} + ${p.db.boundary}) is not in the current sessions-pipeline row's db_combos`);
  }
};

checks.doc = () => {
  const want = renderDoc();
  const have = fs.existsSync(abs(DOC)) ? fs.readFileSync(abs(DOC), 'utf8') : '';
  if (have !== want) err('doc', `${DOC} is out of date: run node ci/self-hosted-requirements/registry.mjs render`);
};

// ---------------------------------------------------------------------------
// Doc rendering
// ---------------------------------------------------------------------------
const code = (s) => (s === '' ? '`""`' : `\`${s}\``);
const show = (v) => (v == null ? '(no default)' : Array.isArray(v) ? code(JSON.stringify(v)) : typeof v === 'object' ? Object.entries(v).map(([k, x]) => code(`${k}=${x}`)).join(', ') : code(v));
const cell = (s) => String(s ?? '').replace(/\|/g, '\\|').replace(/\n+/g, ' ').trim();
const badge = (status) => (status === 'planned' ? '**planned**' : 'shipped');
const short = (d) => (d ? `${d.slice(0, 19)}…` : '');

function secretLines(e, pid) {
  return asList(e.secrets).map((s) => {
    const name = perProfile(s.name, pid);
    const keys = asList(s.keys).map((k) => code(perProfile(k.key, pid))).join(', ');
    return `Secret ${code(name)}${keys ? ` keys ${keys}` : ''}${s.note ? ` (${s.note})` : ''}`;
  });
}
function mapsTo(e, pid) {
  const parts = [];
  if (asList(e.values).length) parts.push(`values ${asList(e.values).map(code).join(', ')}`);
  if (entryEnv(e).length) parts.push(`env ${entryEnv(e).map(code).join(', ')}`);
  parts.push(...new Set(secretLines(e, pid)));
  return parts.join('; ');
}
const anchor = (id) => id.replace(/[^a-z0-9-]/g, '-');

function renderDoc() {
  const out = [];
  const L = (...l) => out.push(...l);
  L('<!-- Generated from self-hosted/requirements.yaml by ci/self-hosted-requirements/registry.mjs render. Do not edit. -->',
    '# Self-hosted requirements and options', '',
    reg.overview.trim(), '',
    `Source of truth: [\`${REGISTRY}\`](../${REGISTRY}). ${entries.length} entries: ` +
      ['requirement', 'option'].map((k) => `${entries.filter((e) => e.kind === k).length} ${k}s (${STATUSES.map((s) => `${entries.filter((e) => e.kind === k && e.status === s).length} ${s}`).join(', ')})`).join(', ') + '.',
    '', '## Contents', '',
    '- [Compatibility matrix](#compatibility-matrix)',
    '- [Profiles](#profiles)',
    ...profiles.map((p) => `  - [${p.id}](#profile-${anchor(p.id)})`),
    '- [All entries](#all-entries)', '',
    '## Compatibility matrix', '');
  const comp = reg.compatibility;
  const img = comp.services_images;
  L('Services image (sessions-pipeline-worker, alleyoop and the privileged SQL Jobs):', '',
    '| registry | image | source | migration generation |', '| --- | --- | --- | --- |',
    `| GHCR | ${code(`${img.ghcr.repository}@${img.ghcr.digest}`)} | sessions-pipeline ${code(img.source_commit)} | ${code(img.migration_generation)} |`,
    `| ECR (AWS path) | ${code(`${img.ecr.repository}@${img.ecr.digest}`)} | same | same |`, '');
  L('| row | status | charts | image | services source / generation | supported dbMode + boundary | notes |',
    '| --- | --- | --- | --- | --- | --- | --- |');
  for (const r of comp.releases) {
    const charts = Object.entries(r.charts || {}).map(([c, v]) => `${c} ${v}`).join('<br>');
    const deps = r.depends ? `<br>(deps: ${Object.values(r.depends).flatMap((d) => Object.entries(d).map(([c, v]) => `${c} ${v}`)).join(', ')})` : '';
    // digest_required: the chart ships no default digest and refuses to render
    // without one, so there is no installable tag to show.
    const imgs = Object.entries(r.images || {}).map(([c, i]) => `${c}: ${code(`${i.repository || '<required repository>'}${i.digest ? `@${short(i.digest)}` : i.digest_required ? '@sha256:<required>' : `:${i.tag ?? r.app_versions?.[c] ?? ''}`}`)}`);
    const image = [...imgs, cell(r.images_note)].filter(Boolean).join('<br>');
    const svc = r.services ? `${code(r.services.source_commit.slice(0, 12))} / ${code(r.services.migration_generation.slice(0, 12))}` : '';
    const combos = asList(r.db_combos).map((k) => `${k.db_mode} + ${k.boundary ?? '(unset)'} (${k.hoopdb})${k.status && k.status !== 'shipped' ? ` (${k.status})` : ''}`).join('<br>');
    L(`| ${r.id} | ${r.status === 'planned' ? '**planned**' : r.status} | ${charts}${deps} | ${image} | ${svc} | ${combos} | ${cell(r.notes)} |`);
  }
  L('', '### Supported dbMode and function boundary combinations', '',
    '| dbMode | boundary | HoopDb | status | profiles | notes |', '| --- | --- | --- | --- | --- | --- |');
  const cur = comp.releases.find((r) => r.current && r.charts?.['sessions-pipeline']);
  for (const k of asList(cur.db_combos)) L(`| ${code(k.db_mode)} | ${k.boundary ? code(k.boundary) : '(unset)'} | ${k.hoopdb} | ${k.status} | ${asList(k.profiles).join(', ')} | ${cell(k.notes)} |`);
  for (const k of asList(comp.refused_combos)) L(`| ${code(k.db_mode)} | ${k.boundary ? code(k.boundary) : '(unset)'} | ${k.hoopdb ?? 'any'} | refused | | ${cell(k.notes)} |`);

  L('', '## Profiles', '',
    'Each profile lists what the operator must provide (requirements) and what they can choose (options). ' +
    '`provided by` says who satisfies it in that profile: `operator` (you, before install), `chart` (rendered by the chart), ' +
    '`migrator` (the HoopDb migrate Job), or `stack` (the AWS/GCP infrastructure stack). Items marked **planned** are not implemented: no chart reads them yet.', '');
  for (const p of profiles) {
    L(`### Profile: ${p.id}`, '', `**${p.title}.** ${cell(p.summary)}`, '');
    const meta = [`chart ${code(p.chart)}`];
    if (asList(p.values_file).length) meta.push(`values ${asList(p.values_file).map((f) => `[${code(f)}](../charts/${p.chart}/${f})`).join(', ')}`);
    if (p.db) meta.push(`dbMode ${code(p.db.db_mode)}`, `boundary ${p.db.boundary ? code(p.db.boundary) : '(unset)'}`, `HoopDb ${p.db.hoopdb}`);
    if (p.services_image) meta.push(`services image ${p.services_image.toUpperCase()}`);
    if (p.install) meta.push(`install: ${code(p.install)}`);
    L(meta.join(' · '), '');
    for (const kind of ['requirement', 'option']) {
      const es = entries.filter((e) => e.kind === kind && asList(e.profiles).includes(p.id));
      if (!es.length) continue;
      L(kind === 'requirement' ? '**Requirements (provide these)**' : '**Options (choose)**', '');
      if (kind === 'requirement') {
        L('| | requirement | provided by | maps to | verify |', '| --- | --- | --- | --- | --- |');
        for (const e of es) L(`| ${badge(e.status)} | [${cell(e.title)}](#${anchor(e.id)}) | ${perProfile(e.provided_by, p.id)} | ${cell(mapsTo(e, p.id))} | ${cell(perProfile(e.verify, p.id))} |`);
      } else {
        L('| | option | choices | default here | maps to |', '| --- | --- | --- | --- | --- |');
        for (const e of es) {
          const ch = asList(e.choices).map((x) => `${show(x.value)}${x.status === 'planned' ? ' (**planned**)' : ''}`).join(', ');
          const def = e.profile_default && (p.id in e.profile_default || 'default' in e.profile_default) ? perProfile(e.profile_default, p.id) : e.default;
          L(`| ${badge(e.status)} | [${cell(e.title)}](#${anchor(e.id)}) | ${ch} | ${show(def)} | ${cell(mapsTo(e, p.id))} |`);
        }
      }
      L('');
    }
  }

  L('## All entries', '');
  for (const kind of ['requirement', 'option']) {
    L(`### ${kind === 'requirement' ? 'Requirements' : 'Options'}`, '');
    for (const e of entries.filter((x) => x.kind === kind)) {
      L(`#### ${e.id}`, '', `<a id="${anchor(e.id)}"></a>`, '', `**${cell(e.title)}** · ${badge(e.status)} · chart ${entryCharts(e).map(code).join(', ')} · profiles ${asList(e.profiles).join(', ')}`, '', e.description.trim(), '');
      if (e.kind === 'option') {
        L(`- Default: ${show(e.default)}${e.profile_default ? ` (by profile: ${Object.entries(e.profile_default).map(([k, v]) => `${k} ${show(v)}`).join(', ')})` : ''}`);
        L(`- Choices: ${asList(e.choices).map((x) => `${show(x.value)}${x.status === 'planned' ? ' (**planned**)' : ''}${x.note ? `: ${x.note}` : ''}`).join('; ')}`);
      }
      const pb = typeof e.provided_by === 'object' ? Object.entries(e.provided_by).map(([k, v]) => `${k}: ${v}`).join(', ') : e.provided_by;
      L(`- Provided by: ${pb}`);
      if (asList(e.values).length) L(`- Values: ${asList(e.values).map(code).join(', ')}`);
      if (entryEnv(e).length) L(`- Env: ${entryEnv(e).map(code).join(', ')}`);
      for (const s of asList(e.secrets)) {
        const name = typeof s.name === 'object' ? Object.entries(s.name).map(([k, v]) => `${code(v)} (${k})`).join(', ') : code(s.name);
        const keys = asList(s.keys).map((k) => (typeof k.key === 'object' ? Object.entries(k.key).map(([pk, v]) => `${code(v)} (${pk})`).join(', ') : code(k.key)) + (k.key_path ? ` from ${code(k.key_path)}` : '') + (k.optional ? ` (optional: ${k.optional})` : '')).join('; ');
        L(`- Secret: ${name}${s.name_paths ? ` from ${asList(s.name_paths).map(code).join(' then ')}` : ''}${keys ? `; keys ${keys}` : ''}${s.note ? `. ${s.note}` : ''}`);
      }
      const verify = typeof e.verify === 'object' ? Object.entries(e.verify).map(([k, v]) => `${k}: ${v}`).join(' / ') : e.verify;
      L(`- Verify: ${cell(verify)}`);
      L(`- Sources: ${asList(e.sources).map((s) => (/^[\w.-]+@/.test(s) ? code(s) : `[${code(s)}](../${s.replace(/:(\d+)(?:-(\d+))?$/, (_, a, b) => `#L${a}${b ? `-L${b}` : ''}`)})`)).join(', ')}`);
      L('');
    }
  }
  L('## Pod plumbing env (not operator-facing)', '',
    'Rendered by the charts but not a requirement or an option: fixed by the chart or derived from other values.', '',
    '| env | chart | why |', '| --- | --- | --- |',
    ...asList(reg.internal_env).map((x) => `| ${code(x.name)} | ${asList(x.chart).join(', ')} | ${cell(x.why)} |`), '');
  return out.join('\n');
}

// ---------------------------------------------------------------------------
const [cmd = 'check', ...names] = process.argv.slice(2);
if (cmd === 'render') {
  fs.writeFileSync(abs(DOC), renderDoc());
  console.log(`wrote ${DOC}`);
} else if (cmd === 'check') {
  const run = names.length ? names : Object.keys(checks);
  for (const n of run) {
    if (!checks[n]) { console.error(`unknown check ${n}; one of ${Object.keys(checks).join(', ')}`); process.exit(2); }
    const before = errors;
    checks[n]();
    console.log(`--- ${n}: ${errors === before ? 'OK' : `${errors - before} error(s)`}`);
  }
  if (errors) { console.log(`self-hosted requirements registry: ${errors} error(s)`); process.exit(1); }
  console.log(`self-hosted requirements registry: OK (${entries.length} entries, ${profiles.length} profiles)`);
} else if (cmd === 'scan') {
  // Debug: what the coverage check extracts from the templates.
  for (const c of CHARTS) console.log(c, JSON.stringify({ env: [...scans[c].env.keys()], keys: [...scans[c].keys.keys()], paths: [...scans[c].paths.keys()] }, null, 1));
} else {
  console.error('usage: registry.mjs render | check [schema coverage shipped planned matrix doc] | scan');
  process.exit(2);
}
