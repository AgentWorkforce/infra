import copy
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import types
import unittest
from unittest.mock import patch, MagicMock

spec = importlib.util.spec_from_file_location("aws_data", Path(__file__).with_name("verify-aws-data.py"))
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)
ACCOUNT = "111111111111"
REGION = "us-west-2"
RUN = "a" * 32


def installation(**changes):
    values = dict(account=ACCOUNT, region=REGION, environment="dev", environment_class="development", name_prefix="agent-relay")
    values.update(changes)
    values.setdefault("search_url", f"https://vpc-{values['name_prefix']}-{values['environment']}-search-abc.{values['region']}.es.amazonaws.com")
    return probe.confirm_installation(**values)


def fixture(mode="rds", confirmed=None):
    i = confirmed or installation()
    name = i.name_prefix + "-" + i.environment
    return {
        "account_id": i.account, "environment": i.environment, "environment_class": i.environment_class, "name_prefix": i.name_prefix, "region": i.region,
        "pippen": None if i.pippen_agent is None else {"agent": i.pippen_agent, "session_id": i.pippen_session},
        "storage": {"prefix": f"proofs/{i.environment}/", "bucket": f"{name}-{i.account}-{i.region}-sessions", "role_arn": f"arn:aws:iam::{i.account}:role/storage"},
        "postgres": {"identifier": name + "-pg", "host": f"{name}-pg.abc.{i.region}.rds.amazonaws.com", "secret_arn": f"arn:aws:secretsmanager:{i.region}:{i.account}:secret:rds!db-canary-AbCd12", "resource_arn": f"arn:aws:rds:{i.region}:{i.account}:{'db' if mode == 'rds' else 'cluster'}:{name}-pg", "port": 5432, "database": "relaycontrol", "master_username": "relay_admin", "engine_mode": mode, "backup_retention_days": {"development": 7, "staging": 14, "production": 35}[i.environment_class], "deletion_protection": True},
        "search": {"url": i.search_url, "domain_arn": f"arn:aws:es:{i.region}:{i.account}:domain/{name}-search", "domain_name": name + "-search", "index_prefix": name + "-", "master_role_arn": f"arn:aws:iam::{i.account}:role/admin", "indexer_role_arn": f"arn:aws:iam::{i.account}:role/writer", "reader_role_arn": f"arn:aws:iam::{i.account}:role/reader", "lambda_role_arn": f"arn:aws:iam::{i.account}:role/external/pipeline"},
        "pipeline": {"function_name": name + "-session-pipeline", "function_arn": f"arn:aws:lambda:{i.region}:{i.account}:function:{name}-session-pipeline", "image_uri": None},
    }


def tag_rows(i):
    result = {"Environment": i.environment, "EnvironmentClass": i.environment_class, "ManagedBy": "terraform"}
    if i.pippen_agent is not None:
        result.update({"pippen:sandbox": "true", "pippen:agent": i.pippen_agent, "pippen:session": i.pippen_session})
    return [{"Key": k, "Value": v} for k, v in result.items()]


class NativeSession:
    """Closed in-memory service stubs: never import boto3 or contact AWS."""
    def __init__(self, config=None, confirmed=None):
        self.i = confirmed or installation()
        self.config = config or fixture(confirmed=self.i)
        self.calls = []
        pg = self.config["postgres"]
        self.instance = {"DBInstanceIdentifier": pg["identifier"], "DBInstanceArn": pg["resource_arn"], "PubliclyAccessible": False, "StorageEncrypted": True, "Endpoint": {"Address": pg["host"], "Port": 5432}, "Engine": "postgres", "EngineVersion": "17.6", "DBInstanceStatus": "available", "TagList": tag_rows(self.i), "DBName": "relaycontrol", "BackupRetentionPeriod": pg["backup_retention_days"], "DeletionProtection": True, "MasterUsername": "relay_admin", "MasterUserSecret": {"SecretArn": pg["secret_arn"], "SecretStatus": "active"}}
        self.cluster = {"DBClusterIdentifier": pg["identifier"], "DBClusterArn": pg["resource_arn"], "Engine": "aurora-postgresql", "EngineVersion": "17.6", "Status": "available", "Port": 5432, "DatabaseName": "relaycontrol", "TagList": tag_rows(self.i), "DBClusterMembers": [{"DBInstanceIdentifier": pg["identifier"] + "-1", "IsClusterWriter": True}, {"DBInstanceIdentifier": pg["identifier"] + "-2", "IsClusterWriter": False}], "Endpoint": pg["host"], "StorageEncrypted": True, "BackupRetentionPeriod": pg["backup_retention_days"], "DeletionProtection": True, "MasterUsername": "relay_admin", "MasterUserSecret": {"SecretArn": pg["secret_arn"], "SecretStatus": "active"}}
        self.members = {}
        for m in self.cluster["DBClusterMembers"]:
            n = m["DBInstanceIdentifier"]
            self.members[n] = {**self.instance, "DBInstanceIdentifier": n, "DBInstanceArn": f"arn:aws:rds:{self.i.region}:{self.i.account}:db:{n}", "DBClusterIdentifier": pg["identifier"], "Engine": "aurora-postgresql"}
        p = self.config["pipeline"]
        self.function = {"Configuration": {"FunctionName": p["function_name"], "FunctionArn": p["function_arn"], "Role": self.config["search"]["lambda_role_arn"], "State": "Active", "LastUpdateStatus": "Successful", "Architectures": ["arm64"], "VpcConfig": {"SubnetIds": ["subnet-a"], "SecurityGroupIds": ["sg-a"]}, "CodeSha256": "reviewed", "Runtime": "nodejs24.x", "Timeout": 300}, "Tags": {x["Key"]: x["Value"] for x in tag_rows(self.i)}}
        self.secret_response = {"ARN": pg["secret_arn"], "SecretString": json.dumps({"username": "relay_admin", "password": "synthetic-canary-only"})}
        self.invoke_response = {"StatusCode": 200, "Payload": io.BytesIO(b'{"ok":true}')}
        self.instance_response = None
        self.cluster_response = None
    def client(self, name, **kwargs):
        self.calls.append(("client", name))
        session = self
        class Client:
            def get_caller_identity(self):
                session.calls.append(("get_caller_identity",))
                arn = f"arn:aws:sts::{session.i.account}:assumed-role/deployer/test"
                if session.i.pippen_session:
                    arn = f"arn:aws:sts::{session.i.account}:assumed-role/agent-session/agent-{session.i.pippen_session}"
                return {"Account": session.i.account, "Arn": arn}
            def describe_db_instances(self, **args):
                session.calls.append(("describe_db_instances", args))
                if session.instance_response is not None: return session.instance_response
                return {"DBInstances": [session.members[args["DBInstanceIdentifier"]] if session.config["postgres"]["engine_mode"] == "aurora" else session.instance]}
            def describe_db_clusters(self, **args):
                session.calls.append(("describe_db_clusters", args))
                return session.cluster_response if session.cluster_response is not None else {"DBClusters": [session.cluster]}
            def get_secret_value(self, **args):
                session.calls.append(("get_secret_value", args))
                return session.secret_response
            def get_function(self, **args):
                session.calls.append(("get_function", args))
                return session.function
            def invoke(self, **args):
                session.calls.append(("invoke", args))
                return session.invoke_response
        return Client()


class DataProofRefusalTests(unittest.TestCase):
    def test_exact_installation_and_both_engines_validate(self):
        for mode in ("rds", "aurora"):
            probe.validate(fixture(mode), installation(), RUN)
        c = fixture(); c["pipeline"] = None; c["search"]["lambda_role_arn"] = None
        probe.validate(c, installation(), RUN)
    def test_target_schema_and_separate_confirmation_cannot_select_foreign_installation(self):
        for change in ({"account": "222222222222"}, {"environment": "prod"}, {"name_prefix": "other"}, {"region": "eu-west-1"}, {"environment_class": "staging"}):
            with self.subTest(change=change), self.assertRaises(probe.Failed):
                probe.validate(fixture(), installation(**change), RUN)
        c = fixture(); c["arbitrary"] = True
        with self.assertRaises(probe.Failed): probe.validate(c, installation(), RUN)
        with self.assertRaises(probe.Failed): probe.validate(fixture(), tuple(installation()), RUN)
    def test_production_lambda_and_foreign_installation_rds_are_refused(self):
        for section, key, value in (("pipeline", "function_arn", f"arn:aws:lambda:{REGION}:{ACCOUNT}:function:agent-relay-prod-session-pipeline"), ("pipeline", "function_name", "other-dev-session-pipeline"), ("postgres", "resource_arn", f"arn:aws:rds:{REGION}:{ACCOUNT}:db:other-dev-pg"), ("postgres", "host", "other-dev-pg.abc.us-west-2.rds.amazonaws.com"), ("postgres", "resource_arn", f"arn:aws:rds:{REGION}:{ACCOUNT}:snapshot:agent-relay-dev-pg"), ("pipeline", "function_arn", fixture()["pipeline"]["function_arn"] + ":alias")):
            c = fixture(); c[section][key] = value
            with self.subTest(key=key, value=value), self.assertRaises(probe.Failed): probe.validate(c, installation(), RUN)
    def test_every_phase_and_search_constructor_refuse_unconfirmed_root_without_any_client(self):
        class NoCalls:
            def client(self, *a, **k): raise AssertionError("No SDK client permitted")
        mixed_lambda = fixture(); mixed_lambda["pipeline"]["function_arn"] = f"arn:aws:lambda:{REGION}:{ACCOUNT}:function:agent-relay-prod-session-pipeline"
        mixed_db = fixture(); mixed_db["postgres"]["resource_arn"] = f"arn:aws:rds:{REGION}:{ACCOUNT}:db:other-dev-pg"
        mixed_search = fixture(); mixed_search["search"]["url"] = "https://vpc-agent-relay-dev-search-foreignopaque.us-west-2.es.amazonaws.com"
        for c in (mixed_search, fixture(confirmed=installation(name_prefix="other")), fixture(confirmed=installation(environment="prod")), {**fixture(), "name_prefix": "other"}, mixed_lambda, mixed_db):
            for call in (lambda: probe.configuration(NoCalls(), c, installation=installation()), lambda: probe.postgres(NoCalls(), c, None, installation=installation()), lambda: probe.storage(NoCalls(), c, RUN, installation=installation()), lambda: probe.lambda_smoke(NoCalls(), c, "reviewed", installation=installation()), lambda: probe.Search(NoCalls(), c, installation=installation()), *(lambda phase=p: probe.search_phase(NoCalls(), c, phase, RUN, installation=installation()) for p in ("search-bootstrap", "search-write", "search-read", "search-cleanup"))):
                with self.assertRaises(probe.Failed): call()
    def test_no_legacy_helper_fallback(self):
        for fn, args in ((probe.configuration, (None, fixture())), (probe.postgres, (None, fixture(), None)), (probe.lambda_smoke, (None, fixture(), "reviewed")), (probe.storage, (None, fixture(), RUN)), (probe.search_phase, (None, fixture(), "search-write", RUN)), (probe.Search, (None, fixture()))):
            with self.subTest(helper=fn.__name__), self.assertRaises(TypeError): fn(*args)
    def test_main_rejects_root_before_sdk_session_setup(self):
        with tempfile.TemporaryDirectory() as td:
            config = Path(td)/"config.json"; config.write_text(json.dumps(fixture(confirmed=installation(name_prefix="other"))))
            boto = types.ModuleType("boto3"); boto.Session = lambda **kwargs: self.fail("No SDK session permitted")
            args = ["lambda-smoke", "--config", str(config), "--run-id", RUN, "--confirm-account", ACCOUNT, "--confirm-environment", "dev", "--confirm-region", REGION, "--confirm-environment-class", "development", "--confirm-name-prefix", "agent-relay", "--confirm-search-url", fixture()["search"]["url"], "--confirm-live"]
            with patch.dict("sys.modules", {"boto3": boto}), self.assertRaises(probe.Failed): probe.main(args)
    def test_pippen_confirmation_is_exact_and_cannot_be_omitted(self):
        i = installation(name_prefix="pippen-sbx-ar", pippen_agent="proof", pippen_session="12345678-0000-4000-8000-000000000000")
        c = fixture(confirmed=i); probe.validate(c, i, RUN)
        for candidate in (installation(name_prefix="pippen-sbx-ar"), i._replace(pippen_session="22345678-0000-4000-8000-000000000000")):
            with self.assertRaises(probe.Failed): probe.validate(c, candidate, RUN)
        with self.assertRaises(probe.Failed): probe.confirm_installation(ACCOUNT, REGION, "dev", "development", "agent-relay", fixture()["search"]["url"], "proof", None)
    def test_same_named_domain_opaque_endpoint_is_independently_confirmed(self):
        c = fixture(); c["search"]["url"] = "https://vpc-agent-relay-dev-search-foreignopaque.us-west-2.es.amazonaws.com"
        with self.assertRaises(probe.Failed): probe.validate(c, installation(), RUN)
        # Deliberately selecting a DIFFERENT confirmed origin is an explicit
        # operator decision, never a default copied from untrusted targets.
        reviewed = installation(search_url=c["search"]["url"])
        probe.validate(c, reviewed, RUN)
        for url in ("http://vpc-agent-relay-dev-search-abc.us-west-2.es.amazonaws.com", "https://attacker.example", "https://vpc-agent-relay-dev-search-abc.us-west-2.es.amazonaws.com/path"):
            with self.assertRaises(probe.Failed): installation(search_url=url)
    def test_immutable_confirmation_contains_only_scalars(self):
        i = installation()
        self.assertTrue(all(isinstance(x, str) or x is None for x in i))
        with self.assertRaises(AttributeError): i.name_prefix = "other"
    def test_search_cannot_redirect_signed_requests_elsewhere(self):
        for url in ("http://vpc-agent-relay-dev-search-abc.us-west-2.es.amazonaws.com", "https://attacker.example", "https://vpc-agent-relay-dev-search-abc.us-west-2.es.amazonaws.com@attacker.example", "https://vpc-agent-relay-dev-search-abc.us-west-2.es.amazonaws.com/path", "https://vpc-agent-relay-dev-search-abc.us-west-2.es.amazonaws.com?redirect=1", "https://vpc-other-dev-search-abc.us-west-2.es.amazonaws.com"):
            c = fixture(); c["search"]["url"] = url
            with self.subTest(url=url), self.assertRaises(probe.Failed): probe.validate(c, installation(), RUN)
    def test_runtime_role_cannot_be_search_administrator(self):
        for section, key in (("search", "reader_role_arn"), ("search", "lambda_role_arn"), ("storage", "role_arn")):
            c = fixture(); c["search"]["master_role_arn"] = c[section][key]
            with self.assertRaises(probe.Failed): probe.validate(c, installation(), RUN)
    def test_direct_search_call_rejects_authority_or_control_paths_before_creds_or_imports(self):
        class NoCredentials:
            def get_credentials(self): raise AssertionError("No credentials permitted")
        client = probe.Search(NoCredentials(), fixture(), installation=installation())
        class NoHttp:
            def open(self, *a, **k): raise AssertionError("No HTTP permitted")
        client.http = NoHttp()
        for path in ("@attacker.example", "//attacker.example", "https://attacker.example", "", None, 1, "/x#fragment", "/x\\@attacker.example", "/x\r\nHost: attacker.example", "/x\t", "/x\x7f", "/x\u0085", "/" + "x"*4096):
            with self.subTest(path=path), self.assertRaises(probe.Failed): client.call("GET", path)
    def test_direct_search_wrong_account_or_common_lease_refuses_before_signing(self):
        pippen = installation(name_prefix="pippen-sbx-ar", pippen_agent="proof", pippen_session="12345678-0000-4000-8000-000000000000")
        common = f"arn:aws:sts::{ACCOUNT}:assumed-role/agent-session/agent-12345678-0000-4000-8000-000000000000"
        for i, caller in ((installation(), {"Account": "222222222222", "Arn": "arn:aws:sts::222222222222:assumed-role/reader/runtime"}), (installation(), {"Account": ACCOUNT, "Arn": common}), (pippen, {"Account": ACCOUNT, "Arn": common.replace("12345678", "22345678")}), (installation(), {"Account": ACCOUNT, "Arn": "malformed"}), (installation(), {"Account": ACCOUNT})):
            class Session:
                def client(self, name):
                    self.asserted = name
                    return types.SimpleNamespace(get_caller_identity=lambda: caller)
                def get_credentials(self): raise AssertionError("No credentials/signing permitted")
            client = probe.Search(Session(), fixture(confirmed=i), installation=i)
            client.http = types.SimpleNamespace(open=lambda *a, **k: self.fail("No HTTP permitted"))
            with self.subTest(caller=caller), self.assertRaises(probe.Failed): client.call("GET", "/_cluster/health")
    def test_direct_search_selected_pippen_runtime_caller_reaches_credentials_after_gate(self):
        i = installation(name_prefix="pippen-sbx-ar", pippen_agent="proof", pippen_session="12345678-0000-4000-8000-000000000000")
        class ReachedCredentials(Exception): pass
        class Session:
            def client(self, name):
                return types.SimpleNamespace(get_caller_identity=lambda: {"Account": ACCOUNT, "Arn": f"arn:aws:sts::{ACCOUNT}:assumed-role/protected-reader/runtime"})
            def get_credentials(self): raise ReachedCredentials()
        client = probe.Search(Session(), fixture(confirmed=i), installation=i)
        auth = types.ModuleType("botocore.auth"); auth.SigV4Auth = lambda *a: None
        request = types.ModuleType("botocore.awsrequest"); request.AWSRequest = lambda **kwargs: types.SimpleNamespace(**kwargs)
        with patch.dict("sys.modules", {"botocore.auth": auth, "botocore.awsrequest": request}), self.assertRaises(ReachedCredentials): client.call("GET", "/_cluster/health")
    def test_direct_search_legitimate_query_keeps_origin_and_signs_only_after_gate(self):
        sent = []
        class Session:
            def client(self, name):
                assert name == "sts"
                return types.SimpleNamespace(get_caller_identity=lambda: {"Account": ACCOUNT, "Arn": f"arn:aws:sts::{ACCOUNT}:assumed-role/reader/runtime"})
            def get_credentials(self): return types.SimpleNamespace(get_frozen_credentials=lambda: "synthetic")
        aws_module = types.ModuleType("botocore.awsrequest")
        aws_module.AWSRequest = lambda **kwargs: types.SimpleNamespace(**kwargs)
        auth_module = types.ModuleType("botocore.auth")
        auth_module.SigV4Auth = lambda *a: types.SimpleNamespace(add_auth=lambda request: sent.append(request.url))
        class Response:
            status = 200
            def __enter__(self): return self
            def __exit__(self, *a): pass
            def read(self, bound): return b'{"ok":true}'
        c = fixture(); client = probe.Search(Session(), c, installation=installation())
        client.http = types.SimpleNamespace(open=lambda *a, **k: Response())
        with patch.dict("sys.modules", {"botocore.awsrequest": aws_module, "botocore.auth": auth_module}):
            self.assertEqual(client.call("PUT", "/agent-relay-dev-proof/_doc/accepted?refresh=true", {}), (200, {"ok": True}))
        self.assertEqual(sent, [c["search"]["url"] + "/agent-relay-dev-proof/_doc/accepted?refresh=true"])
    def test_unknown_search_phase_is_refused_before_any_client(self):
        with self.assertRaises(probe.Failed): probe.search_phase(None, fixture(), "arbitrary", RUN, installation=installation())


class NativeGates(unittest.TestCase):
    def setUp(self):
        self.ca = Path(__file__) # Offline public stand-in; connect is always stubbed.
    def assert_no_sensitive(self, session):
        self.assertFalse(any(c[0] in ("get_secret_value", "invoke") for c in session.calls))
    def test_missing_rds_ca_does_not_make_any_client(self):
        s = NativeSession()
        with self.assertRaises(probe.Failed): probe.postgres(s, s.config, None, installation=s.i)
        self.assertEqual(s.calls, [])
    def test_rds_native_wrong_environment_tags_or_secret_linkage_never_reads_secret(self):
        cases = ({"MasterUsername": "foreign"}, {"DBInstanceIdentifier": "foreign"}, {"DBInstanceArn": "foreign"}, {"Engine": "mysql"}, {"EngineVersion": "16.6"}, {"DBName": "foreign"}, {"DBInstanceStatus": "creating"}, {"PubliclyAccessible": True}, {"Endpoint": {"Address": "foreign", "Port": 5432}}, {"MasterUserSecret": {"SecretArn": "foreign", "SecretStatus": "active"}}, {"MasterUserSecret": {"SecretArn": fixture()["postgres"]["secret_arn"], "SecretStatus": "rotating"}}, {"TagList": []}, {"TagList": tag_rows(installation(environment="prod"))}, {"TagList": tag_rows(installation(environment_class="staging"))}, {"TagList": [{"Key": "ManagedBy", "Value": "foreign"}]}, {"TagList": tag_rows(installation()) * 2}, {"TagList": None})
        for change in cases:
            s = NativeSession(); s.instance.update(change)
            with self.subTest(change=change), self.assertRaises((probe.Failed, KeyError, TypeError)): probe.postgres(s, s.config, self.ca, installation=s.i)
            self.assert_no_sensitive(s)
    def test_rds_empty_duplicate_malformed_or_denied_native_read_never_reads_secret(self):
        for response in ({"DBInstances": []}, {"DBInstances": [{}, {}]}, {"DBInstances": None}, {}):
            s = NativeSession(); s.instance_response = response
            with self.assertRaises((probe.Failed, KeyError, TypeError)): probe.postgres(s, s.config, self.ca, installation=s.i)
            self.assert_no_sensitive(s)
        s = NativeSession()
        with patch.object(s, "client", side_effect=PermissionError("synthetic denied")), self.assertRaises(PermissionError): probe.postgres(s, s.config, self.ca, installation=s.i)
        self.assert_no_sensitive(s)
    def test_pippen_native_owner_tags_are_required_before_secret(self):
        i = installation(name_prefix="pippen-sbx-ar", pippen_agent="proof", pippen_session="12345678-0000-4000-8000-000000000000")
        for field in ("pippen:sandbox", "pippen:agent", "pippen:session"):
            s = NativeSession(confirmed=i); s.instance["TagList"] = [x for x in s.instance["TagList"] if x["Key"] != field]
            with self.assertRaises(probe.Failed): probe.postgres(s, s.config, self.ca, installation=i)
            self.assert_no_sensitive(s)
    def test_aurora_cluster_and_every_member_are_bound_before_secret(self):
        for target, change in (("cluster", {"DBClusterArn": "foreign"}), ("cluster", {"TagList": []}), ("cluster", {"DBClusterMembers": []}), ("cluster", {"DBClusterMembers": [{"DBInstanceIdentifier": "foreign-1", "IsClusterWriter": True}]}), ("cluster", {"MasterUserSecret": {"SecretArn": "foreign", "SecretStatus": "active"}}), ("member", {"DBClusterIdentifier": "foreign"}), ("member", {"DBInstanceArn": "foreign"}), ("member", {"TagList": []}), ("member", {"PubliclyAccessible": True}), ("member", {"Engine": "postgres"})):
            s = NativeSession(fixture("aurora")); row = s.cluster if target == "cluster" else next(iter(s.members.values())); row.update(change)
            with self.subTest(target=target, change=change), self.assertRaises((probe.Failed, KeyError, TypeError)): probe.postgres(s, s.config, self.ca, installation=s.i)
            self.assert_no_sensitive(s)
        for kind in ("duplicate", "no_writer", "two_writers"):
            s = NativeSession(fixture("aurora"))
            if kind == "duplicate": s.cluster["DBClusterMembers"] *= 2
            else:
                for m in s.cluster["DBClusterMembers"]: m["IsClusterWriter"] = kind == "two_writers"
            with self.assertRaises(probe.Failed): probe.postgres(s, s.config, self.ca, installation=s.i)
            self.assert_no_sensitive(s)
    def test_rds_and_aurora_positive_native_path_and_tls_query(self):
        for mode in ("rds", "aurora"):
            s = NativeSession(fixture(mode)); pg = types.ModuleType("psycopg"); pg.connect = MagicMock()
            cursor = pg.connect.return_value.__enter__.return_value.cursor.return_value.__enter__.return_value
            cursor.fetchone.side_effect = [("relaycontrol", 170006, True), ("authenticated-private-tls",)]
            with patch.dict("sys.modules", {"psycopg": pg}): probe.postgres(s, s.config, self.ca, installation=s.i)
            self.assertEqual(sum(c[0] == "get_secret_value" for c in s.calls), 1)
            self.assertEqual(pg.connect.call_args.kwargs["sslmode"], "verify-full")
            self.assertEqual(pg.connect.call_args.kwargs["host"], s.config["postgres"]["host"])
    def test_secret_response_arn_and_master_username_checked_before_sql(self):
        for change in ({"ARN": "foreign"}, {"SecretString": '{"username":"foreign","password":"synthetic"}'}):
            s = NativeSession(); s.secret_response.update(change); pg = types.ModuleType("psycopg"); pg.connect = lambda **kwargs: self.fail("No SQL permitted")
            with patch.dict("sys.modules", {"psycopg": pg}), self.assertRaises(probe.Failed): probe.postgres(s, s.config, self.ca, installation=s.i)
    def test_lambda_name_role_tags_artifact_must_pass_before_invoke(self):
        for change in ({"FunctionName": "foreign"}, {"FunctionArn": "foreign"}, {"Role": f"arn:aws:iam::{ACCOUNT}:role/foreign"}, {"CodeSha256": "different"}, {"State": "Pending"}, {"Runtime": "nodejs22.x"}):
            s = NativeSession(); s.function["Configuration"].update(change)
            with self.subTest(change=change), self.assertRaises(probe.Failed): probe.lambda_smoke(s, s.config, "reviewed", installation=s.i)
            self.assert_no_sensitive(s)
        for tags in ({}, {"Environment": "prod"}, {**NativeSession().function["Tags"], "EnvironmentClass": "production"}, {**NativeSession().function["Tags"], "ManagedBy": "foreign"}, None):
            s = NativeSession(); s.function["Tags"] = tags
            with self.assertRaises(probe.Failed): probe.lambda_smoke(s, s.config, "reviewed", installation=s.i)
            self.assert_no_sensitive(s)
    def test_lambda_tag_error_even_with_partial_tags_prevents_invoke(self):
        s = NativeSession(); s.function["TagsError"] = {"ErrorCode": "AccessDenied", "Message": "synthetic"}
        with self.assertRaises(probe.Failed): probe.lambda_smoke(s, s.config, "reviewed", installation=s.i)
        self.assert_no_sensitive(s)
    def test_external_lambda_role_binding_remains_supported_without_iam_authority_claim(self):
        s = NativeSession(); cfg = types.ModuleType("botocore.config"); cfg.Config = lambda **kwargs: kwargs
        with patch.dict("sys.modules", {"botocore.config": cfg}): probe.lambda_smoke(s, s.config, "reviewed", installation=s.i)
        self.assertEqual(sum(c[0] == "invoke" for c in s.calls), 1)
    def test_pippen_caller_cannot_opt_out_of_lease_by_stripping_config_markers(self):
        s = NativeSession()
        original = s.client
        def client(name, **kwargs):
            c = original(name, **kwargs)
            if name == "sts": c.get_caller_identity = lambda: {"Account": ACCOUNT, "Arn": f"arn:aws:sts::{ACCOUNT}:assumed-role/agent-session/agent-12345678-0000-4000-8000-000000000000"}
            return c
        with patch.object(s, "client", client), self.assertRaises(probe.Failed): probe.lambda_smoke(s, s.config, "reviewed", installation=s.i)
        self.assert_no_sensitive(s)
    def test_lambda_pippen_tags_and_denied_or_malformed_native_read_prevent_invoke(self):
        i = installation(name_prefix="pippen-sbx-ar", pippen_agent="proof", pippen_session="12345678-0000-4000-8000-000000000000")
        for field in ("pippen:sandbox", "pippen:agent", "pippen:session"):
            s = NativeSession(confirmed=i); del s.function["Tags"][field]
            with self.assertRaises(probe.Failed): probe.lambda_smoke(s, s.config, "reviewed", installation=i)
            self.assert_no_sensitive(s)
        for response in (None, {}, {"Configuration": []}):
            s = NativeSession(); s.function = response
            with self.assertRaises((probe.Failed, KeyError, TypeError)): probe.lambda_smoke(s, s.config, "reviewed", installation=s.i)
            self.assert_no_sensitive(s)
        s = NativeSession(); original = s.client
        def client(name, **kwargs):
            c = original(name, **kwargs)
            if name == "lambda": c.get_function = lambda **kwargs: (_ for _ in ()).throw(PermissionError("synthetic denied"))
            return c
        with patch.object(s, "client", client), self.assertRaises(PermissionError): probe.lambda_smoke(s, s.config, "reviewed", installation=s.i)
        self.assert_no_sensitive(s)
    def test_lambda_function_error_is_failure_even_with_http_200(self):
        s = NativeSession(); s.invoke_response = {"StatusCode": 200, "FunctionError": "Unhandled", "Payload": io.BytesIO(b'{"ok":true}')}
        cfg = types.ModuleType("botocore.config"); cfg.Config = lambda **kwargs: kwargs
        with patch.dict("sys.modules", {"botocore.config": cfg}), self.assertRaises(probe.Failed): probe.lambda_smoke(s, s.config, "reviewed", installation=s.i)


class S3OwnerBinding(unittest.TestCase):
    def session(self, refuse=False):
        calls = []; c = fixture()
        class Client:
            def get_caller_identity(self): return {"Account": ACCOUNT, "Arn": f"arn:aws:sts::{ACCOUNT}:assumed-role/storage/test"}
            def operation(self, name, kwargs):
                calls.append((name, kwargs))
                if kwargs.get("ExpectedBucketOwner") != ACCOUNT: raise AssertionError("Every S3 operation must bind the confirmed owner")
                if refuse: raise PermissionError("synthetic expected owner refusal")
                return {"get_public_access_block": {"PublicAccessBlockConfiguration": {k: True for k in ("BlockPublicAcls", "IgnorePublicAcls", "BlockPublicPolicy", "RestrictPublicBuckets")}}, "get_bucket_versioning": {"Status": "Enabled"}, "get_bucket_encryption": {"ServerSideEncryptionConfiguration": {"Rules": [{"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "aws:kms"}, "BucketKeyEnabled": True}]}}, "get_bucket_policy": {"Policy": '{"Statement":[{"Effect":"Deny","Condition":{"Bool":{"aws:SecureTransport":"false"}}}]}'}, "put_object": {}, "get_object": {"Body": io.BytesIO(json.dumps({"marker": RUN}).encode())}, "list_objects_v2": {"Contents": [{"Key": c["storage"]["prefix"] + RUN + "/marker.json"}]}, "delete_object": {}}[name]
            def __getattr__(self, name): return lambda **kwargs: self.operation(name, kwargs)
        class Domain:
            def describe_domain(self, **kwargs): return {"DomainStatus": {"ARN": c["search"]["domain_arn"], "Endpoints": {"vpc": c["search"]["url"].split("//")[1]}, "VPCOptions": {"VPCId": "vpc-synthetic"}, "DomainEndpointOptions": {"EnforceHTTPS": True}, "EncryptionAtRestOptions": {"Enabled": True}, "NodeToNodeEncryptionOptions": {"Enabled": True}, "AdvancedSecurityOptions": {"Enabled": True}}}
        return types.SimpleNamespace(client=lambda name, **kwargs: Domain() if name == "opensearch" else Client()), calls
    def test_every_configuration_and_object_api_binds_confirmed_owner(self):
        s, calls = self.session(); probe.configuration(s, fixture(), installation=installation()); probe.storage(s, fixture(), RUN, installation=installation())
        self.assertEqual({n for n, _ in calls}, {"get_public_access_block", "get_bucket_versioning", "get_bucket_encryption", "get_bucket_policy", "put_object", "get_object", "list_objects_v2", "delete_object"})
        self.assertTrue(all(kwargs["ExpectedBucketOwner"] == ACCOUNT for _, kwargs in calls))
    def test_foreign_owner_refusal_never_becomes_success_or_unbound_cleanup(self):
        for phase in ("configuration", "storage"):
            s, calls = self.session(refuse=True)
            with self.assertRaises(PermissionError):
                if phase == "configuration": probe.configuration(s, fixture(), installation=installation())
                else: probe.storage(s, fixture(), RUN, installation=installation())
            self.assertTrue(calls and all(kwargs["ExpectedBucketOwner"] == ACCOUNT for _, kwargs in calls))
            self.assertFalse(any(name in ("get_object", "list_objects_v2") for name, _ in calls))


class Acknowledgements(unittest.TestCase):
    def test_bulk_http_success_is_not_a_write_refusal(self):
        self.assertTrue(probe.bulk_is_refused(403, {}))
        self.assertTrue(probe.bulk_is_refused(200, {"errors": True, "items": [{"index": {"status": 403}}]}))
        for body in ({}, {"errors": False, "items": [{"index": {"status": 201}}]}, {"errors": True, "items": []}, {"errors": True, "items": [{"index": {"status": 403}}, {"index": {"status": 201}}]}): self.assertFalse(probe.bulk_is_refused(200, body))
    def test_signed_http_redirects_are_not_followed(self):
        self.assertIsNone(probe.NoRedirect().redirect_request(None, None, 302, "Found", {}, "https://attacker.example"))
    def test_http_success_requires_real_service_acknowledgement(self):
        for check, args in ((probe.index_ack, (200, {})), (probe.security_ack, (200, {"status": "ERROR"})), (probe.document_ack, (201, {"result": "created", "_index": "wrong", "_id": "accepted", "_shards": {"failed": 0}}, "expected", "accepted"))):
            with self.subTest(check=check.__name__), self.assertRaises(probe.Failed): check(*args)
        probe.index_ack(200, {"acknowledged": True}); probe.security_ack(201, {"status": "CREATED"})
        probe.document_ack(201, {"result": "created", "_index": "expected", "_id": "accepted", "_shards": {"failed": 0}}, "expected", "accepted")
    def test_iam_role_path_and_sts_identity_must_match_account_and_role(self):
        expected = f"arn:aws:iam::{ACCOUNT}:role/pippen/workload/reader"
        self.assertTrue(probe.role_matches(f"arn:aws:sts::{ACCOUNT}:assumed-role/reader/session", expected))
        self.assertFalse(probe.role_matches("arn:aws:sts::222222222222:assumed-role/reader/session", expected))
        self.assertFalse(probe.role_matches(f"arn:aws:sts::{ACCOUNT}:assumed-role/admin/session", expected))

if __name__ == "__main__": unittest.main()
