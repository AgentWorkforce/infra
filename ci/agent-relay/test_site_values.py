#!/usr/bin/env python3
"""Site values (top-level `site:`) and the aggregated values check.

- The short form (examples/aws/values.yaml) renders byte-identically to the
  long form it replaced (fixtures/aws-long-form-values.yaml, every site value
  typed on each line).
- A per-component value overrides site where it may differ, and a value that
  contradicts site where the two must agree fails.
- One render reports several problems at once, and that report comes out
  before any subchart's own (one-at-a-time) failure.
- templates/site/.../site.yaml stays the deepest template path, which is what
  makes Helm render it before every subchart.
- scripts/selfhost/check-values.sh reports example values and the chart's list.
Needs the chart's dependencies built (ci/agent-relay/render.sh does it first).
"""
from pathlib import Path
import io
import re
import subprocess
import tarfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[2]
CHART = ROOT / 'charts/agent-relay'
EKS = [str(CHART / 'values-eks.yaml'), str(CHART / 'values-eks-native.yaml')]
SHORT = ROOT / 'examples/aws/values.yaml'
LONG = ROOT / 'ci/agent-relay/fixtures/aws-long-form-values.yaml'
SITE_TEMPLATE = 'templates/site/runs-before-subcharts/1/2/3/4/5/site.yaml'

SITE = {
    'domain': 'relay.acme.dev',
    'region': 'eu-west-1',
    'sessionsBucket': 'acme-agent-relay-sessions',
    'opensearchUrl': 'https://vpc-acme-relay-abc.eu-west-1.es.amazonaws.com',
    'orgId': 'org_acme',
    'orgName': 'Acme',
    'adminEmail': 'ops@acme.dev',
}


def helm(*args, files=(), values=None):
    cmd = ['helm', 'template', 'agent-relay', str(CHART), '-n', 'agent-relay', '--no-hooks']
    for f in files:
        cmd += ['-f', str(f)]
    if values is not None:
        cmd += ['-f', '-']
    cmd += list(args)
    return subprocess.run(cmd, input=yaml.safe_dump(values) if values is not None else None,
                          capture_output=True, text=True, cwd=ROOT)


def render(*args, files=(), values=None):
    out = helm(*args, files=files, values=values)
    if out.returncode:
        raise AssertionError(out.stderr)
    return out.stdout


def fails(*args, files=(), values=None):
    out = helm(*args, files=files, values=values)
    if out.returncode == 0:
        raise AssertionError('rendered, expected a failure')
    return out.stderr


def docs(text):
    return [d for d in yaml.safe_load_all(text) if d]


def env_of(objs, kind, name, container=0):
    for o in objs:
        if o['kind'] == kind and o['metadata']['name'] == name:
            spec = o['spec']['template']['spec'] if kind != 'CronJob' else o['spec']['jobTemplate']['spec']['template']['spec']
            return {e['name']: e.get('value') for e in spec['containers'][container].get('env', [])}
    raise AssertionError(f'{kind}/{name} not rendered')


def short_with(site=None, **extra):
    """The AWS example with site replaced by `site` (merged) and extra top-level keys."""
    values = yaml.safe_load(SHORT.read_text())
    values.pop('x-pins', None)
    values['site'] = {**values['site'], **(site or {})}
    for k, v in extra.items():
        values[k] = v
    return values


class ShortForm(unittest.TestCase):
    def test_short_form_renders_like_the_long_form(self):
        self.assertEqual(render(files=EKS + [LONG]), render(files=EKS + [SHORT]))

    def test_short_form_has_each_site_value_once(self):
        text = SHORT.read_text()
        body = '\n'.join(l.split(' #')[0] for l in text.splitlines() if not l.lstrip().startswith('#'))
        site = yaml.safe_load(text)['site']
        for key in ('domain', 'region', 'sessionsBucket', 'opensearchUrl', 'orgId'):
            self.assertEqual(body.count(site[key]), 1 if key != 'region' else body.count(site[key]),
                             f'{key} must appear once in examples/aws/values.yaml')
        self.assertEqual(body.count(site['domain']), 1)
        self.assertEqual(body.count(site['sessionsBucket']), 1)
        self.assertEqual(body.count(site['opensearchUrl']), 1)

    def test_every_derived_value(self):
        objs = docs(render(files=EKS, values=short_with(SITE)))
        text = yaml.safe_dump_all(objs)
        self.assertNotIn('selfhost-example', text)
        self.assertNotIn('placeholder.company', text)
        self.assertNotIn('example-agent-relay-sessions', text)
        control = env_of(objs, 'Deployment', 'relay-control')
        self.assertEqual(control['SELFHOST_PUBLIC_URL'], 'https://api.relay.acme.dev')
        self.assertEqual(control['RELAYCAST_PUBLIC_URL'], 'https://cast.relay.acme.dev')
        self.assertEqual(control['SESSION_READ_API_PUBLIC_URL'], 'https://history.relay.acme.dev')
        self.assertEqual(control['SELFHOST_BOOTSTRAP_ADMIN_EMAIL'], 'ops@acme.dev')
        read = env_of(objs, 'Deployment', 'agent-relay-read-api')
        self.assertEqual(read['LOCKER_BUCKET'], SITE['sessionsBucket'])
        self.assertEqual(read['LOCKER_REGION'], 'eu-west-1')
        self.assertIn('https://relay.acme.dev', text)
        ingest = env_of(objs, 'Deployment', 'agent-relay-ingest-edge')
        self.assertEqual(ingest['LOCKER_BUCKET'], SITE['sessionsBucket'])
        self.assertEqual(ingest['LOCKER_REGION'], 'eu-west-1')
        # global.tenant.orgId reaches the subcharts' own copies of global.
        self.assertIn('org_acme', text)
        self.assertNotIn('org_example', text)


class Overrides(unittest.TestCase):
    def test_independent_value_overrides_site(self):
        values = short_with()
        values['sessions-pipeline']['sessionReadApi']['search']['opensearch']['region'] = 'eu-central-1'
        values['sessions-pipeline']['sessionReadApi']['cors'] = {'allowedOrigins': ['https://other.acme.dev']}
        objs = docs(render(files=EKS, values=values))
        read = env_of(objs, 'Deployment', 'agent-relay-read-api')
        self.assertEqual(read['SEARCH_INDEX_OPENSEARCH_AWS_REGION'], 'eu-central-1')
        self.assertIn('https://other.acme.dev', yaml.safe_dump_all(objs))

    def test_explicit_value_equal_to_site_is_fine(self):
        values = short_with()
        values['sessions-pipeline']['ingestEdge']['locker']['bucket'] = values['site']['sessionsBucket']
        values['relay-control']['publicUrl'] = 'https://api.' + values['site']['domain']
        values['relay-control']['dashboardUrl'] = 'https://' + values['site']['domain']  # no trailing slash: same origin
        render(files=EKS, values=values)

    def test_hosts_replace_single_roles(self):
        objs = docs(render(files=EKS, values=short_with({'hosts': {'dashboard': 'app.acme.dev'}})))
        control = env_of(objs, 'Deployment', 'relay-control')
        self.assertEqual(control['SELFHOST_PUBLIC_URL'], 'https://api.ar.selfhost-example.agentrelay.com')
        self.assertIn('https://app.acme.dev', yaml.safe_dump_all(objs))

    def test_real_region_next_to_real_endpoint_wins(self):
        # us-west-2 is also a profile placeholder; next to a real URL it is real.
        values = short_with()
        values['sessions-pipeline']['searchIndexer']['search']['opensearch'].update(
            {'url': values['site']['opensearchUrl'], 'region': 'us-west-2'})
        objs = docs(render(files=EKS, values=values))
        self.assertIn("SEARCH_INDEX_OPENSEARCH_AWS_REGION', 'value': 'us-west-2'", str([o for o in objs if o['metadata']['name'].endswith('search-indexer')]))

    def test_rds_native_profile_placeholders_are_replaced(self):
        files = [EKS[0], str(CHART / 'values-eks-rds-native.yaml')]
        text = render(files=files, values={'site': SITE})
        for placeholder in ('placeholder.company', 'example-agent-relay-sessions', 'example-org', 'us-west-2'):
            self.assertNotIn(placeholder, text)
        read = env_of(docs(text), 'Deployment', 'agent-relay-read-api')
        self.assertEqual((read['LOCKER_BUCKET'], read['LOCKER_REGION']), (SITE['sessionsBucket'], SITE['region']))

    def test_single_host_cors_is_the_single_host(self):
        values = short_with()
        values.setdefault('global', {})['singleHost'] = {'host': 'one.acme.dev'}
        read = env_of(docs(render(files=EKS, values=values)), 'Deployment', 'agent-relay-read-api')
        self.assertEqual(read['READ_API_CORS_ALLOWED_ORIGINS'], 'https://one.acme.dev')

    def test_no_site_keeps_the_profiles(self):
        # Without site the profile renders exactly as before (the golden in
        # subdomain-golden.sh pins it); spot-check a placeholder survives.
        self.assertIn('placeholder.company', render(files=EKS))

    def test_eks_ingress_takes_the_domain(self):
        values = short_with(eksIngress={'enabled': True, 'certificateArn': 'arn:aws:acm:us-east-1:111111111111:certificate/x'})
        hosts = {r['host'] for o in docs(render(files=EKS, values=values)) if o['kind'] == 'Ingress'
                 for r in o['spec']['rules']}
        d = values['site']['domain']
        self.assertEqual(hosts, {d, 'api.' + d, 'cast.' + d, 'history.' + d})


class DocValues(unittest.TestCase):
    """GKE site values (the guide's values.yaml in the short form, ci/agent-relay/fixtures/gcp-site-values.yaml)."""

    def test_gcp_template_fills_from_site(self):
        fill = {'__NAMESPACE__': 'agent-relay', '__ORG_ID__': 'org_acme', '__ORG_NAME__': 'Acme',
                '__ADMIN_EMAIL__': 'ops@acme.dev', '__DOMAIN__': 'relay.acme.dev', '__REGION__': 'europe-west1',
                '__SESSIONS_BUCKET__': 'acme-relay-sessions', '__STATIC_IP_NAME__': 'acme-ip'}
        text = (ROOT / 'ci/agent-relay/fixtures/gcp-site-values.yaml').read_text()
        for k, v in fill.items():
            text = text.replace(k, v)
        # What docs/gcp-install/managed-values-byo.sh writes, for these inputs.
        gcs = {'provider': 'gcs', 'bucket': 'acme-relay-sessions', 'region': 'europe-west1'}
        managed = {'sessions-pipeline': {'ingestEdge': {'locker': gcs}, 'searchIndexer': {'locker': gcs},
                                         'worker': {'locker': {'bucket': gcs['bucket'], 'region': gcs['region']}}}}
        p = ROOT / 'ci/agent-relay/fixtures/.gcp-managed-test.yaml'
        p.write_text(yaml.safe_dump(managed))
        try:
            out = render(files=[CHART / 'values-gcp.yaml', CHART / 'values-gcp-native.yaml', p], values=yaml.safe_load(text))
        finally:
            p.unlink()
        objs = docs(out)
        hosts = {r['host'] for o in objs if o['kind'] == 'Ingress' for r in o['spec']['rules']}
        self.assertEqual(hosts, {'relay.acme.dev', 'api.relay.acme.dev', 'cast.relay.acme.dev', 'history.relay.acme.dev'})
        read = env_of(objs, 'Deployment', 'agent-relay-read-api')
        self.assertEqual((read['LOCKER_BUCKET'], read['LOCKER_REGION']), ('acme-relay-sessions', 'europe-west1'))
        control = env_of(objs, 'Deployment', 'relay-control')
        self.assertEqual(control['SELFHOST_PUBLIC_URL'], 'https://api.relay.acme.dev')

    def test_gcp_bucket_that_differs_from_terraform_fails(self):
        text = (ROOT / 'ci/agent-relay/fixtures/gcp-site-values.yaml').read_text()
        for k, v in {'__DOMAIN__': 'relay.acme.dev', '__REGION__': 'us-central1', '__SESSIONS_BUCKET__': 'typo-bucket',
                     '__ORG_ID__': 'org_acme', '__ORG_NAME__': 'Acme', '__ADMIN_EMAIL__': 'ops@acme.dev',
                     '__NAMESPACE__': 'agent-relay', '__STATIC_IP_NAME__': 'ip'}.items():
            text = text.replace(k, v)
        values = yaml.safe_load(text)
        values['sessions-pipeline']['ingestEdge']['locker'] = {'provider': 'gcs', 'bucket': 'tf-bucket', 'region': 'us-central1'}
        err = fails(files=[CHART / 'values-gcp.yaml', CHART / 'values-gcp-native.yaml'], values=values)
        self.assertIn('sessions-pipeline.ingestEdge.locker.bucket = "tf-bucket"', err)


class Failures(unittest.TestCase):
    def test_region_names(self):
        for region in ('us-east-1', 'us-gov-west-1', 'europe-west1', 'australia-southeast1', 'asia-south1'):
            with self.subTest(region=region):
                out = helm(files=EKS, values=short_with({'region': region, 'rds': False}))
                self.assertNotIn('site.region = ', out.stderr)
        self.assertIn('site.region = "Mars"', fails(files=EKS, values=short_with({'region': 'Mars'})))

    def test_eks_ingress_domain_that_disagrees_with_site_hosts_fails(self):
        arn = 'arn:aws:acm:us-east-1:111111111111:certificate/x'
        values = short_with({'hosts': {'dashboard': 'app.acme.dev'}},
                            eksIngress={'enabled': True, 'certificateArn': arn, 'domain': 'ar.selfhost-example.agentrelay.com'})
        err = fails(files=EKS, values=values)
        self.assertIn('eksIngress.domain = "ar.selfhost-example.agentrelay.com"', err)
        self.assertIn('gives the dashboard host', err)
        values['eksIngress'].pop('domain')
        hosts = {r['host'] for o in docs(render(files=EKS, values=values)) if o['kind'] == 'Ingress' for r in o['spec']['rules']}
        self.assertIn('app.acme.dev', hosts)

    def test_contradiction_fails_with_both_values(self):
        values = short_with()
        values['sessions-pipeline']['ingestEdge']['locker']['bucket'] = 'other-bucket'
        err = fails(files=EKS, values=values)
        self.assertIn('sessions-pipeline.ingestEdge.locker.bucket = "other-bucket"', err)
        self.assertIn('contradicts site.sessionsBucket', err)

    def test_read_api_locker_env_contradiction(self):
        values = short_with()
        values['sessions-pipeline']['sessionReadApi']['extraEnv'].insert(0, {'name': 'LOCKER_BUCKET', 'value': 'old'})
        self.assertIn('extraEnv LOCKER_BUCKET = "old"', fails(files=EKS, values=values))

    def test_rehearsal_mistakes_are_listed_together(self):
        # The by-hand rehearsal's partial edits, all in one long-form file.
        text = LONG.read_text()
        text = text.replace('origin: https://history.ar.selfhost-example.agentrelay.com', 'origin: https://history.ar.example.com', 1)
        text = text.replace('url: https://vpc-agent-relay-example', 'url: vpc-agent-relay-example')
        text = re.sub(r'(ingestEdge:.*?bucket: )example-agent-relay-sessions', r'\1aa-relay-sessions', text, count=1, flags=re.S)
        err = fails(files=EKS, values=yaml.safe_load(text))
        self.assertIn(SITE_TEMPLATE, err)
        self.assertRegex(err, r'agent-relay: [5-9] values problems')
        for where in ('sessions-pipeline.sessionReadApi.origin',
                      'sessions-pipeline.sessionReadApi.search.opensearch.url',
                      'sessions-pipeline.searchIndexer.search.opensearch.url',
                      'sessions-pipeline.sessionReadApi.extraEnv LOCKER_BUCKET',
                      'sessions-pipeline.ingestEdge.origin'):
            self.assertIn(where, err)

    def test_one_bad_site_value_is_one_problem(self):
        values = short_with({'domain': 'relay.aa.internal', 'opensearchUrl': 'vpc-x.us-east-1.es.amazonaws.com'})
        values['site']['orgID'] = 'typo'
        err = fails(files=EKS, values=values)
        self.assertIn('agent-relay: 3 values problems', err)
        self.assertIn('site.domain = "relay.aa.internal"', err)
        self.assertIn('is a private or reserved name', err)
        self.assertIn('set it to "https://vpc-x.us-east-1.es.amazonaws.com"', err)
        self.assertIn('site.orgID', err)

    def test_wrong_type_is_one_problem(self):
        err = fails('--set', 'site.region=123', '--set', 'site.orgID=x', files=EKS, values=short_with())
        self.assertIn('agent-relay: 2 values problems', err)
        self.assertIn('site.region = 123\n   must be a string', err)

    def test_aggregate_runs_before_subchart_failures(self):
        # relay-control refuses an empty encryption.keyId on its own; the site
        # report must still come first, proving the render order.
        values = short_with({'sessionsBucket': 'Bad_Bucket'})
        err = fails('--set', 'relay-control.encryption.keyId=', files=EKS, values=values)
        self.assertIn(SITE_TEMPLATE, err)
        self.assertIn('site.sessionsBucket', err)

    def test_site_template_is_the_deepest(self):
        depth = SITE_TEMPLATE.count('/')
        deepest = ('', 0)

        def walk_tar(data, prefix):
            nonlocal deepest
            with tarfile.open(fileobj=io.BytesIO(data)) as tar:
                for m in tar.getmembers():
                    path = prefix + m.name
                    if m.name.endswith('.tgz'):
                        walk_tar(tar.extractfile(m).read(), prefix + m.name.rsplit('/', 1)[0] + '/')
                    elif m.isfile() and '/templates/' in m.name and path.count('/') > deepest[1]:
                        deepest = (path, path.count('/'))

        for t in (CHART / 'templates').rglob('*'):
            rel = 'templates/' + str(t.relative_to(CHART / 'templates'))
            if t.is_file() and rel != SITE_TEMPLATE and rel.count('/') > deepest[1]:
                deepest = (rel, rel.count('/'))
        for tgz in (CHART / 'charts').glob('*.tgz'):
            walk_tar(tgz.read_bytes(), 'charts/')
        self.assertGreaterEqual(deepest[1], 6, 'the walk found no nested subchart templates')
        self.assertGreater(depth, deepest[1], f'{deepest[0]} is as deep as {SITE_TEMPLATE}; deepen the site template')


class CheckValues(unittest.TestCase):
    SCRIPT = str(ROOT / 'scripts/selfhost/check-values.sh')

    def run_script(self, *args):
        return subprocess.run([self.SCRIPT, *args], capture_output=True, text=True, cwd=ROOT)

    def test_shipped_profile_list_matches_the_chart(self):
        text = Path(self.SCRIPT).read_text()
        listed = set(re.search(r'shipped_profiles="([^"]*)"', text).group(1).split())
        self.assertEqual(listed, {p.name for p in CHART.glob('values*.yaml')})

    def test_shipped_profiles_are_not_scanned_without_git(self):
        # A copy in the chart directory is scanned; the shipped profile is not.
        copy = CHART / 'values-poc.yaml'
        copy.write_text('site:\n  domain: ar.selfhost-example.agentrelay.com\n')
        try:
            out = self.run_script('-f', EKS[0], '-f', str(copy))
        finally:
            copy.unlink()
        self.assertIn('values-poc.yaml:2:', out.stdout)
        self.assertNotIn('values-eks.yaml:', out.stdout)

    def test_example_values_are_reported_by_line(self):
        out = self.run_script('-f', EKS[0], '-f', EKS[1], '-f', str(SHORT))
        self.assertEqual(out.returncode, 1)
        self.assertRegex(out.stdout, r'examples/aws/values.yaml:\d+: +domain: ar.selfhost-example')

    def test_clean_values_pass(self):
        out = self.run_script('--allow-example-values', '-f', EKS[0], '-f', EKS[1], '-f', str(SHORT))
        self.assertEqual(out.returncode, 0, out.stdout + out.stderr)

    def test_chart_problems_are_listed(self):
        values = short_with({'opensearchUrl': 'vpc-x.us-east-1.es.amazonaws.com', 'region': 'Mars'})
        p = ROOT / 'ci/agent-relay/fixtures/.check-values-test.yaml'
        p.write_text(yaml.safe_dump(values))
        try:
            out = self.run_script('--allow-example-values', '-f', EKS[0], '-f', str(p))
        finally:
            p.unlink()
        self.assertEqual(out.returncode, 1)
        self.assertIn('agent-relay: 2 values problems', out.stdout)
        self.assertNotIn('execution error at', out.stdout)


if __name__ == '__main__':
    unittest.main()
