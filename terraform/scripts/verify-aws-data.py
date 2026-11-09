#!/usr/bin/env python3
"""Private-runner RDS/S3/OpenSearch data-path checks against Terraform outputs.

Uses boto3 and psycopg[binary] supplied by the approved verification runner.
Every live invocation needs a separately confirmed installation identity. Secret
values stay in process memory; this emits only bounded non-secret receipts.
"""
import argparse
import json
from pathlib import Path
import re
import ssl
import sys
from typing import NamedTuple, Optional
from urllib.error import HTTPError
from urllib.parse import urlsplit
from urllib.request import Request, build_opener, HTTPSHandler, ProxyHandler, HTTPRedirectHandler


class Failed(Exception):
    pass


def require(condition):
    if not condition:
        raise Failed("Verification gate failed")


class ConfirmedInstallation(NamedTuple):
    """Operator-supplied installation identity, separate from exported targets.

    This is an explicit confirmation, not IAM authorization or attestation.
    Every phase revalidates it and the untrusted exported configuration.
    """
    account: str
    region: str
    environment: str
    environment_class: str
    name_prefix: str
    search_url: str
    pippen_agent: Optional[str] = None
    pippen_session: Optional[str] = None


def matches(pattern, value):
    return isinstance(value, str) and re.fullmatch(pattern, value) is not None


def confirm_installation(account, region, environment, environment_class, name_prefix, search_url, pippen_agent=None, pippen_session=None):
    require(matches(r"[0-9]{12}", account))
    require(matches(r"[a-z]{2}(?:-[a-z]+)+-[0-9]+", region))
    require(matches(r"[a-z][a-z0-9]*(?:-[a-z0-9]+)*", environment) and len(environment) <= 16)
    require(environment_class in ("development", "staging", "production"))
    require(matches(r"[a-z][a-z0-9]*(?:-[a-z0-9]+)*", name_prefix) and len(name_prefix + "-" + environment) <= 21)
    require(isinstance(search_url, str))
    origin = urlsplit(search_url)
    require(origin.scheme == "https" and origin.port in (None, 443) and origin.username is None and origin.password is None and origin.path in ("", "/") and not origin.query and not origin.fragment)
    require(matches(rf"vpc-{re.escape(name_prefix + '-' + environment)}-search-[a-z0-9]+\.{re.escape(region)}\.es\.amazonaws\.com", origin.hostname))
    require((pippen_agent is None) == (pippen_session is None))
    if pippen_agent is not None:
        require(name_prefix.startswith("pippen-sbx-") and matches(r"[a-z0-9][a-z0-9-]{1,40}", pippen_agent))
        require(matches(r"[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}", pippen_session))
    return ConfirmedInstallation(account, region, environment, environment_class, name_prefix, search_url, pippen_agent, pippen_session)


def fields(value, keys):
    require(isinstance(value, dict) and set(value) == set(keys))


def validate(config, installation, run_id=None):
    require(isinstance(installation, ConfirmedInstallation))
    confirm_installation(*installation) # Reject invalid directly constructed tuples too.
    account, region, environment, environment_class, prefix, search_url, agent, lease = installation
    if run_id is not None:
        require(matches(r"[0-9a-f]{32}", run_id))
    fields(config, ("account_id", "region", "environment", "environment_class", "name_prefix", "pippen", "postgres", "storage", "search", "pipeline"))
    require((config["account_id"], config["region"], config["environment"], config["environment_class"], config["name_prefix"]) == installation[:5])
    require(config["pippen"] == (None if agent is None else {"agent": agent, "session_id": lease}))
    name = prefix + "-" + environment
    search, pg, storage = (config[k] for k in ("search", "postgres", "storage"))
    fields(search, ("url", "domain_name", "domain_arn", "index_prefix", "master_role_arn", "indexer_role_arn", "reader_role_arn", "lambda_role_arn"))
    fields(pg, ("identifier", "host", "port", "database", "master_username", "secret_arn", "resource_arn", "engine_mode", "deletion_protection", "backup_retention_days"))
    fields(storage, ("bucket", "prefix", "role_arn"))
    require(search["domain_name"] == name + "-search" and search["index_prefix"] == name + "-")
    require(search["domain_arn"] == f"arn:aws:es:{region}:{account}:domain/{name}-search")
    require(search["url"] == search_url)
    url = urlsplit(search["url"])
    require(url.scheme == "https" and url.port in (None, 443) and url.username is None and url.password is None and url.path in ("", "/") and not url.query and not url.fragment)
    require(matches(rf"vpc-{re.escape(name)}-search-[a-z0-9]+\.{re.escape(region)}\.es\.amazonaws\.com", url.hostname))
    role_pattern = rf"arn:aws:iam::{account}:role/(?:[A-Za-z0-9+=,.@_-]+/)*[A-Za-z0-9+=,.@_-]+"
    for key in ("master_role_arn", "indexer_role_arn", "reader_role_arn"):
        require(matches(role_pattern, search[key]))
    require(len({search[k] for k in ("master_role_arn", "indexer_role_arn", "reader_role_arn")}) == 3)
    require(storage["prefix"] == f"proofs/{environment}/" and storage["bucket"] == f"{name}-{account}-{region}-sessions")
    require(len(storage["bucket"]) <= 63 and matches(role_pattern, storage["role_arn"]) and storage["role_arn"] != search["master_role_arn"])
    require(pg["engine_mode"] in ("rds", "aurora") and pg["identifier"] == name + "-pg")
    kind = "db" if pg["engine_mode"] == "rds" else "cluster"
    require(pg["resource_arn"] == f"arn:aws:rds:{region}:{account}:{kind}:{name}-pg")
    require(matches(rf"{re.escape(name)}-pg\.[a-z0-9-]+\.{re.escape(region)}\.rds\.amazonaws\.com", pg["host"]))
    require(matches(rf"arn:aws:secretsmanager:{region}:{account}:secret:[A-Za-z0-9/_+=.@!-]+-[A-Za-z0-9]{{6}}", pg["secret_arn"]))
    require(pg["port"] == 5432 and type(pg["port"]) is int and pg["database"] == "relaycontrol" and pg["master_username"] == "relay_admin")
    require(type(pg["deletion_protection"]) is bool and pg["backup_retention_days"] == {"development": 7, "staging": 14, "production": 35}[environment_class])
    require(environment_class != "production" or pg["deletion_protection"] is True)
    pipeline = config["pipeline"]
    if pipeline is not None:
        fields(pipeline, ("function_name", "function_arn", "image_uri"))
        function_name = name + "-session-pipeline"
        require(pipeline["function_name"] == function_name and pipeline["function_arn"] == f"arn:aws:lambda:{region}:{account}:function:{function_name}")
        require(pipeline["image_uri"] is None or matches(r"[^\s]+@sha256:[a-f0-9]{64}", pipeline["image_uri"]))
        require(matches(role_pattern, search["lambda_role_arn"]) and search["lambda_role_arn"] not in (search["master_role_arn"], search["reader_role_arn"]))
    else:
        require(search["lambda_role_arn"] is None)
    return config


def native_tags(rows, installation):
    require(isinstance(rows, list) and all(isinstance(row, dict) and set(row) == {"Key", "Value"} and isinstance(row["Key"], str) and isinstance(row["Value"], str) for row in rows))
    require(len({row["Key"] for row in rows}) == len(rows))
    values = {row["Key"]: row["Value"] for row in rows}
    expected = {"Environment": installation.environment, "EnvironmentClass": installation.environment_class, "ManagedBy": "terraform"}
    if installation.pippen_agent is not None:
        expected.update({"pippen:sandbox": "true", "pippen:agent": installation.pippen_agent, "pippen:session": installation.pippen_session})
    else:
        require(not any(key.startswith("pippen:") for key in values))
    require(all(values.get(key) == value for key, value in expected.items()))


def phase_identity(session, config, installation, run_id=None, role=None):
    validate(config, installation, run_id) # Always before creating even an SDK client.
    caller = session.client("sts").get_caller_identity()
    require(caller["Account"] == installation.account and matches(rf"arn:aws:(?:sts|iam)::{installation.account}:[A-Za-z0-9+=,.@_/-]+", caller["Arn"]))
    if installation.pippen_session is None:
        require(not matches(r"arn:aws:sts::[0-9]{12}:assumed-role/agent-session/[^/]+", caller["Arn"]))
    if installation.pippen_session is not None and role is None:
        require(caller["Arn"] == f"arn:aws:sts::{installation.account}:assumed-role/agent-session/agent-{installation.pippen_session}")
    if role is not None:
        require(role_matches(caller["Arn"], role))


def role_matches(caller, expected):
    if caller == expected:
        return True
    match = re.fullmatch(r"arn:aws:sts::([0-9]{12}):assumed-role/([^/]+)/[^/]+", caller)
    role = re.fullmatch(r"arn:aws:iam::([0-9]{12}):role/(.+)", expected)
    return bool(match and role and match[1] == role[1] and match[2] == role[2].split("/")[-1])


def bulk_is_refused(status, body):
    if status == 403:
        return True
    if status != 200 or not isinstance(body, dict) or body.get("errors") is not True:
        return False
    items = body.get("items")
    return isinstance(items, list) and len(items) == 1 and isinstance(items[0], dict) and isinstance(items[0].get("index"), dict) and items[0]["index"].get("status") == 403


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, newurl):
        # Never forward a signed request or its session token to another URL.
        return None


def security_ack(status, body):
    require(status in (200, 201) and isinstance(body, dict) and body.get("status") in ("CREATED", "OK"))


def index_ack(status, body):
    require(status == 200 and isinstance(body, dict) and body.get("acknowledged") is True)


def document_ack(status, body, index, identifier):
    require(status in (200, 201) and isinstance(body, dict) and body.get("result") in ("created", "updated") and body.get("_index") == index and body.get("_id") == identifier and body.get("_shards", {}).get("failed") == 0)


class Search:
    def __init__(self, session, config, *, installation):
        validate(config, installation)
        self.installation = installation # Immutable scalar confirmation; no nested target config.
        self.session, self.url, self.region = session, config["search"]["url"].rstrip("/"), installation.region
        self.http = build_opener(ProxyHandler({}), NoRedirect(), HTTPSHandler(context=ssl.create_default_context()))

    def call(self, method, path, body=None, ndjson=False):
        # A direct-import caller must not turn the approved base into userinfo
        # (e.g. base + "@foreign") or introduce alternate URL interpretation.
        require(isinstance(path, str) and 1 <= len(path) <= 4096 and path.startswith("/") and not path.startswith("//"))
        require(all(0x21 <= ord(character) <= 0x7e for character in path) and "\\" not in path and "#" not in path)
        require(method in ("GET", "HEAD", "POST", "PUT", "DELETE", "PATCH"))
        require(self.url == self.installation.search_url.rstrip("/"))
        origin, target = urlsplit(self.url), urlsplit(self.url + path)
        require(target.scheme == origin.scheme == "https" and target.netloc == origin.netloc and target.hostname == origin.hostname)
        require(target.username is None and target.password is None and origin.username is None and origin.password is None and not target.fragment)
        # Direct imports cannot bypass the account/common-lease gate. Exact
        # phase-role checks remain in search_phase; this is not IAM authority.
        caller = self.session.client("sts").get_caller_identity()
        account = self.installation.account
        require(isinstance(caller, dict) and caller.get("Account") == account and matches(rf"arn:aws:(?:sts|iam)::{account}:[A-Za-z0-9+=,.@_/-]+", caller.get("Arn")))
        if matches(rf"arn:aws:sts::{account}:assumed-role/agent-session/[^/]+", caller["Arn"]):
            require(self.installation.pippen_session is not None and caller["Arn"] == f"arn:aws:sts::{account}:assumed-role/agent-session/agent-{self.installation.pippen_session}")
        from botocore.auth import SigV4Auth
        from botocore.awsrequest import AWSRequest
        data = body.encode() if ndjson else (json.dumps(body).encode() if body is not None else None)
        headers = {"Content-Type": "application/x-ndjson" if ndjson else "application/json"}
        aws = AWSRequest(method=method, url=target.geturl(), data=data, headers=headers)
        credentials = self.session.get_credentials()
        require(credentials is not None)
        SigV4Auth(credentials.get_frozen_credentials(), "es", self.region).add_auth(aws)
        request = Request(aws.url, data=data, headers=dict(aws.headers.items()), method=method)
        try:
            with self.http.open(request, timeout=30) as response:
                status, raw = response.status, response.read(2_000_001)
        except HTTPError as error:
            status, raw = error.code, error.read(2_000_001)
        require(len(raw) <= 2_000_000 and not 300 <= status < 400)
        try:
            result = json.loads(raw) if raw else {}
        except (ValueError, UnicodeError) as exc:
            raise Failed("Non-JSON service response") from exc
        return status, result


def postgres(session, config, ca_path, *, installation):
    validate(config, installation)
    require(ca_path is not None and ca_path.is_file())
    phase_identity(session, config, installation)
    pg = config["postgres"]
    arn, identifier = pg["resource_arn"], pg["identifier"]
    rds = session.client("rds")
    def one(response, key):
        rows = response[key]
        require(isinstance(rows, list) and len(rows) == 1 and isinstance(rows[0], dict))
        return rows[0]
    def instance(row, expected, engine):
        require(row["DBInstanceIdentifier"] == expected and row["DBInstanceArn"] == f"arn:aws:rds:{installation.region}:{installation.account}:db:{expected}")
        require(row["Engine"] == engine and matches(r"17(?:\.[0-9]+)*", row["EngineVersion"]) and row["DBInstanceStatus"] == "available")
        require(row["PubliclyAccessible"] is False and row["StorageEncrypted"] is True and row["Endpoint"]["Port"] == pg["port"])
        native_tags(row["TagList"], installation)
    if pg["engine_mode"] == "rds":
        database = one(rds.describe_db_instances(DBInstanceIdentifier=identifier), "DBInstances")
        instance(database, identifier, "postgres")
        require(database["DBName"] == pg["database"] and not database.get("DBClusterIdentifier"))
        host = database["Endpoint"]["Address"]
    else:
        database = one(rds.describe_db_clusters(DBClusterIdentifier=identifier), "DBClusters")
        require(database["DBClusterIdentifier"] == identifier and database["DBClusterArn"] == arn and database["Engine"] == "aurora-postgresql" and matches(r"17(?:\.[0-9]+)*", database["EngineVersion"]) and database["Status"] == "available")
        require(database["Port"] == pg["port"] and database["DatabaseName"] == pg["database"])
        native_tags(database["TagList"], installation)
        members = database["DBClusterMembers"]
        require(isinstance(members, list) and 1 <= len(members) <= 16 and all(isinstance(m, dict) and matches(rf"{re.escape(identifier)}-[1-9][0-9]*", m.get("DBInstanceIdentifier")) and type(m.get("IsClusterWriter")) is bool for m in members))
        require(len({m["DBInstanceIdentifier"] for m in members}) == len(members) and sum(m["IsClusterWriter"] for m in members) == 1)
        for member in members:
            row = one(rds.describe_db_instances(DBInstanceIdentifier=member["DBInstanceIdentifier"]), "DBInstances")
            instance(row, member["DBInstanceIdentifier"], "aurora-postgresql")
            require(row["DBClusterIdentifier"] == identifier)
        host = database["Endpoint"]
    require(host == pg["host"] and database["MasterUserSecret"]["SecretArn"] == pg["secret_arn"] and database["MasterUserSecret"]["SecretStatus"] == "active")
    require(database["StorageEncrypted"] is True and type(database["BackupRetentionPeriod"]) is int and database["BackupRetentionPeriod"] == pg["backup_retention_days"] and database["DeletionProtection"] is pg["deletion_protection"])
    require(database["MasterUsername"] == pg["master_username"])
    # No secret API or SQL driver import occurs until ALL native identity gates pass.
    reply = session.client("secretsmanager").get_secret_value(SecretId=pg["secret_arn"])
    require(reply["ARN"] == pg["secret_arn"])
    secret = json.loads(reply["SecretString"])
    require(isinstance(secret, dict) and secret.get("username") == database["MasterUsername"] and isinstance(secret.get("password"), str) and secret["password"])
    import psycopg
    with psycopg.connect(host=host, port=pg["port"], dbname=pg["database"], user=secret["username"], password=secret["password"], sslmode="verify-full", sslrootcert=str(ca_path.resolve()), connect_timeout=15) as connection:
        with connection.cursor() as cursor:
            cursor.execute("SELECT current_database(), current_setting('server_version_num')::int, ssl FROM pg_stat_ssl WHERE pid=pg_backend_pid()")
            row = cursor.fetchone()
            require(row is not None and row[0] == pg["database"] and 170000 <= row[1] < 180000 and row[2] is True)
            cursor.execute("CREATE TEMP TABLE agent_relay_connection_proof (marker text) ON COMMIT DROP")
            cursor.execute("INSERT INTO agent_relay_connection_proof VALUES (%s)", ("authenticated-private-tls",))
            cursor.execute("SELECT marker FROM agent_relay_connection_proof")
            require(cursor.fetchone() == ("authenticated-private-tls",))


def configuration(session, config, *, installation):
    phase_identity(session, config, installation)
    client = session.client("s3")
    bucket = config["storage"]["bucket"]
    public = client.get_public_access_block(Bucket=bucket, ExpectedBucketOwner=installation.account)["PublicAccessBlockConfiguration"]
    require(all(public.get(k) is True for k in ("BlockPublicAcls", "IgnorePublicAcls", "BlockPublicPolicy", "RestrictPublicBuckets")))
    require(client.get_bucket_versioning(Bucket=bucket, ExpectedBucketOwner=installation.account).get("Status") == "Enabled")
    rules = client.get_bucket_encryption(Bucket=bucket, ExpectedBucketOwner=installation.account)["ServerSideEncryptionConfiguration"]["Rules"]
    require(len(rules) == 1 and rules[0]["ApplyServerSideEncryptionByDefault"]["SSEAlgorithm"] == "aws:kms" and rules[0].get("BucketKeyEnabled") is True)
    policy = json.loads(client.get_bucket_policy(Bucket=bucket, ExpectedBucketOwner=installation.account)["Policy"])
    require(any(s.get("Effect") == "Deny" and s.get("Condition", {}).get("Bool", {}).get("aws:SecureTransport") in (False, "false") for s in policy.get("Statement", [])))
    search = config["search"]
    domain = session.client("opensearch").describe_domain(DomainName=search["domain_name"])["DomainStatus"]
    require(domain["ARN"] == search["domain_arn"] and domain["Endpoints"]["vpc"] == urlsplit(search["url"]).hostname and domain["VPCOptions"].get("VPCId"))
    require(domain["DomainEndpointOptions"]["EnforceHTTPS"] and domain["EncryptionAtRestOptions"]["Enabled"] and domain["NodeToNodeEncryptionOptions"]["Enabled"] and domain["AdvancedSecurityOptions"]["Enabled"])


def lambda_smoke(session, config, code_sha, *, installation):
    phase_identity(session, config, installation)
    pipeline = config.get("pipeline")
    require(isinstance(pipeline, dict))
    client = session.client("lambda")
    function = client.get_function(FunctionName=pipeline["function_arn"])
    deployed = function["Configuration"]
    require(deployed["FunctionName"] == pipeline["function_name"] and deployed["Role"] == config["search"]["lambda_role_arn"])
    require(isinstance(function.get("Tags"), dict) and function.get("TagsError") is None)
    native_tags([{"Key": key, "Value": value} for key, value in function["Tags"].items()], installation)
    require(deployed["FunctionArn"] == pipeline["function_arn"] and deployed["State"] == "Active" and deployed["LastUpdateStatus"] == "Successful")
    require(deployed["Architectures"] == ["arm64"] and deployed["VpcConfig"]["SubnetIds"] and deployed["VpcConfig"]["SecurityGroupIds"])
    if pipeline.get("image_uri"):
        require(function["Code"]["ResolvedImageUri"] == pipeline["image_uri"])
    else:
        require(isinstance(code_sha, str) and code_sha and deployed["CodeSha256"] == code_sha and deployed["Runtime"] == "nodejs24.x")
    # Reconcile may run up to the function deadline. Do not let an SDK timeout
    # retry this explicit invocation and accidentally start a second run.
    from botocore.config import Config
    client = session.client("lambda", config=Config(connect_timeout=15, read_timeout=deployed["Timeout"] + 30, retries={"total_max_attempts": 1}))
    response = client.invoke(FunctionName=pipeline["function_arn"], InvocationType="RequestResponse", Payload=b'{"reconcile":true}')
    require(response["StatusCode"] == 200 and not response.get("FunctionError"))
    body = json.loads(response["Payload"].read())
    require(isinstance(body, dict) and body.get("ok") is True)


def storage(session, config, run_id, *, installation):
    validate(config, installation, run_id)
    phase_identity(session, config, installation, run_id, config["storage"]["role_arn"])
    value = config["storage"]
    key = value["prefix"] + run_id + "/marker.json"
    client = session.client("s3")
    body = json.dumps({"marker": run_id}).encode()
    # Only the synthetic current key is deleted. Version history remains under
    # normal retention; an approved administrator cleans versions at retirement.
    try:
        client.put_object(Bucket=value["bucket"], Key=key, Body=body, ExpectedBucketOwner=installation.account)
        result = client.get_object(Bucket=value["bucket"], Key=key, ExpectedBucketOwner=installation.account)
        require(result["Body"].read() == body)
        require(any(x["Key"] == key for x in client.list_objects_v2(Bucket=value["bucket"], Prefix=key, ExpectedBucketOwner=installation.account).get("Contents", [])))
    finally:
        client.delete_object(Bucket=value["bucket"], Key=key, ExpectedBucketOwner=installation.account)


def search_phase(session, config, phase, run_id, *, installation):
    validate(config, installation, run_id)
    roles = {"search-bootstrap": "master_role_arn", "search-write": "indexer_role_arn", "search-read": "reader_role_arn", "search-cleanup": "master_role_arn"}
    require(phase in roles)
    search = config["search"]
    phase_identity(session, config, installation, run_id, search[roles[phase]])
    client = Search(session, config, installation=installation)
    index = search["index_prefix"] + "proof-" + run_id
    denied = "denied-proof-" + run_id
    role = f"agent_relay_proof_{config['environment']}_{run_id}"
    if phase == "search-bootstrap":
        domain = session.client("opensearch").describe_domain(DomainName=search["domain_name"])["DomainStatus"]
        require(domain["ARN"] == search["domain_arn"] and domain["Endpoints"]["vpc"] == urlsplit(search["url"]).hostname)
        require(domain["VPCOptions"].get("VPCId") and domain["AdvancedSecurityOptions"]["Enabled"])
        writer_roles = [search["indexer_role_arn"]] + ([search["lambda_role_arn"]] if search.get("lambda_role_arn") else [])
        for suffix, actions, principals in [("writer", ["crud", "create_index"], writer_roles), ("reader", ["read"], [search["reader_role_arn"]])]:
            security_ack(*client.call("PUT", f"/_plugins/_security/api/roles/{role}_{suffix}", {"cluster_permissions": ["cluster_composite_ops_ro"], "index_permissions": [{"index_patterns": [index], "allowed_actions": actions}], "tenant_permissions": []}))
            security_ack(*client.call("PUT", f"/_plugins/_security/api/rolesmapping/{role}_{suffix}", {"backend_roles": principals, "hosts": [], "users": []}))
        for name in (index, denied):
            index_ack(*client.call("PUT", f"/{name}", {"mappings": {"properties": {"marker": {"type": "keyword"}}}}))
        document_ack(*client.call("PUT", f"/{denied}/_doc/private?refresh=true", {"marker": run_id}), denied, "private")
    elif phase == "search-write":
        document_ack(*client.call("PUT", f"/{index}/_doc/accepted?refresh=true", {"marker": run_id}), index, "accepted")
    elif phase == "search-read":
        status, body = client.call("POST", f"/{index}/_search", {"query": {"term": {"marker": run_id}}})
        require(status == 200 and body.get("timed_out") is False and body.get("_shards", {}).get("failed") == 0)
        hits = body.get("hits", {}).get("hits")
        require(isinstance(hits, list) and len(hits) == 1 and hits[0].get("_id") == "accepted" and hits[0].get("_source", {}).get("marker") == run_id)
        status, _ = client.call("PUT", f"/{index}/_doc/refused", {"marker": run_id})
        require(status == 403)
        body = json.dumps({"index": {"_index": index, "_id": "refused-bulk"}}) + "\n" + json.dumps({"marker": run_id}) + "\n"
        status, result = client.call("POST", "/_bulk", body, ndjson=True)
        require(bulk_is_refused(status, result))
        status, _ = client.call("GET", f"/{denied}/_search")
        require(status == 403)
    elif phase == "search-cleanup":
        # Refusal must have had zero write effects, not merely an error response.
        for doc in ("refused", "refused-bulk"):
            status, body = client.call("GET", f"/{index}/_doc/{doc}")
            require(status == 404 and body.get("found") is False and body.get("_index") == index and body.get("_id") == doc)
        for name in (index, denied):
            index_ack(*client.call("DELETE", f"/{name}"))
        for suffix in ("writer", "reader"):
            for resource in ("rolesmapping", "roles"):
                security_ack(*client.call("DELETE", f"/_plugins/_security/api/{resource}/{role}_{suffix}"))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("phase", choices=["configuration", "postgres", "storage", "search-bootstrap", "search-write", "search-read", "search-cleanup", "lambda-smoke"])
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--run-id", required=True, help="One shared random UUID in 32-character lowercase hex form")
    parser.add_argument("--confirm-account", required=True)
    parser.add_argument("--confirm-environment", required=True)
    parser.add_argument("--confirm-region", required=True)
    parser.add_argument("--confirm-environment-class", required=True, choices=["development", "staging", "production"])
    parser.add_argument("--confirm-name-prefix", required=True, help="Independently reviewed installation prefix; do not copy from untrusted target JSON")
    parser.add_argument("--confirm-search-url", required=True, help="Exact private HTTPS URL from a separately reviewed native installation record; never auto-copy target JSON")
    parser.add_argument("--confirm-pippen-agent")
    parser.add_argument("--confirm-pippen-session")
    parser.add_argument("--confirm-live", action="store_true", required=True)
    parser.add_argument("--rds-ca", type=Path)
    parser.add_argument("--lambda-code-sha256", help="Reviewed Lambda ZIP CodeSha256 in base64; required for ZIP smoke")
    args = parser.parse_args(argv)
    installation = confirm_installation(args.confirm_account, args.confirm_region, args.confirm_environment, args.confirm_environment_class, args.confirm_name_prefix, args.confirm_search_url, args.confirm_pippen_agent, args.confirm_pippen_session)
    config = validate(json.loads(args.config.read_text()), installation, args.run_id)
    import boto3
    session = boto3.Session(region_name=config["region"])
    if args.phase == "configuration":
        configuration(session, config, installation=installation)
    elif args.phase == "lambda-smoke":
        lambda_smoke(session, config, args.lambda_code_sha256, installation=installation)
    elif args.phase == "postgres":
        postgres(session, config, args.rds_ca, installation=installation)
    elif args.phase == "storage":
        storage(session, config, args.run_id, installation=installation)
    else:
        search_phase(session, config, args.phase, args.run_id, installation=installation)
    print(json.dumps({"result": "PASS", "phase": args.phase, "environment": config["environment"], "run_id": args.run_id}))


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(json.dumps({"result": "FAIL", "error_class": type(exc).__name__}), file=sys.stderr)
        sys.exit(1)
