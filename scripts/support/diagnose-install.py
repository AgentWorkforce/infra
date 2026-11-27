#!/usr/bin/env python3
"""Read-only install diagnostics. Credentials stay in memory; output is allowlisted."""
from __future__ import annotations

import argparse
import base64
import datetime as dt
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import parse_qsl, unquote, urlsplit

# Matches the managed-Postgres install contract, including the JSON-wrapped slots.
SLOTS = {
    'control-owner': ('agent-relay-secrets', 'database-migrations-url', None, 'control_owner', 'control'),
    'control-runtime': ('agent-relay-secrets', 'database-url', None, 'control_api_runtime', 'control'),
    'cast-owner': ('agent-relay-secrets', 'database-owner-url', None, 'relaycast_owner', 'cast'),
    'cast-runtime': ('agent-relay-secrets', 'database-runtime-url', None, 'relaycast_runtime', 'cast'),
    'hoop-owner': ('agent-relay-secrets', 'HOOPDB_MIGRATION_URL', None, None, 'hoop'),
    'hoop-runtime': ('agent-relay-secrets', 'HOOPDB_URL', None, 'sessions_pipeline_runtime', 'hoop'),
    'read-runtime': ('agent-relay-read-api', 'RELAYHISTORY_READ_API_SECRET', 'supabase_url', 'bulls96_read_api', 'hoop'),
    'ingest-runtime': ('agent-relay-ingest-edge-runtime', 'database-url', None, 'bulls96_session_ingest', 'hoop'),
    'search-runtime': ('search-indexer-runtime', 'RELAYHISTORY_PIPELINE_CONSUMER_SECRET', 'hoopdb_url', 'search_consumer_runtime', 'hoop'),
    'search-owner': ('search-indexer-owner', 'RELAYHISTORY_PIPELINE_CONSUMER_SECRET', 'hoopdb_url', None, 'hoop'),
}

IDENTITY_SQL = """
SELECT json_build_object(
 'user', current_user, 'database', current_database(),
 'target', json_build_array(inet_server_addr(), inet_server_port(), (SELECT oid FROM pg_database WHERE datname=current_database())),
 'tls', coalesce((SELECT ssl FROM pg_stat_ssl WHERE pid=pg_backend_pid()), false),
 'server_version', current_setting('server_version_num')::int,
 'database_owner', (SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname=current_database()),
 'schema_owners', (SELECT json_object_agg(nspname,pg_get_userbyid(nspowner)) FROM pg_namespace WHERE nspname IN ('public','sessions')),
 'roles', (SELECT json_object_agg(rolname, json_build_object('login',rolcanlogin,'restricted',NOT (rolsuper OR rolcreatedb OR rolcreaterole OR rolreplication OR rolbypassrls))) FROM pg_roles WHERE rolname IN ('control_owner','control_api_runtime','relaycast_owner','relaycast_runtime','sessions_pipeline_runtime','bulls96_read_api','bulls96_session_ingest','search_consumer_runtime')),
 'database_owner_membership', (SELECT pg_has_role(current_user,datdba,'MEMBER') FROM pg_database WHERE datname=current_database()),
 'sessions_usage', CASE WHEN to_regnamespace('sessions') IS NULL THEN false ELSE has_schema_privilege(current_user,'sessions','USAGE') END,
 'login', (SELECT rolcanlogin FROM pg_roles WHERE rolname=current_user),
 'restricted', (SELECT NOT (rolsuper OR rolcreatedb OR rolcreaterole OR rolreplication OR rolbypassrls) FROM pg_roles WHERE rolname=current_user),
 'admin_membership', EXISTS (SELECT 1 FROM pg_roles WHERE rolname IN ('rds_superuser','cloudsqlsuperuser','pg_write_all_data','pg_read_all_data') AND pg_has_role(current_user, oid, 'MEMBER'))
);
"""

# Only system catalogs and privilege functions: no application rows, DDL or probes
# that create temporary objects. Counts distinguish an empty schema from success.
CAST_SQL = """
WITH roles AS (
 SELECT 'relaycast_owner'::text AS owner, 'relaycast_runtime'::text AS runtime
), objects AS (
 SELECT c.oid,c.relname,c.relowner,c.relkind FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
 WHERE n.nspname='public' AND c.relkind IN ('r','p','S','v','m','f')
 AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid='pg_class'::regclass AND d.objid=c.oid AND d.deptype='e')
), defaults AS (
 SELECT a.privilege_type, d.defaclobjtype FROM pg_default_acl d
 CROSS JOIN LATERAL aclexplode(d.defaclacl) a
 WHERE d.defaclrole=(SELECT oid FROM pg_roles WHERE rolname='relaycast_owner')
 AND (d.defaclnamespace=0 OR d.defaclnamespace=(SELECT oid FROM pg_namespace WHERE nspname='public'))
 AND a.grantee=(SELECT oid FROM pg_roles WHERE rolname='relaycast_runtime')
)
SELECT json_build_object(
 'roles_exist', (SELECT count(*)=2 FROM pg_roles WHERE rolname IN ('relaycast_owner','relaycast_runtime')),
 'schema_owner', coalesce((SELECT pg_get_userbyid(nspowner)='relaycast_owner' FROM pg_namespace WHERE nspname='public'),false),
 'owner_connect', has_database_privilege(owner,current_database(),'CONNECT'),
 'owner_temp', has_database_privilege(owner,current_database(),'TEMP'),
 'owner_no_db_create', NOT has_database_privilege(owner,current_database(),'CREATE'),
 'owner_schema_create', has_schema_privilege(owner,'public','CREATE'),
 'runtime_connect', has_database_privilege(runtime,current_database(),'CONNECT'),
 'runtime_usage', has_schema_privilege(runtime,'public','USAGE'),
 'runtime_no_create', NOT has_schema_privilege(runtime,'public','CREATE'),
 'runtime_no_db_create', NOT has_database_privilege(runtime,current_database(),'CREATE'),
 'runtime_no_temp', NOT has_database_privilege(runtime,current_database(),'TEMP'),
 'runtime_no_owner_membership', NOT pg_has_role(runtime,owner,'MEMBER'),
 'public_no_schema_create', NOT EXISTS (SELECT 1 FROM pg_namespace n CROSS JOIN LATERAL aclexplode(coalesce(n.nspacl,acldefault('n',n.nspowner))) a WHERE n.nspname='public' AND a.grantee=0 AND a.privilege_type='CREATE'),
 'public_no_db_create_temp', NOT EXISTS (SELECT 1 FROM pg_database d CROSS JOIN LATERAL aclexplode(coalesce(d.datacl,acldefault('d',d.datdba))) a WHERE d.datname=current_database() AND a.grantee=0 AND a.privilege_type IN ('CREATE','TEMPORARY')),
 'public_no_object_grants', NOT EXISTS (SELECT 1 FROM objects o JOIN pg_class c ON c.oid=o.oid CROSS JOIN LATERAL aclexplode(coalesce(c.relacl,acldefault(CASE WHEN c.relkind='S' THEN 'S'::char ELSE 'r'::char END::"char",c.relowner))) a WHERE a.grantee=0),
 'public_no_default_grants', NOT EXISTS (SELECT 1 FROM pg_default_acl d CROSS JOIN LATERAL aclexplode(d.defaclacl) a WHERE d.defaclrole=(SELECT oid FROM pg_roles WHERE rolname=owner) AND d.defaclobjtype IN ('r','S') AND (d.defaclnamespace=0 OR d.defaclnamespace=(SELECT oid FROM pg_namespace WHERE nspname='public')) AND a.grantee=0),
 'table_defaults', (SELECT count(DISTINCT privilege_type)=4 FROM defaults WHERE defaclobjtype='r' AND privilege_type IN ('SELECT','INSERT','UPDATE','DELETE')),
 'sequence_defaults', (SELECT count(DISTINCT privilege_type)=3 FROM defaults WHERE defaclobjtype='S' AND privilege_type IN ('SELECT','USAGE','UPDATE')),
 'objects', (SELECT count(*) FROM objects),
 'wrong_owners', (SELECT count(*) FROM objects WHERE pg_get_userbyid(relowner)<>owner),
 'missing_table_grants', (SELECT count(*) FROM objects WHERE relkind<>'S' AND relname<>'_engine_migrations' AND NOT (has_table_privilege(runtime,oid,'SELECT') AND has_table_privilege(runtime,oid,'INSERT') AND has_table_privilege(runtime,oid,'UPDATE') AND has_table_privilege(runtime,oid,'DELETE'))),
 'ledger_runtime_read_only', (SELECT coalesce(bool_and(has_table_privilege(runtime,oid,'SELECT') AND NOT has_table_privilege(runtime,oid,'INSERT,UPDATE,DELETE,TRUNCATE')),true) FROM objects WHERE relname='_engine_migrations'),
 'missing_sequence_grants', (SELECT count(*) FROM objects WHERE relkind='S' AND NOT (has_sequence_privilege(runtime,oid,'SELECT') AND has_sequence_privilege(runtime,oid,'USAGE') AND has_sequence_privilege(runtime,oid,'UPDATE')))
) FROM roles;
"""
HOOP_SQL = """SELECT json_build_object(
 'vector', EXISTS(SELECT 1 FROM pg_extension WHERE extname='vector'),
 'pg_trgm', EXISTS(SELECT 1 FROM pg_extension WHERE extname='pg_trgm'),
 'btree_gin', EXISTS(SELECT 1 FROM pg_extension WHERE extname='btree_gin'),
 'sessions_schema', EXISTS(SELECT 1 FROM pg_namespace WHERE nspname='sessions')
);"""

# Ingest proof: a desktop upload lands an object in S3 and a pointer row in
# sessions.session_index. Only counts, an age and booleans leave the database
# path; the latest bucket/key stay in memory for an optional S3 HEAD.
INGEST_TABLE_SQL = """SELECT json_build_object(
 'present', to_regclass('sessions.session_index') IS NOT NULL,
 'forced_rls', coalesce((SELECT relforcerowsecurity FROM pg_class WHERE oid=to_regclass('sessions.session_index')), false)
);"""
INGEST_SQL = """SELECT json_build_object(
 'rows', (SELECT count(*) FROM sessions.session_index),
 'pointers', (SELECT count(*) FROM sessions.session_index WHERE bucket IS NOT NULL AND manifest_key IS NOT NULL AND deleted_at IS NULL),
 'latest_age_s', (SELECT floor(extract(epoch FROM now() - max(created_at)))::bigint FROM sessions.session_index),
 'latest', (SELECT json_build_object('bucket',bucket,'key',manifest_key) FROM sessions.session_index
            WHERE bucket IS NOT NULL AND manifest_key IS NOT NULL AND deleted_at IS NULL ORDER BY created_at DESC LIMIT 1)
);"""


def ingest_checks(options, credential, report, query=None):
    psql = query or globals()['psql']
    table = psql(credential, INGEST_TABLE_SQL, options.timeout, options.ca_file)
    if not table.get('present'):
        report.unknown('ingest.pointers', 'session-index-missing')
        return
    if table.get('forced_rls'):
        report.unknown('ingest.pointers', 'forced-row-level-security-hides-rows-from-owner')
        return
    data = psql(credential, INGEST_SQL, options.timeout, options.ca_file)
    rows, pointers, age = int(data.get('rows') or 0), int(data.get('pointers') or 0), data.get('latest_age_s')
    if not rows:
        report.add('ingest.pointers', 'UNKNOWN', 'No sessions ingested yet.',
                   'Sign in with the desktop app, start a Claude/Codex session, wait a few minutes, then rerun.')
        return
    when = (' Latest arrived '+(str(int(age)//60)+' min' if age is not None and int(age) >= 60 else str(age)+' s')+' ago.') if age is not None else ''
    report.test('ingest.pointers', pointers > 0,
                str(rows)+' session row(s), '+str(pointers)+' with an S3 object pointer.'+when,
                'Rows without S3 pointers: check the ingest edge logs and its S3 (locker) bucket access.')
    latest = data.get('latest') or {}
    if not (latest.get('bucket') and latest.get('key')) or getattr(options, 'no_s3_check', False):
        return
    try:
        result = subprocess.run(['aws', 's3api', 'head-object', '--bucket', latest['bucket'], '--key', latest['key'],
                                 '--output', 'json'], text=True, capture_output=True, timeout=options.timeout)
        err = result.stderr
        if result.returncode == 0:
            report.add('ingest.s3-object', 'PASS', 'The latest pointer\'s object exists in S3.')
        elif '(404)' in err or 'Not Found' in err:
            report.add('ingest.s3-object', 'FAIL', 'The latest pointer\'s object was not found in S3.',
                       'Check the ingest edge S3 (locker) bucket and region; the pointer was written but the object is missing.')
        elif '(403)' in err or 'Forbidden' in err or 'AccessDenied' in err:
            report.unknown('ingest.s3-object', 'your-aws-identity-cannot-read-the-bucket')
        elif 'credentials' in err.lower() or 'ExpiredToken' in err or 'token' in err.lower():
            report.unknown('ingest.s3-object', 'no-valid-aws-credentials-on-this-machine')
        else:
            report.unknown('ingest.s3-object', 'aws-cli-error')
    except FileNotFoundError:
        report.unknown('ingest.s3-object', 'aws-cli-not-installed')
    except subprocess.TimeoutExpired:
        report.unknown('ingest.s3-object', 'timeout')
    finally:
        latest.clear()


# Cluster reachability probe. Each attempt gets at least PROBE_FLOOR seconds (or
# --timeout when higher): with kubeconfig auth through `aws eks get-token` and a
# slow credential_process one kubectl call takes ~14s, so the old 8s cap made a
# reachable cluster look unreachable and skipped every workload check.
PROBE_FLOOR = 30
PROBE_ATTEMPTS = 2
PROBE_PAUSE = 5
PROBE_SLEEP = __import__('time').sleep
PROBE_CLOCK = __import__('time').monotonic


class DiagnosticError(Exception):
    """Only fixed category strings may be emitted from this exception."""


# (category, regex) in order, applied to lowercased stderr. The in-cluster probe
# (perl) applies the same table, so keep the regexes portable.
ERROR_RULES = (
    ('role-missing', r'role .+ does not exist'),
    ('authentication', r'password authentication failed|no password supplied|role does not exist'),
    ('database-missing', r'database[\s\S]*does not exist|does not exist[\s\S]*database'),
    ('tls', r'certificate|ssl|tls'),
    ('dns', r'could not translate host|name or service not known'),
    ('network', r'connection refused|timeout expired|could not connect|no route to host|network is unreachable'),
    ('permissions', r'permission denied|forbidden'),
)


def error_category(stderr):
    # Never return server/command error text; it can include full credentials.
    value = stderr.lower()
    for category, rule in ERROR_RULES:
        if re.search(rule, value):
            return category
    return 'command-failed'


def run(argv, timeout, *, env=None, sql=None):
    try:
        result = subprocess.run(argv, input=sql, text=True, capture_output=True,
                                timeout=timeout, env=env, shell=False)
    except FileNotFoundError:
        raise DiagnosticError('tool-missing') from None
    except subprocess.TimeoutExpired:
        raise DiagnosticError('timeout') from None
    except OSError:
        raise DiagnosticError('command-unavailable') from None
    if result.returncode:
        raise DiagnosticError(error_category(result.stderr))
    try:
        return json.loads(result.stdout)
    except ValueError:
        raise DiagnosticError('invalid-response') from None


def parse_credential(value, wrapper, expected_role):
    try:
        if wrapper:
            value = json.loads(value)[wrapper]
        if not isinstance(value, str) or any(c in value for c in ('\n', '\r', '\x00')):
            raise ValueError()
        url = urlsplit(value)
        params_list = parse_qsl(url.query, keep_blank_values=True, strict_parsing=True)
        params = dict(params_list)
        if (url.scheme not in ('postgres', 'postgresql') or not url.hostname
                or not url.username or not url.password or not url.path.startswith('/')
                or len(url.path) < 2 or url.fragment or len(params) != len(params_list)
                or set(params) - {'sslmode','sslrootcert','connect_timeout','application_name'}):
            raise ValueError()
        credential = {'host': url.hostname, 'port': str(url.port or 5432),
                      'user': unquote(url.username), 'password': unquote(url.password),
                      'database': unquote(url.path[1:]), 'params': params}
        if (any('\x00' in v for v in credential.values() if isinstance(v,str))
                or any('\x00' in v for v in params.values())):
            raise ValueError()
    except (ValueError, TypeError, KeyError):
        raise DiagnosticError('malformed-url-or-json') from None
    if expected_role and credential['user'] != expected_role:
        raise DiagnosticError('wrong-login')
    if not expected_role and credential['user'] in {s[3] for s in SLOTS.values()}:
        raise DiagnosticError('owner-uses-service-login')
    if params.get('sslmode') != 'verify-full':
        raise DiagnosticError('tls-verify-full-required')
    return credential


def psql(credential, sql, timeout, ca_file=None):
    # Clear inherited libpq connection overrides, including service/options.
    env = {k:v for k,v in os.environ.items() if not k.startswith('PG')}
    env.update(PGHOST=credential['host'], PGPORT=credential['port'],
               PGDATABASE=credential['database'], PGUSER=credential['user'],
               PGPASSWORD=credential['password'], PGSSLMODE='verify-full',
               PGCONNECT_TIMEOUT=str(min(timeout,10)), PGAPPNAME='agent-relay-diagnostic',
               PGOPTIONS='-c default_transaction_read_only=on -c statement_timeout=10000 -c lock_timeout=2000')
    ca = ca_file or credential['params'].get('sslrootcert')
    if ca:
        env['PGSSLROOTCERT'] = str(ca)
    # -X avoids local psqlrc code; -w never prompts; SQL arrives on stdin.
    return run(['psql','-X','-w','-q','-A','-t','-v','ON_ERROR_STOP=1'], timeout,
               env=env, sql='BEGIN READ ONLY;\n'+sql+'\nROLLBACK;\n')


class Report:
    def __init__(self):
        self.checks = []

    def add(self, name, status, detail, action=''):
        self.checks.append(dict(check=name, status=status, detail=detail, action=action))

    def test(self, name, value, detail, action=''):
        self.add(name, 'PASS' if value else 'FAIL', detail, '' if value else action)

    def unknown(self, name, category):
        self.add(name, 'UNKNOWN', category,
                 'Check access, VPN, tools and the selected target; rerun this section.')

    def result(self):
        counts = {s:sum(c['status']==s for c in self.checks) for s in ('PASS','FAIL','UNKNOWN')}
        return {'schemaVersion':1, 'generatedAt':dt.datetime.now(dt.timezone.utc).isoformat(),
                'readOnly':True, 'summary':counts, 'checks':self.checks}


def kube(options, resource, name=None, selector=False, probe=False, probe_timeout=PROBE_FLOOR):
    if not options.context:
        raise DiagnosticError('no-kube-context')
    timeout = probe_timeout if probe else options.timeout
    argv = ['kubectl','--context',options.context,'--namespace',options.namespace,
            '--request-timeout='+str(timeout)+'s','get',resource]
    if name:
        argv.append(name)
    if selector:
        argv += ['-l','app.kubernetes.io/instance='+options.release]
    return run(argv+['-o','json'],timeout+2)


def cluster_checks(options, report):
    mounted = set()  # ConfigMaps the release's pods require (optional mounts excluded)
    for resource in ('jobs','pods','deployments','persistentvolumeclaims'):
        try:
            items = kube(options,resource,selector=True)['items']
            if not items:
                report.unknown('cluster.'+resource, 'no-release-labelled-resources')
            for i,item in enumerate(items):
                name = resource+'.'+str(i+1)  # Do not echo untrusted names/messages.
                status = item.get('status',{})
                if resource == 'jobs':
                    conditions = {c['type']:c['status'] for c in status.get('conditions',[])}
                    if conditions.get('Complete') == 'True':
                        report.add(name,'PASS','Job completed.')
                    elif conditions.get('Failed') == 'True':
                        report.add(name,'FAIL','Job failed; it may predate corrected credentials.',
                                   'Correlate job age and pod exit codes with credential checks. Preserve evidence and use the approved migration recovery procedure.')
                    else:
                        report.unknown(name,'job-pending-or-running')
                elif resource == 'pods':
                    for volume in item.get('spec',{}).get('volumes',[]) or []:
                        ref = volume.get('configMap') or {}
                        cm = ref.get('name')
                        if not ref.get('optional') and isinstance(cm,str) and re.fullmatch(r'[a-z0-9][a-z0-9.-]{0,252}',cm):
                            mounted.add(cm)
                    states = status.get('initContainerStatuses',[])+status.get('containerStatuses',[])
                    for j,state in enumerate(states):
                        for origin,container in (('current',state.get('state',{})),('previous',state.get('lastState',{}))):
                            terminated = container.get('terminated',{})
                            code = terminated.get('exitCode')
                            if code and isinstance(code,int):
                                detail = 'Container exit code '+str(code)+'.'
                                if code == 65:
                                    detail += ' Relaycast uses 65 for database identity/privilege failures.'
                                report.add(name+'.container.'+str(j+1)+'.'+origin,'FAIL' if origin=='current' else 'UNKNOWN',detail,
                                           'Check database URL roles, schema owner, TEMP/CREATE and default grants; compare with the current Job status.')
                        reason = state.get('state',{}).get('waiting',{}).get('reason')
                        if reason in ('ImagePullBackOff','ErrImagePull','CreateContainerConfigError','CrashLoopBackOff'):
                            report.add(name+'.waiting.'+str(j+1),'FAIL',reason,
                                       'Check image access or referenced Secret/ConfigMap keys and database bootstrap phase.')
                    if status.get('phase') != 'Succeeded':
                        ready = any(c.get('type')=='Ready' and c.get('status')=='True' for c in status.get('conditions',[]))
                        report.test(name+'.ready',ready,'Pod readiness.', 'Inspect the current pod state; dependent services can wait for migrations or post-migration logins.')
                elif resource == 'deployments':
                    desired = item.get('spec',{}).get('replicas',1)
                    ready = status.get('readyReplicas',0)
                    current = status.get('observedGeneration',0) >= item.get('metadata',{}).get('generation',1)
                    report.test(name,current and ready >= desired,'Deployment ready replicas: '+str(ready)+'/'+str(desired)+'.','Check migration results and waiting containers.')
                else:
                    report.test(name,status.get('phase')=='Bound','Persistent volume bound.','Check StorageClass, volume provisioning and capacity.')
                resource_name = item.get('metadata',{}).get('name','')
                if re.fullmatch(r'[a-z0-9][a-z0-9.-]{0,252}',resource_name):
                    for check in report.checks:
                        if check['check']==name or check['check'].startswith(name+'.'):
                            check['resource'] = resource_name
                created = item.get('metadata',{}).get('creationTimestamp','')
                if re.fullmatch(r'[0-9TZ:.+-]{10,40}',created):
                    for check in report.checks:
                        if check['check']==name or check['check'].startswith(name+'.'):
                            check['createdAt'] = created
        except (DiagnosticError, KeyError, TypeError, AttributeError) as exc:
            report.unknown('cluster.'+resource,str(exc) if isinstance(exc,DiagnosticError) else 'invalid-response')
    if mounted:
        configmap_checks(options, report, mounted)


def configmap_checks(options, report, mounted):
    """A ConfigMap a pod mounts but nobody created keeps the pod in ContainerCreating
    (the rds-ca case). A chart-managed rds-ca (global.rdsCa) must still hold the bytes
    its pinned hash names."""
    import hashlib
    try:
        items = {i['metadata']['name']: i for i in kube(options,'configmaps')['items']}
        for n, cm in enumerate(sorted(mounted)):
            name = 'cluster.configmaps.'+str(n+1)
            if cm not in items:
                report.add(name,'FAIL','A ConfigMap the release\'s pods mount does not exist; those pods stay in ContainerCreating.',
                           'For rds-ca set global.rdsCa.bundle to the RDS region so the chart creates it (docs/self-hosted-rds-manual-setup.md 1.2); '
                           'otherwise create the ConfigMap the values name, or correct the name.')
            else:
                report.add(name,'PASS','Mounted ConfigMap exists.')
                pinned = ((items[cm].get('metadata') or {}).get('annotations') or {}).get('agentworkforce.dev/rds-ca-sha256')
                if pinned:
                    actual = hashlib.sha256(((items[cm].get('data') or {}).get('ca.crt') or '').encode()).hexdigest()
                    report.test(name+'.rds-ca-pin', actual == pinned,
                                'The chart-managed RDS CA holds the bundle its services pin.' if actual == pinned
                                else 'The chart-managed RDS CA no longer holds the bundle its services pin (it was overwritten).',
                                'Run helm upgrade with the same values; the chart rewrites the ConfigMap.')
            report.checks[-1]['resource'] = cm
            if len(report.checks) > 1 and report.checks[-2]['check'] == name:
                report.checks[-2]['resource'] = cm
    except (DiagnosticError, KeyError, TypeError, AttributeError) as exc:
        report.unknown('cluster.configmaps',str(exc) if isinstance(exc,DiagnosticError) else 'invalid-response')


def _yaml_scalar(raw):
    raw = raw.strip()
    if raw[:1] == '"':
        end = 1
        while end < len(raw):
            if raw[end] == '\\':
                end += 2
                continue
            if raw[end] == '"':
                break
            end += 1
        if end >= len(raw):
            raise DiagnosticError('manifest-unterminated-quote')
        return json.loads(raw[:end+1])
    if raw[:1] == "'":
        out, i = [], 1
        while i < len(raw):
            if raw[i] == "'":
                if raw[i+1:i+2] == "'":
                    out.append("'")
                    i += 2
                    continue
                return ''.join(out)
            out.append(raw[i])
            i += 1
        raise DiagnosticError('manifest-unterminated-quote')
    return re.split(r'\s+#', raw, 1)[0].strip()


def _parse_manifest_doc(lines):
    """Minimal parser for Kubernetes Secret manifests (no PyYAML on operator machines)."""
    kind = name = section = None
    sections = {'stringData': {}, 'data': {}}
    i = 0
    while i < len(lines):
        line = lines[i].rstrip('\n')
        i += 1
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        indent = len(line) - len(line.lstrip(' '))
        key, sep, rest = line.strip().partition(':')
        if not sep:
            continue
        if indent == 0:
            section = key
            if key == 'kind':
                kind = _yaml_scalar(rest)
            continue
        if section == 'metadata' and key == 'name' and indent == 2:
            name = _yaml_scalar(rest)
        elif section in ('stringData', 'data') and indent == 2:
            rest = rest.strip()
            if rest[:1] in ('|', '>'):
                block = []
                while i < len(lines) and (not lines[i].strip() or len(lines[i]) - len(lines[i].lstrip(' ')) > indent):
                    block.append(lines[i].strip())
                    i += 1
                value = ('\n' if rest[0] == '|' else ' ').join(block).strip()
            else:
                value = _yaml_scalar(rest)
            sections[section][key] = value
    return kind, name, sections['stringData'], sections['data']


def _secret_values(string_data, data):
    """Kubernetes semantics: decoded data first, stringData wins regardless of field order."""
    if not isinstance(string_data, dict) or not isinstance(data, dict):
        raise DiagnosticError('manifest-invalid-fields')
    if not all(isinstance(v, str) for v in list(string_data.values()) + list(data.values())):
        raise DiagnosticError('manifest-invalid-fields')
    values = {k: base64.b64decode(v, validate=True).decode() for k, v in data.items()}
    values.update(string_data)
    return values


def load_secret_manifests(paths):
    """Return {secret_name: {key: value}} from Secret manifest files or directories (YAML or kubectl JSON)."""
    files = []
    for path in paths:
        if path.is_dir():
            files += sorted(f for f in path.iterdir() if f.suffix in ('.yaml', '.yml', '.json') and f.is_file())
        elif path.is_file():
            files.append(path)
        else:
            raise DiagnosticError('manifest-path-missing')
    secrets = {}
    for f in files:
        text = f.read_text()
        if f.stat().st_mode & 0o077:
            print('warning: '+f.name+' is readable by other users; chmod 600 it after this run.', file=sys.stderr)
        docs = []
        if text.lstrip()[:1] in ('{', '['):
            obj = json.loads(text)
            items = obj.get('items', [obj]) if isinstance(obj, dict) else None
            if not isinstance(items, list) or not all(isinstance(i, dict) for i in items):
                raise DiagnosticError('manifest-invalid-fields')
            for item in items:
                metadata = item.get('metadata') or {}
                docs.append((item.get('kind'), metadata.get('name') if isinstance(metadata, dict) else None,
                             item.get('stringData') or {}, item.get('data') or {}))
        else:
            chunk = []
            for line in text.splitlines(True) + ['---\n']:
                if re.fullmatch(r'---(?:[ \t]+#.*)?', line.rstrip()):
                    if chunk:
                        docs.append(_parse_manifest_doc(chunk))
                    chunk = []
                else:
                    chunk.append(line)
        for kind, name, string_data, data in docs:
            if kind == 'Secret' and isinstance(name, str) and name:
                secrets.setdefault(name, {}).update(_secret_values(string_data, data))
    return secrets


def load_credentials(options, report):
    secrets = {}
    credentials = {}
    manifests = None
    if getattr(options, 'secret_manifests', None):
        try:
            manifests = load_secret_manifests(options.secret_manifests)
        except DiagnosticError as exc:
            manifests = exc
        except (ValueError, OSError, TypeError, AttributeError):
            manifests = DiagnosticError('manifest-unreadable')
    for slot,(secret,key,wrapper,role,group) in SLOTS.items():
        try:
            in_cluster = getattr(options, 'in_cluster_values', None)
            if in_cluster is not None:
                found = in_cluster.get((secret, key))
                if found is None:
                    raise DiagnosticError('in-cluster-no-result')
                if isinstance(found, DiagnosticError):
                    raise found
                value = found.strip()
            elif manifests is not None:
                if isinstance(manifests, DiagnosticError):
                    raise manifests
                if secret not in manifests:
                    raise DiagnosticError('manifest-secret-missing')
                if key not in manifests[secret]:
                    raise DiagnosticError('secret-key-missing')
                value = manifests[secret][key].strip()
            elif options.secret_dir:
                path = options.secret_dir/secret/key
                if not path.is_file():
                    raise DiagnosticError('credential-file-missing')
                if path.stat().st_mode & 0o077:
                    raise DiagnosticError('credential-file-permissions-require-0600')
                value = path.read_text().strip()
            else:
                if secret not in secrets:
                    try:
                        secrets[secret] = kube(options,'secret',secret).get('data',{})
                    except DiagnosticError as exc:
                        secrets[secret] = exc
                if isinstance(secrets[secret],DiagnosticError):
                    raise secrets[secret]
                if key not in secrets[secret]:
                    raise DiagnosticError('secret-key-missing')
                value = base64.b64decode(secrets[secret][key],validate=True).decode().strip()
            credentials[slot] = parse_credential(value,wrapper,role)
            expected_db = getattr(options,group+'_database')
            if expected_db and credentials[slot]['database'] != expected_db:
                del credentials[slot]
                raise DiagnosticError('wrong-database')
            report.add('credential.'+slot,'PASS','URL structure, login and TLS mode match the install contract.')
        except DiagnosticError as exc:
            report.add('credential.'+slot,'UNKNOWN' if str(exc) in ('permissions','network','timeout','tool-missing','command-failed','in-cluster-no-result') else 'FAIL',str(exc),
                       'Check the named Secret/key or local file in the credential map; use the intended service login, explicit host and custom database name.')
        except (OSError,ValueError,UnicodeError,TypeError,AttributeError):
            report.add('credential.'+slot,'FAIL','credential-unreadable','Check file permissions, encoding and JSON wrapper.')
    for group in ('control','cast','hoop'):
        members = [c for s,c in credentials.items() if SLOTS[s][4]==group]
        if members:
            targets = {(c['host'],c['port'],c['database']) for c in members}
            report.test('credential.'+group+'.same-target',len(targets)==1,'Service URLs select the same host, port and database.',
                        'Align all URLs in this database group, including the owner URL; custom database names are supported.')
    group_targets = {}
    for slot,c in credentials.items():
        group_targets.setdefault(SLOTS[slot][4],set()).add((c['host'],c['port'],c['database']))
    for left,right in (('control','cast'),('control','hoop'),('cast','hoop')):
        if left in group_targets and right in group_targets:
            report.test('credential.separate-databases.'+left+'.'+right, not (group_targets[left] & group_targets[right]),
                        'Services use separate databases.', 'Use dedicated control, Relaycast and HoopDb databases, with the custom names from the handoff.')
    return credentials


def database_checks(options, credentials, report, query=None):
    psql = query or globals()['psql']
    identities = {}
    for slot,credential in credentials.items():
        try:
            identity = psql(credential,IDENTITY_SQL,options.timeout,options.ca_file)
            identities[slot] = identity
            report.test('database.'+slot+'.identity',identity['user']==credential['user'] and identity['database']==credential['database'] and identity['login'],
                        'Authenticated login and database match the configured URL.','Check authentication mapping and actual credential source.')
            report.test('database.'+slot+'.tls',identity['tls'],'Connection uses TLS.','Check CA bundle and TLS endpoint.')
            if slot.endswith('runtime') or slot=='cast-owner':
                report.test('database.'+slot+'.restricted',identity['restricted'] and not identity['admin_membership'],
                            'Dedicated login has no administrative attributes or broad predefined role membership.',
                            'Have the DBA review role attributes and memberships; never use the admin URL for a runtime service.')
            if slot.endswith('runtime') or slot=='cast-owner':
                report.test('database.'+slot+'.no-database-owner-membership',not identity['database_owner_membership'],
                            'Login cannot assume the database owner role.', 'Have the DBA review inherited and SET-role membership paths; Relaycast migrations must own the public schema without owning the database.')
                if SLOTS[slot][4]=='hoop':
                    report.test('database.'+slot+'.sessions-usage',identity['sessions_usage'],
                                'Runtime has USAGE on the sessions schema.',
                                'The search-indexer bootstrap Job grants this after it reaches OpenSearch: check that Job and the OpenSearch URL/access.'
                                if slot=='search-runtime' else 'Check migrations and post-migration phase 2 role activation/grants.')
            if slot=='control-owner':
                report.test('control.database-owner',identity['database_owner']==identity['user'],
                            'Control database is owned by its migration login.', 'Review the control database phase 1 bootstrap and the owner URL.')
            report.add('database.'+slot+'.server-version','PASS', 'PostgreSQL server version number: '+str(identity['server_version'])+'.')
            if slot=='hoop-owner':
                owner_is_login = identity['database_owner']==identity['user']
                schema_is_login = (identity.get('schema_owners') or {}).get('sessions')==identity['user']
                report.add('hoop.owner-layout','PASS' if owner_is_login and schema_is_login else 'UNKNOWN',
                           'Database owned by migration login: '+str(owner_is_login)+'; membership in database owner: '+str(identity['database_owner_membership'])+'; sessions schema owned by migration login: '+str(schema_is_login)+'.',
                           '' if owner_is_login and schema_is_login else 'Compare the database and sessions schema owners with the release bootstrap/upgrade contract; do not change ownership from this report alone.')
            if slot=='cast-owner':
                for role in ('relaycast_owner','relaycast_runtime'):
                    report.test('cast.role.'+role,role in identity['roles'],'Required Relaycast role exists.', 'Run the reviewed phase 1 database bootstrap against the intended database.')
                if 'relaycast_runtime' not in identity['roles']:
                    continue
                cast = psql(credential,CAST_SQL,options.timeout,options.ca_file)
                for check,value in cast.items():
                    if check=='objects':
                        report.add('cast.objects','PASS' if value else 'UNKNOWN','Application schema object count: '+str(value)+'.',
                                   '' if value else 'No migrated objects were found; inspect the migration Job. This does not prove migration completion.')
                    else:
                        ok = value==0 if check in ('wrong_owners','missing_table_grants','missing_sequence_grants') else value is True
                        report.test('cast.'+check,ok,'Relaycast catalog check: '+check+(' (count '+str(value)+')' if type(value) is int else '')+'.',
                                    'Review the Relaycast database bootstrap in phase 1: schema owner, owner TEMP, runtime isolation, current grants and owner default privileges. No repair was attempted.')
            if slot=='hoop-owner':
                for check,value in psql(credential,HOOP_SQL,options.timeout,options.ca_file).items():
                    report.test('hoop.'+check,value is True,'HoopDb prerequisite: '+check+'.','Check phase 1 extensions and migration completion before phase 2 login activation.')
                ingest_checks(options,credential,report,query)
        except (DiagnosticError,KeyError,TypeError,AttributeError) as exc:
            category = str(exc) if isinstance(exc,DiagnosticError) else 'invalid-response'
            if category in ('authentication','role-missing','database-missing'):
                report.add('database.'+slot,'FAIL',category,'Check the configured login/password/database and the phase 1/phase 2 bootstrap; no credentials were changed.')
            else:
                report.unknown('database.'+slot,category)
    for group in ('control','cast','hoop'):
        targets = [json.dumps(v['target']) for s,v in identities.items() if SLOTS[s][4]==group]
        if len(targets)>1:
            report.test('database.'+group+'.same-target',len(set(targets))==1,
                        'Connected services see the same server endpoint and database OID.',
                        'Check owner/runtime URLs and database routing.')
    missing = set(SLOTS)-set(credentials)
    for slot in sorted(missing):
        report.unknown('database.'+slot,'credential-not-available')



# EKS Pod Identity. Which AWS access each chart ServiceAccount needs, keyed by the
# name after "<release>-". A workload needs an association when its env reads S3
# (LOCKER_BUCKET with no static LOCKER_ACCESS_KEY_ID) or signs OpenSearch requests
# (SEARCH_INDEX_OPENSEARCH_AUTH=sigv4); this table only sets the access level.
POD_IDENTITY_ACCESS = {
    'worker': ('s3-rw',),
    'alleyoop': ('s3-rw',),
    'session-ingest-api': ('s3-rw',),
    'search-indexer': ('s3-r', 'os-w'),
    'session-read': ('s3-r', 'os-r'),
}
ACCESS_LABEL = {'s3-rw': 'S3 read/write', 's3-r': 'S3 read', 's3-sweep': 'S3 re-arm sweep (list and delete object versions)',
                'os-w': 'OpenSearch write', 'os-r': 'OpenSearch read'}
# (IAM actions, resource kind) simulated per access level.
ACCESS_ACTIONS = {
    's3-r': ((('s3:GetObject',), 'object'), (('s3:ListBucket',), 'bucket')),
    's3-rw': ((('s3:GetObject', 's3:PutObject', 's3:DeleteObject'), 'object'), (('s3:ListBucket',), 'bucket')),
    's3-sweep': ((('s3:GetObject', 's3:DeleteObjectVersion'), 'object'), (('s3:ListBucketVersions',), 'bucket')),
    # The reader and indexer action sets of terraform/modules/aws/search.
    'os-r': ((('es:ESHttpGet', 'es:ESHttpHead', 'es:ESHttpPost'), 'domain'),),
    'os-w': ((('es:ESHttpGet', 'es:ESHttpHead', 'es:ESHttpPost', 'es:ESHttpPut', 'es:ESHttpDelete', 'es:ESHttpPatch'), 'domain'),),
}
# The default Terraform gives these one shared sessions role. With direct uploads
# the ingest edge is the upload consumer and must keep its own role.
SESSIONS_ROLE_FAMILY = ('worker', 'alleyoop', 'session-ingest-api')
NAME_RE = r'[a-z0-9]([-a-z0-9]*[a-z0-9])?'
ROLE_ARN_RE = r'arn:aws(?:-[a-z]+)*:iam::\d{12}:role/[A-Za-z0-9+=,.@_/-]{1,512}'
REGION_RE = r'[a-z]{2}(?:-gov|-iso[a-z]*)?-[a-z]+-\d'


def aws_json(options, argv):
    """Run an aws CLI read command; raise DiagnosticError with a fixed category."""
    env = dict(os.environ)
    if getattr(options, 'aws_profile', None):
        # The profile the kube context authenticates with (or --aws-profile), so the
        # AWS checks look at the same account as the workloads.
        env['AWS_PROFILE'] = options.aws_profile
        env.pop('AWS_ACCESS_KEY_ID', None), env.pop('AWS_SECRET_ACCESS_KEY', None), env.pop('AWS_SESSION_TOKEN', None)
    try:
        result = subprocess.run(['aws']+argv+['--output', 'json'], text=True, capture_output=True,
                                timeout=options.timeout, env=env, shell=False)
    except FileNotFoundError:
        raise DiagnosticError('aws-cli-not-installed') from None
    except subprocess.TimeoutExpired:
        raise DiagnosticError('timeout') from None
    except OSError:
        raise DiagnosticError('command-unavailable') from None
    if result.returncode:
        err = result.stderr
        if 'AccessDenied' in err or 'not authorized' in err or 'UnauthorizedOperation' in err:
            raise DiagnosticError('aws-access-denied')
        if 'ResourceNotFoundException' in err or 'NoSuchEntity' in err:
            raise DiagnosticError('aws-resource-not-found')
        if ('credentials' in err.lower() or 'ExpiredToken' in err or 'InvalidClientTokenId' in err
                or 'token' in err.lower() or 'SSO' in err):
            raise DiagnosticError('no-valid-aws-credentials')
        raise DiagnosticError('aws-cli-error')
    try:
        return json.loads(result.stdout or '{}')
    except ValueError:
        raise DiagnosticError('invalid-response') from None


def eks_target(options):
    """(cluster name, region) from --eks-cluster/--aws-region, else the kube context.
    aws eks update-kubeconfig names the cluster by its ARN and passes --cluster-name
    and --region (and sometimes AWS_PROFILE) to its exec credential plugin."""
    name, region = getattr(options, 'eks_cluster', None), getattr(options, 'aws_region', None)
    eks = bool(name and region)
    if options.context:
        try:
            out = subprocess.run(['kubectl', 'config', 'view', '--minify', '--context', options.context, '-o', 'json'],
                                 text=True, capture_output=True, timeout=10)
            config = json.loads(out.stdout) if out.returncode == 0 else {}
        except (OSError, subprocess.TimeoutExpired, ValueError):
            config = {}
        clusters = [c.get('name', '') for c in config.get('clusters') or [] if isinstance(c, dict)]
        for c in clusters:
            m = re.fullmatch(r'arn:aws(?:-[a-z]+)*:eks:('+REGION_RE+r'):\d{12}:cluster/([A-Za-z0-9][A-Za-z0-9_-]{0,99})', c)
            if m:
                region, name, eks = region or m.group(1), name or m.group(2), True
        for user in config.get('users') or []:
            ex = ((user or {}).get('user') or {}).get('exec') or {}
            args = [a for a in ex.get('args') or [] if isinstance(a, str)]
            eks = eks or ('eks' in args and 'get-token' in args)
            for flag in ('--cluster-name', '--region'):
                if flag in args[:-1]:
                    value = args[args.index(flag)+1]
                    if flag == '--cluster-name' and not name and re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_-]{0,99}', value):
                        name = value
                    if flag == '--region' and not region and re.fullmatch(REGION_RE, value):
                        region = value
            for item in ex.get('env') or []:
                if isinstance(item, dict) and item.get('name') == 'AWS_PROFILE' and not getattr(options, 'aws_profile', None):
                    value = str(item.get('value') or '')
                    if re.fullmatch(r'[A-Za-z0-9_.@+-]{1,64}', value):
                        options.aws_profile = value
    return (name, region) if eks else (None, None)


def release_service_accounts(options):
    """{serviceAccount: {'needs': set of access levels, 'bucket': str, 'opensearch': str, 'workloads': [names]}}
    for the release's workloads that read S3 or sign OpenSearch requests."""
    found = {}
    for resource in ('deployments', 'statefulsets', 'jobs', 'cronjobs'):
        for item in kube(options, resource, selector=True).get('items', []):
            spec = item.get('spec') or {}
            template = spec.get('template') or (((spec.get('jobTemplate') or {}).get('spec') or {}).get('template')) or {}
            pod = template.get('spec') or {}
            sa = pod.get('serviceAccountName') or pod.get('serviceAccount') or 'default'
            env = {}
            for c in (pod.get('containers') or []) + (pod.get('initContainers') or []):
                for e in c.get('env') or []:
                    if isinstance(e, dict) and isinstance(e.get('name'), str):
                        env[e['name']] = e.get('value') if isinstance(e.get('value'), str) else env.get(e['name'], '')
            needs = set()
            if env.get('LOCKER_BUCKET') and 'LOCKER_ACCESS_KEY_ID' not in env and (env.get('LOCKER_PROVIDER') or 's3') == 's3':
                needs.add('s3')
            if (env.get('INGEST_REARM_CREDENTIALS') or '').lower() == 'podidentity' and env.get('INGEST_REARM_BUCKET'):
                needs.add('s3-sweep')
                env.setdefault('LOCKER_BUCKET', env['INGEST_REARM_BUCKET'])
            if (env.get('HISTORY_UPLOAD_DIRECT') or 'off').lower() not in ('', 'off', 'false', '0', 'no'):
                options.direct_uploads = True
            if (env.get('SEARCH_INDEX_OPENSEARCH_AUTH') or '').lower() == 'sigv4':
                needs.add('os')
            if not needs or not re.fullmatch(NAME_RE, sa):
                continue
            entry = found.setdefault(sa, {'needs': set(), 'bucket': '', 'opensearch': '', 'workloads': []})
            entry['needs'] |= needs
            if re.fullmatch(r'[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]', env.get('LOCKER_BUCKET') or ''):
                entry['bucket'] = env['LOCKER_BUCKET']
            if re.fullmatch(r'https://[a-z0-9.-]+\.(?:es|aoss)\.amazonaws\.com/?', env.get('SEARCH_INDEX_OPENSEARCH_URL') or ''):
                entry['opensearch'] = env['SEARCH_INDEX_OPENSEARCH_URL']
            workload = (item.get('metadata') or {}).get('name', '')
            if re.fullmatch(r'[a-z0-9][a-z0-9.-]{0,252}', workload):
                entry['workloads'].append((resource, workload))
    for sa, entry in found.items():
        known = POD_IDENTITY_ACCESS.get(sa[len(options.release)+1:] if sa.startswith(options.release+'-') else '') or ()
        # The usual levels for this ServiceAccount, kept only where the workload uses that service.
        levels = {l for l in known if ('os' if l.startswith('os-') else 's3') in entry['needs']}
        if 'os' in entry['needs'] and not any(l.startswith('os-') for l in levels):
            levels.add('os-w')
        if 's3' in entry['needs'] and not any(l in ('s3-r', 's3-rw') for l in levels):
            levels.add('s3-rw')
        if 's3-sweep' in entry['needs']:
            levels.add('s3-sweep')
        entry['access'] = sorted(levels, key=list(ACCESS_LABEL).index)
    return found


def _access_text(levels):
    return ', '.join(ACCESS_LABEL[l] for l in levels)


def simulate_access(options, role_arn, entry, region, report, name):
    """Stretch check: does the role's IAM policy allow the S3/OpenSearch actions it needs?
    Identity policies only (not bucket/KMS resource policies or the OpenSearch role mapping)."""
    partition = role_arn.split(':')[1]
    account = role_arn.split(':')[4]
    domain = ''
    m = re.match(r'https://(?:vpc|search)-([a-z][a-z0-9-]{2,27})-[a-z0-9]{26}\.('+REGION_RE+r')\.es\.', entry.get('opensearch') or '')
    if m:
        domain, region = m.group(1), m.group(2)
    results = []
    for level in entry['access']:
        for actions, kind in ACCESS_ACTIONS[level]:
            if kind in ('object', 'bucket') and not entry.get('bucket'):
                results.append((level, None))
                continue
            if kind == 'domain' and not (domain and region):
                results.append((level, None))
                continue
            resource = {'object': 'arn:'+partition+':s3:::'+entry.get('bucket', '')+'/*',
                        'bucket': 'arn:'+partition+':s3:::'+entry.get('bucket', ''),
                        'domain': 'arn:'+partition+':es:'+str(region)+':'+account+':domain/'+domain+'/*'}[kind]
            try:
                data = aws_json(options, ['iam', 'simulate-principal-policy', '--policy-source-arn', role_arn,
                                          '--action-names', *actions, '--resource-arns', resource])
                decisions = [r.get('EvalDecision') for r in data.get('EvaluationResults') or []]
                results.append((level, bool(decisions) and all(d == 'allowed' for d in decisions)))
            except DiagnosticError as exc:
                results.append((level, str(exc)))
    for level in entry['access']:
        outcomes = [r for l, r in results if l == level]
        check = name+'.'+level
        if any(isinstance(r, str) for r in outcomes) or any(r is None for r in outcomes):
            reason = next((r for r in outcomes if isinstance(r, str)), None) or \
                ('bucket-unknown' if level.startswith('s3') else 'opensearch-domain-unknown')
            report.add(check, 'UNKNOWN', ACCESS_LABEL[level]+': not simulated ('+reason+').',
                       'Run with an identity allowed iam:SimulatePrincipalPolicy, or check the role\'s policy by hand.')
        else:
            report.test(check, all(outcomes), ACCESS_LABEL[level]+': the role\'s IAM policy '+('allows' if all(outcomes) else 'does not allow')+' it.',
                        'Grant the role '+ACCESS_LABEL[level]+(' on bucket '+entry['bucket'] if level.startswith('s3') else ' on OpenSearch domain '+domain)+'.')
        report.checks[-1]['resource'] = name.split('.', 1)[1]


def pod_identity_checks(options, report):
    """Every ServiceAccount the release's workloads use for S3 or OpenSearch has an
    EKS Pod Identity association; optionally, its role's IAM policy allows that access."""
    try:
        accounts = release_service_accounts(options)
    except (DiagnosticError, KeyError, TypeError, AttributeError) as exc:
        report.unknown('podidentity', str(exc) if isinstance(exc, DiagnosticError) else 'invalid-response')
        return
    cluster, region = eks_target(options)
    if not (cluster and region):
        if getattr(options, 'only', None) == 'pod-identity' and accounts:
            report.add('podidentity', 'UNKNOWN', 'Not an EKS kube context (or the cluster name and region are not in it): '
                       'Pod Identity not checked for '+', '.join(sorted(accounts))+'.',
                       'On EKS, pass --eks-cluster <name> --aws-region <region>, or check by hand: aws eks list-pod-identity-associations '
                       '--cluster-name <cluster> --region <region> --namespace '+options.namespace)
        return  # Not an EKS context (GKE, AKS, kind): nothing to check. --eks-cluster/--aws-region force it.
    if not accounts:
        return  # No workload reads S3 or signs OpenSearch requests (GCS, static keys).
    import shlex
    base = ['--cluster-name', cluster, '--region', region]
    profile = (' --profile '+shlex.quote(options.aws_profile)) if getattr(options, 'aws_profile', None) else ''
    def create_line(sa, role):
        return ('aws eks create-pod-identity-association'+profile+' --cluster-name '+cluster+' --region '+region+' --namespace '
                +options.namespace+' --service-account '+sa+' --role-arn '+role)
    try:
        listed = aws_json(options, ['eks', 'list-pod-identity-associations', *base, '--namespace', options.namespace])
        associations = {}
        for a in listed.get('associations') or []:
            sa, aid = a.get('serviceAccount', ''), a.get('associationId', '')
            if re.fullmatch(NAME_RE, sa) and re.fullmatch(r'a-[a-z0-9]{8,64}', aid):
                associations[sa] = aid
    except DiagnosticError as exc:
        for sa, entry in sorted(accounts.items()):
            report.add('podidentity.'+sa, 'UNKNOWN', 'Needs '+_access_text(entry['access'])+'; associations not listed ('+str(exc)+').',
                       'With AWS credentials for the cluster account, run: aws eks list-pod-identity-associations'+profile
                       +' --cluster-name '+cluster+' --region '+region+' --namespace '+options.namespace)
            report.checks[-1]['resource'] = sa
        return
    roles, unreadable = {}, {}
    for sa, aid in associations.items():
        try:
            described = aws_json(options, ['eks', 'describe-pod-identity-association', *base, '--association-id', aid])
            role = (described.get('association') or {}).get('roleArn', '')
            if re.fullmatch(ROLE_ARN_RE, role):
                roles[sa] = role
            else:
                unreadable[sa] = 'invalid-response'
        except DiagnosticError as exc:
            unreadable[sa] = str(exc)
    short = lambda sa: sa[len(options.release)+1:] if sa.startswith(options.release+'-') else ''
    direct = getattr(options, 'direct_uploads', False)
    def suggested_role(sa, entry):
        """The role of a ServiceAccount that, in the reference Terraform, shares this one's role.
        With direct uploads the ingest edge is the upload consumer: never share its role."""
        family = SESSIONS_ROLE_FAMILY if short(sa) in SESSIONS_ROLE_FAMILY else ()
        if direct:
            family = () if short(sa) == 'session-ingest-api' else tuple(f for f in family if f != 'session-ingest-api')
        for donor in family:
            if options.release+'-'+donor in roles and donor != short(sa):
                return roles[options.release+'-'+donor]
        own = ' (its own upload-consumer role: direct uploads are on)' if direct and short(sa) == 'session-ingest-api' else ''
        return '<ARN of a role with '+_access_text(entry['access'])+own+'>'
    for sa, entry in sorted(accounts.items()):
        name = 'podidentity.'+sa
        if sa in associations:
            role = roles.get(sa)
            report.add(name, 'PASS', 'Pod Identity association exists'+(' (role '+role+')' if role else '')+'; needs '+_access_text(entry['access'])+'.')
            report.checks[-1]['resource'] = sa
            if getattr(options, 'no_iam_simulate', False):
                continue
            if role:
                simulate_access(options, role, entry, region, report, name)
            else:
                for level in entry['access']:
                    report.add(name+'.'+level, 'UNKNOWN', ACCESS_LABEL[level]+': not simulated (role not readable: '+unreadable.get(sa, 'unknown')+').',
                               'Allow eks:DescribePodIdentityAssociation, or check the role\'s policy by hand.')
                    report.checks[-1]['resource'] = sa
        elif sa in getattr(options, 'create_pod_identity', {}):
            role = options.create_pod_identity[sa]
            deployments = sorted(n for r, n in entry['workloads'] if r == 'deployments')
            try:
                aws_json(options, ['eks', 'create-pod-identity-association', *base, '--namespace', options.namespace,
                                   '--service-account', sa, '--role-arn', role])
                options.created_associations.append({'serviceAccount': sa, 'roleArn': role, 'deployments': deployments})
                report.add(name, 'PASS', 'Pod Identity association created for '+sa+' (role '+role+'); its pods need a restart: '
                           +(', '.join(deployments) or 'none running')+'.')
            except DiagnosticError as exc:
                report.add(name, 'FAIL', 'Could not create the Pod Identity association for '+sa+' ('+str(exc)+').',
                           create_line(sa, role)+'   (needs eks:CreatePodIdentityAssociation and iam:PassRole on the role)')
            report.checks[-1]['resource'] = sa
        else:
            workloads = ', '.join(n for _, n in entry['workloads'][:4])
            deployments = ' '.join('deployment/'+n for r, n in entry['workloads'] if r == 'deployments')
            report.add(name, 'FAIL', 'No Pod Identity association for ServiceAccount '+sa+' (used by '+workloads+'), which needs '
                       +_access_text(entry['access'])+'. Its pods get no AWS credentials.',
                       create_line(sa, suggested_role(sa, entry))
                       +('  then restart its pods: kubectl --context '+shlex.quote(options.context)+' -n '+options.namespace
                         +' rollout restart '+deployments if deployments else ''))
            report.checks[-1]['resource'] = sa
    unused = sorted(sa for sa in associations if sa not in accounts and sa.startswith(options.release+'-'))
    if unused:
        report.add('podidentity.unused', 'PASS', 'Associations no workload of this release uses (harmless; remove if unwanted): '+', '.join(unused)+'.')


# In-cluster database checks. When the operator machine can't reach the database
# (split VPN), the same read-only catalog SQL runs from a short-lived Job in the
# release namespace. The Job mounts only the credential keys of the release's own
# Secrets and the rds-ca ConfigMap, runs psql from the pinned PostgreSQL client
# image that rds-setup.sh and configure-rds.sh use, and prints one line per
# result: the credential value with its password replaced, then each query's JSON
# or a fixed error category. Raw errors, passwords and object keys never reach the
# log. The operator needs only create/get/delete on Jobs and get on Pods and logs.
PSQL_IMAGE = 'ghcr.io/cloudnative-pg/postgresql:17-standard-trixie@sha256:ed6923f9ba2399cf9070379a353c710c29ced8a294be73986a2c3dae7e599ce3'
# The ingest query without the latest object's bucket/key (they would reach the log).
INGEST_SQL_IN_CLUSTER = INGEST_SQL.replace(""",
 'latest', (SELECT json_build_object('bucket',bucket,'key',manifest_key) FROM sessions.session_index
            WHERE bucket IS NOT NULL AND manifest_key IS NOT NULL AND deleted_at IS NULL ORDER BY created_at DESC LIMIT 1)""", '')
IN_CLUSTER_QUERIES = {'identity': IDENTITY_SQL, 'cast': CAST_SQL, 'hoop': HOOP_SQL,
                      'ingest-table': INGEST_TABLE_SQL, 'ingest': INGEST_SQL_IN_CLUSTER}
QUERY_NAMES = {IDENTITY_SQL: 'identity', CAST_SQL: 'cast', HOOP_SQL: 'hoop',
               INGEST_TABLE_SQL: 'ingest-table', INGEST_SQL: 'ingest'}
SLOT_QUERIES = {'cast-owner': ('identity', 'cast'), 'hoop-owner': ('identity', 'hoop', 'ingest-table', 'ingest')}

PROBE = r"""
use strict; use warnings; use MIME::Base64 qw(encode_base64); use JSON::PP qw(decode_json);
my @rules = map { [split /\t/, $_, 2] } grep { length } split /\n/, $ENV{AR_RULES};
sub category { my $e = lc(shift // ''); for my $r (@rules) { return $r->[0] if $e =~ /$r->[1]/ } 'command-failed' }
sub out { print join("\t", 'AR', @_), "\n" }
sub dec { my $v = shift; $v =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge; $v }
sub slurp { my $f = shift; open(my $h, '<', $f) or return undef; local $/; my $v = <$h>; close $h; $v }
sub b64json { my $j = JSON::PP->new->canonical->utf8->encode(shift); encode_base64($j, '') }
delete $ENV{$_} for grep { /^PG/ } keys %ENV;
my ($ca) = grep { -s "/ca/$_/ca.crt" } split /,/, $ENV{AR_CA_DIRS};
out('CA', defined $ca ? $ca : 'none');
for my $line (grep { length } split /\n/, $ENV{AR_PLAN}) {
  my ($slot, $secret, $key, $wrapper, $queries) = split /\t/, $line;
  my @queries = split /,/, $queries;
  my $value = slurp("/secrets/$secret/$key");
  if (!defined $value) { out('CRED', $slot, 'ERR', 'secret-key-missing'); next }
  $value =~ s/^\s+|\s+$//g;
  my $url = $value;
  if ($wrapper ne '-') {
    my $doc = eval { decode_json($value) };
    $url = (ref($doc) eq 'HASH' && defined($doc->{$wrapper}) && !ref($doc->{$wrapper})) ? $doc->{$wrapper} : undef;
  }
  # Split like urlsplit: the netloc ends at the first / ? #, userinfo at its last @.
  my @m = defined($url) ? ($url =~ m{^([A-Za-z][A-Za-z0-9+.-]*)://([^:/?#\@]*):([^/?#]*)\@(\[[0-9A-Fa-f:.]+\]|[^\@/?#:\[\]]*)(?::([^/?#]*))?(/[^?#]*)?(?:\?([^#]*))?(#.*)?$}s) : ();
  if (!@m) { out('CRED', $slot, 'ERR', 'malformed-url-or-json'); out('Q', $slot, $_, 'ERR', 'malformed-url-or-json') for @queries; next }
  # Only the parts the URL checks need. The password, every other field of the
  # Secret value and any query parameter the install contract doesn't allow (its
  # value could be a password) stay in this process; a fixed marker stands in.
  my @q;
  for my $p (split /&/, $m[6] // '') {
    my ($k, $v) = split /=/, $p, 2;
    my $name = dec($k =~ tr/+/ /r);   # as parse_qsl decodes names
    push @q, (defined($v) && $name =~ /^(?:sslmode|sslrootcert|connect_timeout|application_name)$/) ? "$name=$v" : 'unsupported=1';
  }
  out('CRED', $slot, 'OK', b64json({scheme => $m[0], user => $m[1], host => $m[3], port => $m[4] // '',
                                     path => $m[5] // '', query => join('&', @q), fragment => defined($m[7]) ? 1 : 0,
                                     password => length($m[2]) ? 1 : 0}));
  (my $host = $m[3]) =~ s/^\[|\]$//g;
  my $port = (defined($m[4]) && length($m[4])) ? $m[4] : '5432';
  if ($port !~ /^\d{1,5}$/ || !defined($m[5]) || length($m[5]) < 2) { out('Q', $slot, $_, 'ERR', 'malformed-url-or-json') for @queries; next }
  local $ENV{PGHOST} = $host; local $ENV{PGPORT} = $port;
  local $ENV{PGUSER} = dec($m[1]); local $ENV{PGPASSWORD} = dec($m[2]); local $ENV{PGDATABASE} = dec(substr($m[5], 1));
  local $ENV{PGSSLMODE} = 'verify-full'; local $ENV{PGSSLROOTCERT} = defined $ca ? "/ca/$ca/ca.crt" : '/ca/none';
  local $ENV{PGCONNECT_TIMEOUT} = $ENV{AR_TIMEOUT}; local $ENV{PGOPTIONS} = '-c statement_timeout='.($ENV{AR_TIMEOUT} * 1000);
  local $ENV{PGAPPNAME} = 'agent-relay-diagnose';
  for my $q (@queries) {
    my $sql = $ENV{'AR_SQL_'.uc($q =~ s/-/_/gr)};
    open(my $f, '>', '/tmp/q.sql') or die; print $f "BEGIN READ ONLY;\n$sql\nROLLBACK;\n"; close $f;
    my $pid = fork() // die;
    if (!$pid) {
      open(STDIN, '<', '/tmp/q.sql'); open(STDOUT, '>', '/tmp/out'); open(STDERR, '>', '/tmp/err');
      exec('psql', '-X', '-w', '-q', '-A', '-t', '-v', 'ON_ERROR_STOP=1') or exit 127;
    }
    waitpid($pid, 0);
    my ($rc, $o) = ($? >> 8, slurp('/tmp/out') // '');
    $o =~ s/^\s+|\s+$//g;
    if ($rc == 0) { out('Q', $slot, $q, 'OK', encode_base64($o, '')) }
    else { out('Q', $slot, $q, 'ERR', $rc == 127 ? 'tool-missing' : category(slurp('/tmp/err'))) }
    unlink('/tmp/out', '/tmp/err', '/tmp/q.sql');
  }
}
out('DONE');
"""


# --- Search readiness ---------------------------------------------------------
# One signed GET from inside the cluster, as the search indexer's ServiceAccount,
# with the services image's own SigV4 signer and Pod Identity credential source.
SEARCH_PROBE = r"""
const out = (o) => console.log("AR\tOS\t" + Buffer.from(JSON.stringify(o)).toString("base64"));
const url = (process.env.AR_OS_URL || "").replace(/\/$/, ""), region = process.env.AR_OS_REGION || "";
try {
  if (!process.env.AWS_CONTAINER_CREDENTIALS_FULL_URI) out({ kind: "no-credentials" });
  else {
    const { podIdentityCredentials } = await import("/app/src/shared/locker.ts");
    const { signRequest } = await import("/app/packages/object-store/src/sigv4.ts");
    const { sha256Hex } = await import("/app/packages/object-store/src/crypto.ts");
    let creds = null;
    try { creds = await podIdentityCredentials(); } catch (e) { out({ kind: "no-credentials", detail: String(e && e.message || e).slice(0, 160) }); }
    if (creds) {
      const call = async (path) => {
        const u = new URL(url + path);
        const h = new Headers({ accept: "application/json" });
        await signRequest({ method: "GET", url: u, headers: h, payloadSha256: await sha256Hex(""), region, service: "es", credentials: creds });
        const r = await fetch(u, { headers: h, redirect: "error", signal: AbortSignal.timeout(10000) });
        return { status: r.status, body: (await r.text()).slice(0, 800) };
      };
      let who = null;
      try { const a = await call("/_plugins/_security/authinfo"); if (a.status === 200) { const j = JSON.parse(a.body); who = { user: j.user_name, backend_roles: j.backend_roles }; } } catch {}
      try { const r = await call("/_cluster/health"); out({ kind: "http", status: r.status, body: r.body, who }); }
      catch (e) { out({ kind: "network", detail: String((e && (e.code || (e.cause && e.cause.code) || e.name)) || e).slice(0, 80) }); }
    }
  }
} catch (e) { out({ kind: "error", detail: String(e && e.message || e).slice(0, 160) }); }
console.log("AR\tDONE");
"""


def search_indexer(options):
    """The release's search indexer: {sa, image, url, region, prefix, deployment} or None."""
    for item in kube(options, 'deployments', selector=True).get('items', []):
        pod = (((item.get('spec') or {}).get('template') or {}).get('spec') or {})
        for c in pod.get('containers') or []:
            env = {e.get('name'): e.get('value') for e in c.get('env') or [] if isinstance(e, dict) and isinstance(e.get('value'), str)}
            if (env.get('SEARCH_INDEX_OPENSEARCH_AUTH') or '').lower() == 'sigv4' and env.get('SEARCH_INDEX_OPENSEARCH_URL') \
               and (item.get('metadata') or {}).get('name', '').endswith('search-indexer'):
                return {'sa': pod.get('serviceAccountName') or 'default', 'image': c.get('image', ''),
                        'url': env['SEARCH_INDEX_OPENSEARCH_URL'], 'region': env.get('SEARCH_INDEX_OPENSEARCH_AWS_REGION', ''),
                        'prefix': env.get('SEARCH_INDEX_OPENSEARCH_INDEX_PREFIX') or 'relayhistory',
                        'deployment': (item.get('metadata') or {}).get('name', '')}
    return None


def search_probe_job(options, name, target=None):
    target = target or options.search_target
    labels = {'app.kubernetes.io/name': 'agent-relay-diagnose', 'app.kubernetes.io/part-of': 'agent-relay-support'}
    return {
        'apiVersion': 'batch/v1', 'kind': 'Job',
        'metadata': {'name': name, 'namespace': options.namespace, 'labels': labels},
        'spec': {'backoffLimit': 0, 'activeDeadlineSeconds': 120, 'ttlSecondsAfterFinished': 600,
                 'template': {'metadata': {'labels': labels}, 'spec': {
                     # The indexer's own ServiceAccount: its Pod Identity association, its credentials.
                     'serviceAccountName': target['sa'], 'restartPolicy': 'Never', 'enableServiceLinks': False,
                     'securityContext': {'runAsNonRoot': True, 'runAsUser': 1000, 'runAsGroup': 1000,
                                         'seccompProfile': {'type': 'RuntimeDefault'}},
                     'volumes': [{'name': 'tmp', 'emptyDir': {'medium': 'Memory', 'sizeLimit': '16Mi'}}],
                     'containers': [{
                         'name': 'probe', 'image': target['image'], 'command': ['bun', '-e', SEARCH_PROBE],
                         'env': [{'name': 'AR_OS_URL', 'value': target['url']}, {'name': 'AR_OS_REGION', 'value': target['region']},
                                 {'name': 'HOME', 'value': '/tmp'}],
                         'volumeMounts': [{'name': 'tmp', 'mountPath': '/tmp'}],
                         'resources': {'requests': {'cpu': '50m', 'memory': '96Mi'}, 'limits': {'memory': '256Mi'}},
                         'securityContext': {'allowPrivilegeEscalation': False, 'readOnlyRootFilesystem': True,
                                             'capabilities': {'drop': ['ALL']}},
                     }]}}}}


def parse_search_probe(text):
    result, done = None, False
    for line in text.splitlines():
        parts = line.split('\t')
        if parts[:2] == ['AR', 'DONE']:
            done = True
        elif len(parts) == 3 and parts[:2] == ['AR', 'OS']:
            try:
                result = json.loads(base64.b64decode(parts[2], validate=True).decode())
            except (ValueError, UnicodeError):
                result = {'kind': 'error', 'detail': 'invalid-response'}
    if not done or not isinstance(result, dict):
        raise DiagnosticError('in-cluster-output-incomplete')
    return result


def iam_role_forms(role_arn='', assumed=''):
    """The IAM role ARN with its path and without it; OpenSearch FGAC matches the
    backend role exactly, and which form arrives depends on the domain's version."""
    forms = []
    m = re.fullmatch(r'arn:(aws[a-z-]*):sts::(\d{12}):assumed-role/([A-Za-z0-9+=,.@_-]{1,64})/[^/]+', assumed or '')
    if re.fullmatch(ROLE_ARN_RE, role_arn or ''):
        forms.append(role_arn)
        part, acct, rest = role_arn.split(':')[1], role_arn.split(':')[4], role_arn.split(':role/', 1)[1]
        forms.append('arn:'+part+':iam::'+acct+':role/'+rest.rsplit('/', 1)[-1])
    elif m:
        forms.append('arn:'+m.group(1)+':iam::'+m.group(2)+':role/'+m.group(3))
    return list(dict.fromkeys(forms))


def classify_opensearch(result, target, role_arn=''):
    """(status, detail, action) for the signed probe's result."""
    host = re.sub(r'^https://|/.*$', '', target.get('url', ''))
    sa, prefix = target.get('sa', ''), target.get('prefix', 'relayhistory')
    kind = result.get('kind')
    if kind == 'no-credentials':
        return ('FAIL', 'The search indexer\'s ServiceAccount '+sa+' got no AWS credentials to sign OpenSearch requests.',
                'Create its EKS Pod Identity association (OpenSearch write), then restart the search indexer.')
    if kind == 'network':
        return ('FAIL', 'OpenSearch '+host+' is unreachable from the cluster ('+str(result.get('detail', ''))+').',
                'Check the OpenSearch URL (site.opensearchUrl or searchIndexer.search.opensearch.url), DNS from the cluster, '
                'and that the domain\'s security group allows TCP 443 from the cluster nodes.')
    if kind != 'http':
        return ('UNKNOWN', 'The OpenSearch probe could not run ('+str(result.get('detail') or kind)+').',
                'Rerun; if it persists, check the search indexer image.')
    status, body = result.get('status'), str(result.get('body') or '')
    who = result.get('who') or {}
    if status == 200:
        return ('PASS', 'A signed request to OpenSearch '+host+' as '+(who.get('user') or sa)+' was accepted (cluster health).', '')
    if status == 403 and re.search(r'security_exception|no permissions for', body):
        forms = iam_role_forms(role_arn, who.get('user', ''))
        roles = json.dumps(forms or ['<the search indexer role ARN>'])
        role_body = json.dumps({'cluster_permissions': ['cluster_monitor', 'indices:data/write/bulk'], 'index_permissions': [{
            'index_patterns': [prefix+'-*'], 'allowed_actions': ['write', 'create_index', 'indices:data/write/bulk*',
            'indices:monitor/settings/get', 'indices:admin/mapping/put', 'indices:data/read/search*', 'indices:data/read/scroll*',
            'indices:data/read/mget*', 'indices:data/write/delete/byquery', 'indices:admin/refresh*', 'indices:admin/get']}]},
            separators=(',', ':'))
        return ('FAIL', 'OpenSearch '+host+' refused the search indexer (403 from fine-grained access control): its role is not mapped'
                +(' (it arrived as '+who['user']+')' if who.get('user') else '')+'.',
                'As the OpenSearch admin (install guide step 7, opensearch-roles-via-cluster.sh), run: '
                'PUT _plugins/_security/api/roles/relayhistory_indexer '+role_body+'  and  '
                'PUT _plugins/_security/api/rolesmapping/relayhistory_indexer {"backend_roles":'+roles+'}'
                '  (both forms: with and without the role\'s IAM path; PUT replaces the mapping, so include any backend roles it already has).')
    if status == 403:
        return ('FAIL', 'OpenSearch '+host+' refused the search indexer (403 from the domain access policy'
                +(': '+re.sub(r'\s+', ' ', body)[:160] if body else '')+').',
                'Allow es:ESHttp* on the domain for the search indexer role in the domain\'s access policy '
                '(or leave the policy open to the account and rely on fine-grained access control).')
    if status == 401:
        return ('FAIL', 'OpenSearch '+host+' rejected the signature (401).',
                'Check searchIndexer.search.opensearch.region matches the domain\'s region.')
    return ('FAIL', 'OpenSearch '+host+' answered HTTP '+str(status)+' to a signed request.', 'Check the domain\'s health in the AWS console.')


def search_checks(options, report):
    """Search readiness: the bootstrap Job, then one signed OpenSearch request from inside the cluster."""
    try:
        jobs = kube(options, 'jobs', selector=True).get('items', [])
    except DiagnosticError as exc:
        report.unknown('search.bootstrap', str(exc))
        jobs = []
    boots = sorted((j for j in jobs if 'search-indexer-bootstrap' in (j.get('metadata') or {}).get('name', '')),
                   key=lambda j: (j.get('metadata') or {}).get('creationTimestamp', ''))
    if boots:
        job = boots[-1]
        name = job['metadata']['name']
        conditions = {c.get('type'): c.get('status') for c in (job.get('status') or {}).get('conditions', [])}
        if conditions.get('Complete') == 'True':
            report.add('search.bootstrap', 'PASS', 'The search bootstrap Job completed.')
        elif conditions.get('Failed') == 'True':
            cause = ''
            try:
                for pod in kube(options, 'pods', selector=True).get('items', []):
                    if (pod.get('metadata') or {}).get('labels', {}).get('job-name') == name:
                        for st in (pod.get('status') or {}).get('containerStatuses') or []:
                            cause = cause or ((st.get('state') or {}).get('terminated') or {}).get('message', '')
            except DiagnosticError:
                pass
            cause = re.sub(r'postgres(?:ql)?://\S+', '<url>', cause.strip().split('\n')[0])[:300]
            if not cause or not cause.startswith('search bootstrap failed'):
                cause = 'search bootstrap failed'+(': '+cause if cause else '')
            if re.search(r'permission denied|not permitted to log in|search_consumer_runtime', cause):
                fix = 'Run rds-setup.sh post (configure-rds.sh does), then '
            else:
                fix = 'Fix the cause, then '
            report.add('search.bootstrap', 'FAIL', cause+' (Job '+name+').',
                       fix+'kubectl -n '+options.namespace+' delete job '+name+' and helm upgrade again; log: kubectl -n '
                       +options.namespace+' logs job/'+name)
        else:
            report.unknown('search.bootstrap', 'job-pending-or-running')
        report.checks[-1]['resource'] = name
    try:
        target = search_indexer(options)
    except DiagnosticError as exc:
        report.unknown('search.opensearch', str(exc))
        return
    if not target:
        return  # No SigV4 OpenSearch indexer in this release.
    options.search_target = target
    role = ''
    try:
        cluster, region = eks_target(options)
        if cluster and region:
            listed = aws_json(options, ['eks', 'list-pod-identity-associations', '--cluster-name', cluster, '--region', region,
                                        '--namespace', options.namespace, '--service-account', target['sa']])
            for a in listed.get('associations') or []:
                d = aws_json(options, ['eks', 'describe-pod-identity-association', '--cluster-name', cluster, '--region', region,
                                       '--association-id', a.get('associationId', '')])
                role = (d.get('association') or {}).get('roleArn', '') or role
    except DiagnosticError:
        role = ''
    try:
        result = run_in_cluster(options, build=search_probe_job, parse=parse_search_probe, kind='os')
    except DiagnosticError as exc:
        report.add('search.opensearch', 'UNKNOWN', 'The in-cluster OpenSearch probe did not finish ('+str(exc)+').',
                   'Check that this identity can create Jobs in '+options.namespace+' and that the nodes can pull '
                   +target['image'].split('@')[0]+'.')
        return
    status, detail, action = classify_opensearch(result, target, role)
    report.add('search.opensearch', status, detail, action)
    report.checks[-1]['resource'] = target['deployment']


def kubectl_text(options, args, stdin=None, timeout=None):
    argv = ['kubectl', '--context', options.context, '--namespace', options.namespace,
            '--request-timeout='+str(options.timeout)+'s'] + args
    try:
        result = subprocess.run(argv, input=stdin, text=True, capture_output=True,
                                timeout=timeout or options.timeout+5, shell=False)
    except FileNotFoundError:
        raise DiagnosticError('tool-missing') from None
    except subprocess.TimeoutExpired:
        raise DiagnosticError('timeout') from None
    except OSError:
        raise DiagnosticError('command-unavailable') from None
    if result.returncode:
        raise DiagnosticError(error_category(result.stderr))
    return result.stdout


def ca_configmaps(options):
    """--ca-configmap, else the CA rds-setup.sh/the chart (rds-ca) or cloud-sql-setup.sh (cloud-sql-ca) creates."""
    return [options.ca_configmap] if getattr(options, 'ca_configmap', None) else ['rds-ca', 'cloud-sql-ca']


def credential_url(parts, wrapper):
    """The Secret value rebuilt from the probe's URL parts, password replaced, for parse_credential."""
    if not isinstance(parts, dict) or not all(isinstance(parts.get(k), str) for k in ('scheme', 'user', 'host', 'port', 'path', 'query')):
        raise ValueError()
    password = 'redacted' if parts.get('password', 1) else ''   # an empty password stays empty: still malformed
    value = (parts['scheme']+'://'+parts['user']+':'+password+'@'+parts['host']+(':'+parts['port'] if parts['port'] else '')
             +parts['path']+('?'+parts['query'] if parts['query'] else '')+('#fragment' if parts.get('fragment') else ''))
    return json.dumps({wrapper: value}) if wrapper else value


def in_cluster_job(options, name):
    """The Job manifest: read-only, no ServiceAccount token, only the credential keys."""
    plan, volumes, mounts, by_secret = [], [], [], {}
    for slot, (secret, key, wrapper, _role, _group) in SLOTS.items():
        plan.append('\t'.join((slot, secret, key, wrapper or '-', ','.join(SLOT_QUERIES.get(slot, ('identity',))))))
        by_secret.setdefault(secret, [])
        if key not in by_secret[secret]:
            by_secret[secret].append(key)
    for i, (secret, keys) in enumerate(sorted(by_secret.items())):
        volumes.append({'name': 's'+str(i), 'secret': {'secretName': secret, 'optional': True, 'defaultMode': 0o440,
                                                      'items': [{'key': k, 'path': k} for k in keys]}})
        mounts.append({'name': 's'+str(i), 'mountPath': '/secrets/'+secret, 'readOnly': True})
    for i, configmap in enumerate(ca_configmaps(options)):
        volumes.append({'name': 'ca'+str(i), 'configMap': {'name': configmap, 'optional': True,
                                                          'items': [{'key': 'ca.crt', 'path': 'ca.crt'}]}})
        mounts.append({'name': 'ca'+str(i), 'mountPath': '/ca/'+str(i), 'readOnly': True})
    volumes.append({'name': 'tmp', 'emptyDir': {'medium': 'Memory', 'sizeLimit': '16Mi'}})
    mounts.append({'name': 'tmp', 'mountPath': '/tmp'})
    env = [{'name': 'AR_PLAN', 'value': '\n'.join(plan)},
           {'name': 'AR_RULES', 'value': '\n'.join(c+'\t'+r for c, r in ERROR_RULES)},
           {'name': 'AR_TIMEOUT', 'value': str(options.timeout)}, {'name': 'HOME', 'value': '/tmp'},
           {'name': 'AR_CA_DIRS', 'value': ','.join(str(i) for i in range(len(ca_configmaps(options))))}]
    env += [{'name': 'AR_SQL_'+q.upper().replace('-', '_'), 'value': sql} for q, sql in IN_CLUSTER_QUERIES.items()]
    labels = {'app.kubernetes.io/name': 'agent-relay-diagnose', 'app.kubernetes.io/part-of': 'agent-relay-support'}
    return {
        'apiVersion': 'batch/v1', 'kind': 'Job',
        'metadata': {'name': name, 'namespace': options.namespace, 'labels': labels},
        'spec': {'backoffLimit': 0, 'activeDeadlineSeconds': options.in_cluster_deadline,
                 'ttlSecondsAfterFinished': 600,
                 'template': {'metadata': {'labels': labels}, 'spec': {
                     'restartPolicy': 'Never', 'automountServiceAccountToken': False, 'enableServiceLinks': False,
                     'securityContext': {'runAsNonRoot': True, 'runAsUser': 26, 'runAsGroup': 26, 'fsGroup': 26,
                                         'seccompProfile': {'type': 'RuntimeDefault'}},
                     'volumes': volumes,
                     'containers': [{
                         'name': 'psql', 'image': options.psql_image, 'command': ['perl', '-e', PROBE], 'env': env,
                         'volumeMounts': mounts,
                         'resources': {'requests': {'cpu': '50m', 'memory': '64Mi'}, 'limits': {'memory': '128Mi'}},
                         'securityContext': {'allowPrivilegeEscalation': False, 'readOnlyRootFilesystem': True,
                                             'capabilities': {'drop': ['ALL']}},
                     }]}}}}


def parse_probe_output(text):
    """{(secret, key): sanitized value or DiagnosticError}, {(slot, query): ('ok', obj) | ('err', category)}"""
    values, results, done = {}, {'ca': None}, False
    for line in text.splitlines():
        parts = line.split('\t')
        if parts[:1] != ['AR']:
            continue
        if parts[1:] == ['DONE']:
            done = True
        elif len(parts) == 3 and parts[1] == 'CA' and re.fullmatch(r'none|\d{1,2}', parts[2]):
            results['ca'] = parts[2]
        elif len(parts) == 5 and parts[1] == 'CRED' and parts[2] in SLOTS:
            secret, key, wrapper = SLOTS[parts[2]][:3]
            if parts[3] == 'OK':
                try:
                    values[(secret, key)] = credential_url(json.loads(base64.b64decode(parts[4], validate=True).decode()), wrapper)
                except (ValueError, UnicodeError):
                    values[(secret, key)] = DiagnosticError('invalid-response')
            elif re.fullmatch(r'[a-z-]{1,40}', parts[4]):
                values[(secret, key)] = DiagnosticError(parts[4])
        elif len(parts) == 6 and parts[1] == 'Q' and parts[2] in SLOTS and parts[3] in IN_CLUSTER_QUERIES:
            if parts[4] == 'OK':
                try:
                    results[(parts[2], parts[3])] = ('ok', json.loads(base64.b64decode(parts[5], validate=True).decode()))
                except (ValueError, UnicodeError):
                    results[(parts[2], parts[3])] = ('err', 'invalid-response')
            elif re.fullmatch(r'[a-z-]{1,40}', parts[5]):
                results[(parts[2], parts[3])] = ('err', parts[5])
    if not done:
        raise DiagnosticError('in-cluster-output-incomplete')
    return values, results


def run_in_cluster(options, build=None, parse=None, kind='db'):
    """Run a probe Job (default: the database probe), return its parsed output, and always delete the Job."""
    import secrets as _secrets
    import time
    build, parse = build or in_cluster_job, parse or parse_probe_output
    name = (options.release+'-diagnose-'+kind+'-')[:56]+_secrets.token_hex(3)
    manifest = json.dumps(build(options, name))
    options.in_cluster_job = {'name': name, 'deleted': None}
    created = False
    try:
        try:
            kubectl_text(options, ['create', '-f', '-', '-o', 'name'], stdin=manifest)
            created = True
        except DiagnosticError as exc:
            # A timeout or dropped connection may still have created it: clean up below.
            created = None if str(exc) in ('timeout', 'network', 'command-failed', 'command-unavailable') else False
            raise
        deadline = time.monotonic() + options.in_cluster_deadline + 30
        state = None
        while time.monotonic() < deadline:
            status = json.loads(kubectl_text(options, ['get', 'job', name, '-o', 'json'])).get('status', {})
            conditions = {c.get('type'): c.get('status') for c in status.get('conditions', [])}
            if status.get('succeeded') or conditions.get('Complete') == 'True':
                state = 'complete'
                break
            if status.get('failed') or conditions.get('Failed') == 'True':
                state = 'failed'
                break
            time.sleep(2)
        if state != 'complete':
            reason = 'in-cluster-job-timeout' if state is None else 'in-cluster-job-failed'
            try:  # A fixed category for a pod that never started.
                pods = json.loads(kubectl_text(options, ['get', 'pods', '-l', 'job-name='+name, '-o', 'json'])).get('items', [])
                for pod in pods:
                    for st in (pod.get('status') or {}).get('containerStatuses') or []:
                        waiting = (st.get('state') or {}).get('waiting', {}).get('reason')
                        if waiting in ('ImagePullBackOff', 'ErrImagePull', 'InvalidImageName'):
                            reason = 'in-cluster-image-pull-failed'
                    if (pod.get('status') or {}).get('phase') == 'Pending' and reason == 'in-cluster-job-timeout':
                        reason = 'in-cluster-pod-not-scheduled-or-started'
            except (DiagnosticError, ValueError):
                pass
            raise DiagnosticError(reason)
        # Logs go through the node's kubelet; on a node that was just created its
        # serving certificate can lag ("tls: internal error"), so retry.
        for attempt in range(6):
            try:
                return parse(kubectl_text(options, ['logs', 'job/'+name, '--tail=-1']))
            except DiagnosticError as exc:
                if attempt == 5 or str(exc) == 'in-cluster-output-incomplete':
                    raise
                time.sleep(5)
    except ValueError:
        raise DiagnosticError('invalid-response') from None
    finally:
        if created is not False:
            try:
                kubectl_text(options, ['delete', 'job', name, '--ignore-not-found', '--cascade=background', '--wait=false'])
                options.in_cluster_job['deleted'] = True
            except DiagnosticError:
                options.in_cluster_job['deleted'] = False
                print('warning: could not delete Job '+name+' in '+options.namespace+'; it deletes itself 10 minutes after finishing.',
                      file=sys.stderr)


def replay_query(results, credentials):  # results: {(slot, query): ...}
    """A psql() stand-in that answers from the in-cluster results."""
    slot_of = {id(c): s for s, c in credentials.items()}
    def query(credential, sql, timeout, ca_file=None):
        found = results.get((slot_of.get(id(credential)), QUERY_NAMES.get(sql)))
        if found is None:
            raise DiagnosticError('in-cluster-no-result')
        if found[0] == 'err':
            raise DiagnosticError(found[1])
        return found[1]
    return query


LOCAL_UNREACHABLE = ('network', 'dns', 'timeout', 'tool-missing', 'tls', 'credential-not-available', 'no-credentials')


def database_unreachable_locally(checks):
    """True when no database login was even attempted successfully from this machine, and
    nothing was confirmed wrong (a FAIL is kept, never replaced by the Job's result)."""
    if any(c['status'] == 'FAIL' for c in checks):
        return False
    db = [c for c in checks if c['check'] == 'database' or c['check'].startswith('database.')]
    connected = any(c['check'].endswith('.identity') for c in db)
    failed = any(c['status'] == 'FAIL' for c in db)
    return bool(db) and not connected and not failed and all(c['detail'] in LOCAL_UNREACHABLE for c in db)


def in_cluster_database_section(options, report):
    """Credentials and database checks from the in-cluster Job. Returns the credentials."""
    try:
        values, results = run_in_cluster(options)
    except DiagnosticError as exc:
        report.add('database.in-cluster', 'UNKNOWN', str(exc),
                   'The in-cluster check Job did not finish. Check that this identity can create Jobs in '+options.namespace
                   +', that the nodes can pull '+options.psql_image.split('@')[0]+' (or pass --psql-image <mirror>), and rerun.')
        in_cluster_cleanup_check(options, report)
        return {}
    options.in_cluster_values = values
    try:
        credentials = load_credentials(options, report)
    finally:
        options.in_cluster_values = None
    database_checks(options, credentials, report, query=replay_query(results, credentials))
    cas = ca_configmaps(options)
    ca = results.get('ca')
    if ca is None or ca == 'none' or int(ca) >= len(cas):
        report.add('database.in-cluster', 'UNKNOWN', 'Database checks ran inside the cluster, but no CA ConfigMap was found ('+', '.join(cas)+').',
                   'Create the CA ConfigMap the install uses (key ca.crt), or pass --ca-configmap <name>; TLS logins cannot verify without it.')
    else:
        report.add('database.in-cluster', 'PASS', 'Database checks ran inside the cluster, with the CA from ConfigMap '+cas[int(ca)]+'.')
    in_cluster_cleanup_check(options, report)
    return credentials


def in_cluster_cleanup_check(options, report):
    job = getattr(options, 'in_cluster_job', None) or {}
    if job.get('deleted') is False:
        report.add('database.in-cluster.cleanup', 'UNKNOWN', 'The check Job could not be deleted.',
                   'kubectl --context '+options.context+' -n '+options.namespace+' delete job '+job['name']
                   +' (it also deletes itself 10 minutes after finishing).')


EXAMPLE_CA_SHA = '9f2c4e1ab7d03586e2f1c9a47b0d6e3851fa2c94d7e60b13a8c5f27e4d91b06a'
EXAMPLE_MARKERS = ('selfhost-example', 'ar.example.com', 'org_example', 'example-agent-relay-sessions',
                   'vpc-agent-relay-example', 'admin@example.com', 'Example Corp', 'abc123example')
CA_NAMES = ('rds-ca.pem', 'database-ca.pem', 'global-bundle.pem')
SECRET_NAMES = {s[0] for s in SLOTS.values()}


def _is_ca(path):
    try:
        return path.is_file() and 'BEGIN CERTIFICATE' in path.read_text(errors='ignore')
    except OSError:
        return False


def _yaml_files(folder):
    try:
        return sorted(f for f in folder.iterdir() if f.is_file() and f.suffix in ('.yaml', '.yml'))
    except OSError:
        return []


def _secret_manifest_files(folders):
    found = []
    for folder in folders:
        for f in _yaml_files(folder):
            try:
                text = f.read_text(errors='ignore')
            except OSError:
                continue
            if re.search(r'^kind:\s*Secret\s*$', text, re.M) and any(n in text for n in SECRET_NAMES):
                found.append(f)
    return found


def can_create_jobs(options):
    """--in-cluster needs no Secret reads: ask whether this identity may create Jobs here."""
    try:
        return kubectl_text(options, ['auth', 'can-i', 'create', 'jobs.batch']).strip() == 'yes'
    except DiagnosticError:
        return False


def find_cluster(options, notes):
    """Use --context or the current context; True when the release namespace answers."""
    if not options.context:
        try:
            out = subprocess.run(['kubectl', 'config', 'current-context'], text=True,
                                 capture_output=True, timeout=10)
            if out.returncode == 0 and out.stdout.strip():
                options.context = out.stdout.strip()
                notes.append('kube context: '+options.context+' (current context; pass --context to change)')
        except (OSError, subprocess.TimeoutExpired):
            pass
        if not options.context:
            notes.append('kube context: none found; cluster checks will be UNKNOWN')
            options.missing['context'] = ('No kube context. On the cluster VPN, run: aws eks update-kubeconfig '
                                          '--name <cluster> --region <region>, or pass --context <name>. '
                                          'On the database VPN this is expected; use --scope database.')
            return False
    # Right after rollout restarts the API server, or slow exec-plugin credentials,
    # can delay an answer: never cap the probe below --timeout, and retry once.
    wait = max(options.timeout, PROBE_FLOOR)
    last, took = None, 0.0
    for attempt in range(PROBE_ATTEMPTS):
        start = PROBE_CLOCK()
        try:
            kube(options, 'secret', 'agent-relay-secrets', probe=True, probe_timeout=wait)
            return True
        except DiagnosticError as exc:
            last, took = exc, max(took, PROBE_CLOCK() - start)
            if attempt + 1 < PROBE_ATTEMPTS:
                PROBE_SLEEP(PROBE_PAUSE)
    plugin = exec_plugin(options)
    if str(last) == 'timeout' and plugin:
        notes.append('cluster: no answer within '+str(wait)+'s on '+str(PROBE_ATTEMPTS)+' attempts. This kubeconfig '
                     'authenticates through an exec plugin ('+plugin+'), so this is most likely slow credentials '
                     '(e.g. aws eks get-token with a slow credential_process), not an unreachable cluster. '
                     'Refresh the credentials or rerun with --timeout 90.')
    else:
        notes.append('cluster: not reachable after '+str(PROBE_ATTEMPTS)+' attempts ('+str(last)+', '+
                     str(round(took))+'s); on a split VPN, rerun on the cluster VPN for workload checks')
    return False


def exec_plugin(options):
    """The kubeconfig user's exec plugin command (e.g. aws), or '' when none or unknown."""
    try:
        out = subprocess.run(['kubectl', 'config', 'view', '--minify', '--context', options.context, '-o', 'json'],
                             text=True, capture_output=True, timeout=10)
        users = json.loads(out.stdout or '{}').get('users') or []
        command = ((users[0].get('user') or {}).get('exec') or {}).get('command', '') if users else ''
        return os.path.basename(str(command))[:40] if re.fullmatch(r'[A-Za-z0-9_./-]{1,200}', str(command)) else ''
    except (OSError, subprocess.TimeoutExpired, ValueError, AttributeError, IndexError):
        return ''


def discover(options, notes):
    """Fill in anything not passed explicitly; record what was used."""
    cwd = Path.cwd()
    home = Path.home()/'.agent-relay-install'
    options.missing = {}
    options.no_credentials = False
    wants_cluster = options.scope != 'database' or getattr(options, 'in_cluster', False)
    options.cluster_reachable = find_cluster(options, notes) if wants_cluster else False
    cluster_ok = options.cluster_reachable
    if getattr(options, 'in_cluster', False) and options.scope != 'cluster':
        notes.append('credentials: the release\'s Secrets, read inside the cluster by a short-lived Job (--in-cluster)')
    elif not options.secret_dir and not options.secret_manifests:
        manifests = _secret_manifest_files([cwd, cwd/'secrets'])
        if cluster_ok:
            notes.append('credentials: deployed Kubernetes Secrets')
        elif (home/'secret-files').is_dir():
            options.secret_dir = home/'secret-files'
            notes.append('credentials: '+str(options.secret_dir))
        elif manifests:
            options.secret_manifests = manifests
            notes.append('credentials: '+str(len(manifests))+' Secret YAML file(s): '+', '.join(f.name for f in manifests))
        else:
            options.no_credentials = True
            notes.append('credentials: none found')
            options.missing['credentials'] = (
                'No database credentials found. Looked for: the deployed Secrets (cluster not reachable), '
                '~/.agent-relay-install/secret-files, and Secret YAMLs in '+str(cwd)+' or '+str(cwd/'secrets')+'. '
                'Fix: copy the filled-in Secret YAMLs you applied (01-agent-relay-secrets.yaml ... '
                '05-search-indexer-owner.yaml) into ./secrets, or pass --secret-manifests <folder>.')
    if getattr(options, 'in_cluster', False) and options.scope != 'cluster':
        notes.append('database CA: the '+' or '.join(ca_configmaps(options))+' ConfigMap in '+options.namespace+' (--in-cluster)')
    elif not options.ca_file:
        for candidate in [cwd/n for n in CA_NAMES] + sorted(cwd.glob('*-bundle.pem')) + [home/'rds-ca.pem']:
            if _is_ca(candidate):
                options.ca_file = candidate
                notes.append('database CA: '+str(candidate))
                break
        else:
            notes.append('database CA: none found')
            options.missing['ca'] = None  # filled in after credentials load (region from the RDS host)
    if options.values is None:
        options.values = [f for f in _yaml_files(cwd) if 'values' in f.name.lower()
                          and f not in _secret_manifest_files([cwd])]
        if options.values:
            notes.append('values file(s): '+', '.join(f.name for f in options.values))
        else:
            notes.append('values file: none found')
            options.missing['values'] = ('No *values*.yaml in '+str(cwd)+', so the values checks were skipped. '
                                         'Fix: copy the values file you installed with (e.g. values-eks-poc.yaml) here, '
                                         'or pass --values <path>.')
    if not options.output:
        stamp = dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
        options.output = cwd/('install-diagnostic-'+stamp+'.json')


def values_checks(options, report):
    """Line-based lint of filled-in Helm values for mistakes seen in real installs."""
    import hashlib
    ca_sha = None
    if options.ca_file and _is_ca(Path(options.ca_file)):
        ca_sha = hashlib.sha256(Path(options.ca_file).read_bytes()).hexdigest()
    for f in options.values or []:
        tag = 'values.'+re.sub(r'[^a-z0-9]+', '-', f.name.lower()).strip('-')
        try:
            lines = f.read_text().splitlines()
        except OSError:
            report.unknown(tag, 'values-file-unreadable')
            continue
        placeholders, scheme, bad_sha, example_sha = [], [], [], []
        # global.rdsCa.bundle: the chart renders rds-ca and computes every hash.
        managed = re.search(r'^([ \t]*)rdsCa:[ \t]*\n(?:\1[ \t]+.*\n|[ \t]*#.*\n)*?\1[ \t]+bundle:[ \t]*["\']?([^"\'\s#]*)', '\n'.join(lines)+'\n', re.M)
        bundle = managed.group(2) if managed else ''
        if bundle:
            valid = bool(re.fullmatch(r'global|[a-z]{2}(?:-[a-z]+)+-[0-9]+', bundle))
            report.test(tag+'.rds-ca', valid,
                        'global.rdsCa.bundle is set: the chart creates rds-ca and computes its SHA-256.' if valid
                        else 'global.rdsCa.bundle is not an AWS region or global.',
                        'Set global.rdsCa.bundle to the RDS region, for example us-east-1, or to global.')
        for n, line in enumerate(lines, 1):
            body = line.split(' #', 1)[0]
            if body.lstrip().startswith('#') or not body.strip():
                continue
            if any(m in body for m in EXAMPLE_MARKERS) or re.search(r'__[A-Z0-9_]+__|<[a-z][a-z0-9 _-]*>', body):
                placeholders.append(n)
            for host in re.findall(r'(?:^|[\s"\'=:,\[])((?:[a-z]+://)?[a-z0-9.-]+\.(?:es|aoss)\.amazonaws\.com)', body):
                if not host.startswith('https://'):
                    scheme.append(n)
            m = re.search(r'\b(?:caSha256|sha256)\s*:\s*["\']?([0-9a-f]{64})', body)
            if m and 'digest' not in body:
                if m.group(1) == EXAMPLE_CA_SHA:
                    example_sha.append(n)
                elif ca_sha and m.group(1) != ca_sha:
                    bad_sha.append(n)
        lines_of = lambda xs: ', '.join(map(str, xs))
        report.test(tag+'.placeholders', not placeholders,
                    'Example/placeholder values remain on line(s) '+lines_of(placeholders)+'.' if placeholders else 'No example placeholders left.',
                    'Replace them with your domain, org, bucket, OpenSearch endpoint and admin email, then helm upgrade.')
        report.test(tag+'.opensearch-scheme', not scheme,
                    'OpenSearch URL without https:// on line(s) '+lines_of(scheme)+'.' if scheme else 'OpenSearch URLs use https://.',
                    'Prefix the OpenSearch endpoint with https:// (the search indexer fails without it).')
        report.test(tag+'.ca-sha256', not (example_sha or bad_sha),
                    (('Example CA hash on line(s) '+lines_of(example_sha)+'. ' if example_sha else '')
                    + ('CA hash differs from the local CA file on line(s) '+lines_of(bad_sha)+'.' if bad_sha else '')).strip()
                    or ('CA hashes match the local CA file.' if ca_sha else 'No example CA hash (no local CA file to compare).'),
                    ('Delete the hand-set CA hashes: with global.rdsCa.bundle the chart computes them.' if bundle else
                     'Set global.rdsCa.bundle: <RDS region> and delete the hand-set CA hashes (the chart computes them), '
                     'or set every caSha256/sha256 under rds-ca to: shasum -a 256 rds-ca.pem'))


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__+' With no flags, run it in the folder holding rds-ca.pem, your values file and Secret YAMLs; everything else is detected.')
    parser.add_argument('--context',help='Kube context (default: the current context).')
    parser.add_argument('--namespace',default='agent-relay')
    parser.add_argument('--release',default='agent-relay')
    parser.add_argument('--scope',choices=('cluster','database','all'),default='all',
                        help='Split runs when cluster and database VPNs cannot coexist.')
    parser.add_argument('--secret-dir',type=Path,help='Existing secret-files tree from the setup script; no Secrets API reads.')
    parser.add_argument('--secret-manifests',type=Path,nargs='+',
                        help='Filled-in Secret manifest files or a directory of them (YAML or kubectl JSON); no Secrets API reads.')
    parser.add_argument('--ca-file',type=Path,help='Local DB CA bundle; replaces in-container CA paths for this process.')
    for group in ('control','cast','hoop'):
        parser.add_argument('--'+group+'-database',help='Expected database name, including custom names.')
    parser.add_argument('--values',type=Path,nargs='*',help='Filled-in Helm values file(s) to lint (default: values*.yaml here).')
    parser.add_argument('--no-s3-check',action='store_true',help='Skip the S3 HEAD of the latest ingested object.')
    parser.add_argument('--no-aws',action='store_true',help='Skip the EKS Pod Identity checks (they use your AWS credentials, read only).')
    parser.add_argument('--eks-cluster',help='EKS cluster name for the Pod Identity checks (default: from the kube context).')
    parser.add_argument('--aws-region',help='AWS region of the EKS cluster (default: from the kube context).')
    parser.add_argument('--aws-profile',help='AWS profile for the Pod Identity checks (default: the one the kube context uses).')
    parser.add_argument('--no-iam-simulate',action='store_true',help='Skip iam simulate-principal-policy on the associated roles.')
    parser.add_argument('--in-cluster',action='store_true',
                        help='Run the database checks from a short-lived Job in the release namespace, with the release\'s '
                             'own Secrets and the rds-ca ConfigMap. Automatic when the database is unreachable from here.')
    parser.add_argument('--no-in-cluster',action='store_true',help='Never run the database checks inside the cluster.')
    parser.add_argument('--psql-image',default=os.environ.get('PSQL_IMAGE') or PSQL_IMAGE,
                        help='PostgreSQL client image for --in-cluster (default: $PSQL_IMAGE, else the rds-setup.sh pin).')
    parser.add_argument('--ca-configmap',help='ConfigMap (key ca.crt) with the database CA for --in-cluster '
                                               '(default: rds-ca, else cloud-sql-ca).')
    parser.add_argument('--in-cluster-deadline',type=int,default=300,help=argparse.SUPPRESS)
    parser.add_argument('--only',choices=('pod-identity','search'),
                        help='Run one section against the cluster: pod-identity (EKS Pod Identity associations for every '
                             'ServiceAccount the release uses) or search (the search bootstrap Job and one signed OpenSearch '
                             'request from inside the cluster, as the search indexer).')
    parser.add_argument('--create-pod-identity',metavar='SA=ROLE_ARN,...',
                        help='With --only pod-identity: create the missing associations named here (opt-in; changes AWS).')
    parser.add_argument('--no-search',action='store_true',help='Skip the search readiness checks (bootstrap Job and the OpenSearch probe).')
    parser.add_argument('--timeout',type=int,default=20)
    parser.add_argument('--output',type=Path,help='New JSON report file, mode 0600; never overwrites (default: ./install-diagnostic-<time>.json).')
    options = parser.parse_args(argv)
    if options.secret_dir and options.secret_manifests:
        parser.error('use either --secret-dir or --secret-manifests, not both')
    if options.in_cluster and options.no_in_cluster:
        parser.error('use either --in-cluster or --no-in-cluster, not both')
    if options.in_cluster and (options.secret_dir or options.secret_manifests or options.ca_file):
        parser.error('--in-cluster reads the deployed Secrets and rds-ca inside the cluster; drop --secret-dir/--secret-manifests/--ca-file')
    if options.ca_configmap is not None and not re.fullmatch(r'[a-z0-9][a-z0-9.-]{0,252}', options.ca_configmap):
        parser.error('--ca-configmap must be a ConfigMap name')
    # The Job mounts database credentials into this image: only a digest can't be swapped.
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._/:-]{0,400}@sha256:[0-9a-f]{64}', options.psql_image):
        parser.error('--psql-image (or PSQL_IMAGE) must be pinned by digest: <image>@sha256:<64 hex>')
    if not 1<=options.timeout<=120:
        parser.error('--timeout must be 1..120 seconds')
    spec, options.create_pod_identity, options.created_associations = options.create_pod_identity, {}, []
    if spec:
        if options.only != 'pod-identity':
            parser.error('--create-pod-identity needs --only pod-identity')
        for item in spec.split(','):
            sa, _, role = item.strip().partition('=')
            if not (re.fullmatch(NAME_RE, sa) and re.fullmatch(ROLE_ARN_RE, role)):
                parser.error('--create-pod-identity: each item is <ServiceAccount>=<IAM role ARN>, got '+item.strip()[:80])
            options.create_pod_identity[sa] = role
    return options


def only_section(options):
    """--only: one cluster section, its rows and a RESULT line. Exit 0 PASS, 1 FAIL, 2 UNKNOWN, 3 cluster unreachable."""
    report, notes = Report(), []
    options.missing = {}
    reachable = find_cluster(options, notes)
    for note in notes:
        print('  '+note)
    if not reachable:
        print('RESULT: INCOMPLETE: the cluster did not answer; '+options.only+' not checked.')
        return 3
    if options.only == 'pod-identity':
        pod_identity_checks(options, report)
        if not report.checks:
            report.add('podidentity', 'PASS', 'No workload of this release reads S3 or signs OpenSearch requests (or none is deployed yet).')
    else:
        search_checks(options, report)
        if not report.checks:
            report.add('search', 'PASS', 'No search indexer in this release.')
    for c in report.checks:
        print(c['status']+' '+c['check']+(' ['+c['resource']+']' if c.get('resource') else '')+': '+c['detail'])
        if c.get('action'):
            print('  Next: '+c['action'])
    for created in options.created_associations:
        print('CREATED '+created['serviceAccount']+' '+created['roleArn']+' '+','.join(created['deployments']))
    statuses = {c['status'] for c in report.checks}
    if 'FAIL' in statuses:
        print('RESULT: FAIL'); return 1
    if 'UNKNOWN' in statuses:
        print('RESULT: PARTIAL'); return 2
    print('RESULT: PASS'); return 0


def main(argv=None):
    options = parse_args(argv)
    if options.only:
        return only_section(options)
    explicit_credentials = bool(options.secret_dir or options.secret_manifests)
    report = Report()
    notes = []
    discover(options, notes)
    print('Detected:')
    for note in notes:
        print('  '+note)
    print()
    values_checks(options,report)
    if options.scope in ('cluster','all'):
        if getattr(options,'cluster_reachable',True):
            cluster_checks(options,report)
            if not getattr(options,'no_aws',False):
                pod_identity_checks(options,report)
            if not getattr(options,'no_search',False):
                search_checks(options,report)
        else:
            report.unknown('cluster','not-reachable')
    missing = getattr(options,'missing',{})
    in_cluster = getattr(options,'in_cluster',False) and options.scope in ('database','all')
    if in_cluster:
        credentials = {}
    elif getattr(options,'no_credentials',False):
        credentials = {}
        report.unknown('credentials','none-found')
    else:
        credentials = load_credentials(options,report)
        absent = sorted({SLOTS[c['check'].split('.',1)[1]][0] for c in report.checks
                         if c['check'].startswith('credential.') and c['detail']=='manifest-secret-missing'
                         and c['check'].split('.',1)[1] in SLOTS})
        if absent:
            missing['secrets'] = ('These Secrets were not in the YAML files found: '+', '.join(absent)+
                                  '. Add their filled-in YAMLs to ./secrets (see examples/aws/secrets/).')
    if 'ca' in missing:
        regions = sorted({m.group(1) for c in credentials.values()
                          for m in [re.search(r'\.([a-z]{2}(?:-gov)?-[a-z]+-\d)\.rds\.amazonaws\.com$', c['host'])] if m})
        region = regions[0] if len(regions)==1 else '<region>'
        missing['ca'] = ('No database CA file (looked for rds-ca.pem, database-ca.pem, global-bundle.pem, *-bundle.pem here, '
                         'then ~/.agent-relay-install/rds-ca.pem); TLS logins will fail. Fix: from your infra checkout '
                         'cp charts/agent-relay/files/rds-ca/'+region+'-bundle.pem rds-ca.pem, or '
                         'curl -fsS -o rds-ca.pem https://truststore.pki.rds.amazonaws.com/'+region+'/'+region+'-bundle.pem '
                         '(or pass --ca-file <path>).')
    first_credential_check = next((i for i,c in enumerate(report.checks) if c['check'].startswith('credential')), len(report.checks))
    if in_cluster:
        # Creating the Job needs no Secret reads, so don't require the Secret probe.
        if options.context and (getattr(options,'cluster_reachable',False) or can_create_jobs(options)):
            in_cluster_database_section(options,report)
        else:
            report.add('database.in-cluster','UNKNOWN','cluster-not-reachable-or-jobs-forbidden',
                       'Check the kube context and that this identity can create Jobs in '+options.namespace
                       +': kubectl auth can-i create jobs -n '+options.namespace)
        for key in ('ca','credentials','secrets'):
            missing.pop(key,None)
    elif getattr(options,'no_credentials',False):
        report.unknown('database','no-credentials')
    elif options.scope in ('database','all'):
        database_checks(options,credentials,report)
    else:
        report.unknown('database','not-requested-cluster-only')
    # Database unreachable from here (split VPN, no psql, no CA) but the cluster is
    # reachable: run the same checks from inside the cluster instead.
    unreachable = (not in_cluster and options.scope in ('database','all') and not getattr(options,'no_in_cluster',False)
                   and database_unreachable_locally(report.checks[first_credential_check:]))
    if unreachable and explicit_credentials:
        # The Job would test the deployed Secrets, not the copy you selected.
        print('The database is not reachable from this machine. To check the deployed Secrets from inside the cluster '
              'instead of the files you passed, rerun with --in-cluster.')
        unreachable = False
    if unreachable and not getattr(options,'cluster_reachable',False):
        # --scope database skipped the cluster; try it now that the database is out of reach.
        cluster_notes = []
        if options.scope == 'database' or not options.context:
            find_cluster(options, cluster_notes)
        options.cluster_reachable = bool(options.context) and can_create_jobs(options)
        for note in cluster_notes:
            print('  '+note)
    if unreachable and getattr(options,'cluster_reachable',False):
        print('The database is not reachable from this machine; running the database checks inside the cluster '
              '(a short-lived Job in '+options.namespace+'; --no-in-cluster to skip).')
        del report.checks[first_credential_check:]
        in_cluster_database_section(options,report)
        for key in ('ca','credentials','secrets'):
            missing.pop(key,None)
    result = report.result()
    result['scope'] = options.scope
    result['missingInputs'] = sorted(missing)
    from_cluster = any(c['check']=='database.in-cluster' for c in result['checks'])
    result['credentialSource'] = ('in-cluster-job' if from_cluster else 'local-manifests' if options.secret_manifests
                                  else 'local-files' if options.secret_dir else 'named-kubernetes-secrets')
    result['databaseChecksFrom'] = 'cluster' if from_cluster else 'this-machine'
    if options.output:
        try:
            with open(options.output,'x',opener=lambda path,flags:os.open(path,flags,0o600)) as output:
                json.dump(result,output,indent=2)
                output.write('\n')
        except OSError:
            print('Could not create report file (existing file, permissions or missing directory).',file=sys.stderr)
            return 2
    for check in result['checks']:
        resource = ' ['+check['resource']+']' if 'resource' in check else ''
        print(check['status']+' '+check['check']+resource+': '+check['detail'])
        if check['action']:
            print('  Next: '+check['action'])
    failures = [c for c in result['checks'] if c['status']=='FAIL']
    if failures:
        print()
        print('Likely problems (fix top to bottom):')
        for c in failures:
            where = ' ['+c['resource']+']' if 'resource' in c else ''
            print('  - '+c['check']+where+': '+c['detail']+(' -> '+c['action'] if c['action'] else ''))
    if missing:
        print()
        print('Missing files - how to fix:')
        for key in ('credentials','secrets','ca','values','context'):
            if key in missing:
                print('  - '+missing[key])
    print()
    print('Summary: '+json.dumps(result['summary'],sort_keys=True))
    print('Report written to '+str(options.output)+' (share this file, never the Secret YAMLs).')
    skipped = options.scope in ('cluster','all') and not getattr(options,'cluster_reachable',True)
    if result['summary']['FAIL']:
        print('RESULT: FAIL: '+str(result['summary']['FAIL'])+' check(s) failed; fix them top to bottom (see "Likely problems").')
        return 1
    if skipped:
        # Never a clean result: the workload checks did not run.
        print('RESULT: INCOMPLETE: workload checks skipped (the cluster did not answer). Nothing above covers Jobs, '
              'Pods or Deployments. Rerun on the cluster VPN: python3 diagnose-install.py --scope cluster, '
              'or run: helm test agent-relay -n agent-relay --logs')
        return 3
    if result['summary']['UNKNOWN']:
        print('RESULT: PARTIAL: '+str(result['summary']['UNKNOWN'])+' check(s) could not run (UNKNOWN above).')
        return 2
    print('RESULT: PASS')
    return 0


if __name__=='__main__':
    sys.exit(main())
