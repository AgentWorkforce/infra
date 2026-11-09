"""Parent common-role metadata/S3 retirement transport; no secret-value API.

Never execute during source tests. Credential process remains the parent's
refreshing selector; this module neither invokes it for inspection nor accepts
static credentials. Resource/operation scope comes from the reviewed ledgers.
"""
import json
import os
import re
from secret_io import run,SecretIoError
import s3_probe

def require(value,code='parent_retirement_guard'):
    if not value:raise SecretIoError(code)

def environment():
    raw=dict(os.environ)
    require(raw.get('AWS_PROFILE')=='pippen-sandbox' and raw.get('AWS_SHARED_CREDENTIALS_FILE')=='/dev/null' and raw.get('AWS_EC2_METADATA_DISABLED')=='true' and raw.get('AWS_CONFIG_FILE'),'refreshing_common_selector_required')
    require(not any(raw.get(k) for k in ['AWS_ACCESS_KEY_ID','AWS_SECRET_ACCESS_KEY','AWS_SESSION_TOKEN','AWS_ROLE_ARN','AWS_WEB_IDENTITY_TOKEN_FILE','AWS_ENDPOINT_URL']),'no_static_or_foreign_parent_auth')
    return {k:v for k,v in raw.items() if k in ['PATH','HOME','AWS_PROFILE','AWS_CONFIG_FILE','AWS_SHARED_CREDENTIALS_FILE','AWS_EC2_METADATA_DISABLED']}

def cli(c,service,operation,*args,refusal=None):
    operations={'get-caller-identity':'GetCallerIdentity','list-multipart-uploads':'ListMultipartUploads','list-object-versions':'ListObjectVersions','abort-multipart-upload':'AbortMultipartUpload','delete-object':'DeleteObject','list-parts':'ListParts'}
    require((service=='sts' and operation=='get-caller-identity') or (service=='s3api' and operation in operations),'parent_operation_refused')
    owner=['--expected-bucket-owner',c['account_id']] if service=='s3api' else []
    r=run(['aws','--region',c['region'],'--no-cli-pager',service,operation,*args,*owner,'--output','json'],env=environment(),timeout=90)
    if refusal:
        match=re.search(rb'An error occurred \(([^)]+)\) when calling the ([A-Za-z0-9]+) operation',r.stderr)
        require(r.returncode!=0 and match and match[1].decode()==refusal and match[2].decode()==operations[operation],'parent_target_refusal_unproved');return {}
    require(r.returncode==0,'parent_retirement_api_failed')
    try:return json.loads(r.stdout) if r.stdout.strip() else {}
    except Exception:raise SecretIoError('parent_retirement_json') from None

def version_entries(c):
    s3_probe.cli=cli;return s3_probe.version_entries(c)
def clean_versions(c,ledger):
    s3_probe.cli=cli;return s3_probe.clean_versions(c,ledger)
