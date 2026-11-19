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
 SELECT c.oid,c.relowner,c.relkind FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
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
 'missing_table_grants', (SELECT count(*) FROM objects WHERE relkind<>'S' AND NOT (has_table_privilege(runtime,oid,'SELECT') AND has_table_privilege(runtime,oid,'INSERT') AND has_table_privilege(runtime,oid,'UPDATE') AND has_table_privilege(runtime,oid,'DELETE'))),
 'missing_sequence_grants', (SELECT count(*) FROM objects WHERE relkind='S' AND NOT (has_sequence_privilege(runtime,oid,'SELECT') AND has_sequence_privilege(runtime,oid,'USAGE') AND has_sequence_privilege(runtime,oid,'UPDATE')))
) FROM roles;
"""
HOOP_SQL = """SELECT json_build_object(
 'vector', EXISTS(SELECT 1 FROM pg_extension WHERE extname='vector'),
 'pg_trgm', EXISTS(SELECT 1 FROM pg_extension WHERE extname='pg_trgm'),
 'btree_gin', EXISTS(SELECT 1 FROM pg_extension WHERE extname='btree_gin'),
 'sessions_schema', EXISTS(SELECT 1 FROM pg_namespace WHERE nspname='sessions')
);"""


class DiagnosticError(Exception):
    """Only fixed category strings may be emitted from this exception."""


def error_category(stderr):
    # Never return server/command error text; it can include full credentials.
    value = stderr.lower()
    if re.search(r'role .+ does not exist',value):
        return 'role-missing'
    for category, patterns in (
        ('authentication', ('password authentication failed', 'no password supplied', 'role does not exist')),
        ('database-missing', ('database',)),
        ('tls', ('certificate', 'ssl', 'tls')),
        ('dns', ('could not translate host', 'name or service not known')),
        ('network', ('connection refused', 'timeout expired', 'could not connect', 'no route to host')),
        ('permissions', ('permission denied', 'forbidden')),
    ):
        if category == 'database-missing':
            if 'database' in value and 'does not exist' in value:
                return category
        elif any(p in value for p in patterns):
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
        if any('\x00' in v for k,v in credential.items() if isinstance(v,str)):
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


def kube(options, resource, name=None, selector=False):
    argv = ['kubectl','--context',options.context,'--namespace',options.namespace,
            '--request-timeout='+str(options.timeout)+'s','get',resource]
    if name:
        argv.append(name)
    if selector:
        argv += ['-l','app.kubernetes.io/instance='+options.release]
    return run(argv+['-o','json'],options.timeout)


def cluster_checks(options, report):
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


def load_credentials(options, report):
    secrets = {}
    credentials = {}
    for slot,(secret,key,wrapper,role,group) in SLOTS.items():
        try:
            if options.secret_dir:
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
            report.add('credential.'+slot,'UNKNOWN' if str(exc) in ('permissions','network','timeout','tool-missing','command-failed') else 'FAIL',str(exc),
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


def database_checks(options, credentials, report):
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
            if slot.endswith('runtime'):
                report.test('database.'+slot+'.no-database-owner-membership',not identity['database_owner_membership'],
                            'Runtime cannot assume the database owner role.', 'Have the DBA review inherited and SET-role membership paths.')
                if SLOTS[slot][4]=='hoop':
                    report.test('database.'+slot+'.sessions-usage',identity['sessions_usage'],
                                'Runtime has USAGE on the sessions schema.', 'Check migrations and post-migration phase 2 role activation/grants.')
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


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--context',help='Explicit kube context; required when reading the cluster.')
    parser.add_argument('--namespace',default='agent-relay')
    parser.add_argument('--release',default='agent-relay')
    parser.add_argument('--scope',choices=('cluster','database','all'),default='all',
                        help='Split runs when cluster and database VPNs cannot coexist.')
    parser.add_argument('--secret-dir',type=Path,help='Existing secret-files tree from the setup script; no Secrets API reads.')
    parser.add_argument('--ca-file',type=Path,help='Local DB CA bundle; replaces in-container CA paths for this process.')
    for group in ('control','cast','hoop'):
        parser.add_argument('--'+group+'-database',help='Expected database name, including custom names.')
    parser.add_argument('--timeout',type=int,default=20)
    parser.add_argument('--output',type=Path,help='New JSON report file, created mode 0600; never overwrites.')
    options = parser.parse_args(argv)
    if not options.context and (options.scope!='database' or not options.secret_dir):
        parser.error('--context is required for cluster access; database-only offline input requires --secret-dir')
    if not 1<=options.timeout<=120:
        parser.error('--timeout must be 1..120 seconds')
    return options


def main(argv=None):
    options = parse_args(argv)
    report = Report()
    if options.scope in ('cluster','all'):
        cluster_checks(options,report)
    credentials = load_credentials(options,report)
    if options.scope in ('database','all'):
        database_checks(options,credentials,report)
    else:
        report.unknown('database','not-requested-cluster-only')
    result = report.result()
    result['scope'] = options.scope
    result['credentialSource'] = 'local-files' if options.secret_dir else 'named-kubernetes-secrets'
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
    print('Summary: '+json.dumps(result['summary'],sort_keys=True))
    return 1 if result['summary']['FAIL'] else 2 if result['summary']['UNKNOWN'] else 0


if __name__=='__main__':
    sys.exit(main())
