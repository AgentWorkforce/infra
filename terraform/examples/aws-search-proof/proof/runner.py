#!/usr/bin/env python3
"""Held source runner. Operational commands are FUTURE operator actions only.

Tests inject a transport. Importing this file never invokes a tool/provider.
Capability metadata is inherited from the selected Pippen CLI, never obtained
by inspecting its credential_process or accepting a client approval file.
Catchable TERM/HUP/INT interrupt through owned-group settlement; SIGKILL and host
crash/power loss cannot provide cleanup or completed evidence guarantees.
Signals first delivered after restoration follow the caller's prior handlers.
"""
import argparse
import configparser
import datetime as dt
import fcntl
import json
import os
from pathlib import Path
import signal
import stat
import subprocess
import sys
import time
from contract import ADDRESSES, caller, canonical, changes, context, context_provenance, digest, domain_name, expected_tags, identities, native_error, require, variables as validate_variables
from files import read, save, sha

ROOT = Path(__file__).resolve().parents[1]
MODULE = ROOT.parents[1] / 'modules/aws/search'

class CommandInterrupted(InterruptedError):
    def __init__(self, signum):
        self.signum = signum
        super().__init__(f'Owned command interrupted by signal {signum}')

class Runner:
    def __init__(self, execution, variables, terraform, env=None, transport=None):
        self.execution = Path(execution).resolve(); self.variables = Path(variables).resolve()
        self.terraform = str(Path(terraform).resolve()); self.env = dict(os.environ if env is None else env)
        self.transport = transport; self.settled = True
        self.v = read(self.variables)
        validate_variables(self.v)
        self.execution.mkdir(mode=0o700, parents=True, exist_ok=True)
        require(stat.S_IMODE(self.execution.stat().st_mode) == 0o700, 'Private execution directory must be mode 0700')
        require(not str(self.execution).startswith(str(ROOT) + os.sep), 'Keep state/evidence outside the committed source root')
        if sys.platform == 'darwin': require(str(self.execution).startswith('/Volumes/T7/'), 'Mac execution/install output belongs on mounted T7')
        owner = self.execution / 'execution-owner.json'
        expected_owner = {'format': 'aws-search-proof-execution-v1', 'source_root': str(ROOT), 'source_sha': self.v['source_sha'], 'inputs_sha256': sha(self.variables)}
        if owner.exists(): require(read(owner) == expected_owner, 'Execution directory belongs to another source/input lifecycle')
        else:
            allowed = {self.variables.name} if self.variables.parent == self.execution else set()
            require({p.name for p in self.execution.iterdir()} <= allowed, 'Refuse an existing unrelated execution/evidence directory')
            save(owner, expected_owner)
        for key in list(self.env):
            if key.startswith(('TF_VAR_', 'TF_CLI_ARGS', 'TF_LOG')): self.env.pop(key)
        require(not self.env.get('TF_DATA_DIR'), 'Provider/backend data directory overrides are not supported')
        require(not any(self.env.get(k) for k in ['AWS_ACCESS_KEY_ID', 'AWS_SECRET_ACCESS_KEY', 'AWS_SESSION_TOKEN', 'AWS_WEB_IDENTITY_TOKEN_FILE', 'AWS_ROLE_ARN', 'AWS_ENDPOINT_URL']), 'Refreshing Pippen profile only; no static/alternate credential or endpoint inputs')
        require(not any(k.startswith('AWS_ENDPOINT_URL_') and v for k, v in self.env.items()), 'No endpoint overrides')
        require(self.env.get('AWS_PROFILE') == 'pippen-sandbox' and self.env.get('AWS_SHARED_CREDENTIALS_FILE') == '/dev/null' and self.env.get('AWS_EC2_METADATA_DISABLED') == 'true', 'Run inside the selected refreshing Pippen CLI execution environment')
        require(self.env.get('TF_WORKSPACE', 'default') == 'default', 'Only the isolated default workspace is supported')
        config = configparser.ConfigParser(interpolation=None); require(config.read(self.env['AWS_CONFIG_FILE']), 'Missing refreshing selector')
        require(config.sections() == ['profile pippen-sandbox'] and set(config['profile pippen-sandbox']) == {'region', 'credential_process'} and config['profile pippen-sandbox']['region'] == self.v['region'], 'Unexpected AWS selector configuration')
        self.selector_sha256 = sha(self.env['AWS_CONFIG_FILE'])
        self.env.update(TF_IN_AUTOMATION='1', TF_INPUT='0', TF_WORKSPACE='default', AWS_PAGER='')
        # A private literal CLI config excludes hidden provider dev_overrides.
        self.cli_config = self.execution / 'terraform.rc'
        contents = 'disable_checkpoint = true\n'
        if self.cli_config.exists(): require(self.cli_config.read_text() == contents, 'Terraform CLI configuration changed')
        else: self.cli_config.write_text(contents); self.cli_config.chmod(0o600)
        self.env['TF_CLI_CONFIG_FILE'] = str(self.cli_config)
        # Preserve PIPPEN_SANDBOX_CAPABILITY_CONTEXT for credential refresh too.
        self.state = self.execution / 'state.tfstate'
        self.backend = self.execution / 'backend.json'
        wanted = {'path': str(self.state)}
        if self.backend.exists(): require(read(self.backend) == wanted, 'Backend path changed')
        else: save(self.backend, wanted)

    def path(self, name): return self.execution / name

    def run(self, args, timeout=2700, check=True):
        require(sha(self.env['AWS_CONFIG_FILE']) == self.selector_sha256, 'Refreshing selector changed during this operation')
        if self.transport: return self.transport(args, timeout=timeout, check=check)
        prefix = self.path('commands') / str(time.time_ns()); prefix.parent.mkdir(mode=0o700, exist_ok=True)
        metadata = {'args': args, 'outcome': 'launching'}; save(prefix.with_suffix('.json'), metadata)
        process = None; self.settled = False
        requested = None; primary_error = None
        previous = {}
        def interrupt(signum, _frame):
            nonlocal requested
            # Record only: an asynchronous raise could interrupt exception-entry
            # cleanup or Popen before its owned PID has been assigned.
            if requested is None: requested = signum
        def pending_signal():
            if requested is not None: raise CommandInterrupted(requested)
        def settle():
            if process is None: return True
            for sig in [signal.SIGTERM, signal.SIGKILL]:
                process.poll()
                try: os.killpg(process.pid, sig)
                except ProcessLookupError: return True
                except PermissionError: pass # Unknown, not absence; still reap/probe within the bound.
                end = time.monotonic() + 5
                while time.monotonic() < end:
                    process.poll()
                    try: os.killpg(process.pid, 0)
                    except ProcessLookupError: return True
                    except PermissionError: pass # May be transient while the group exits.
                    time.sleep(.1)
            return False
        try:
            for sig in [signal.SIGTERM, signal.SIGHUP, signal.SIGINT]:
                previous[sig] = signal.signal(sig, interrupt)
            with prefix.with_suffix('.stdout').open('w') as out, prefix.with_suffix('.stderr').open('w') as err:
                os.chmod(out.name, 0o600); os.chmod(err.name, 0o600)
                pending_signal() # A signal before launch must not create a child.
                process = subprocess.Popen(args, cwd=ROOT, env=self.env, stdout=out, stderr=err, start_new_session=True, text=True)
                metadata.update(pid=process.pid, pgid=process.pid, outcome='running')
                pending_signal() # Includes signals deferred during Popen/assignment.
                save(prefix.with_suffix('.json'), metadata)
                deadline = time.monotonic() + timeout
                while True:
                    pending_signal()
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        if process.poll() is not None: break
                        raise subprocess.TimeoutExpired(args, timeout)
                    try:
                        process.wait(timeout=min(.1, remaining))
                        break
                    except subprocess.TimeoutExpired: pass
                pending_signal()
                self.settled = settle()
                pending_signal()
                require(self.settled, 'Unsettled owned process group; quarantine before recovery')
            pending_signal() # Log __exit__ may record a signal; retain cleanup/evidence handling.
        except BaseException as error:
            if not self.settled: self.settled = settle()
            metadata.update(outcome='interrupted', error_type=type(error).__name__, process_group_absent=self.settled)
            if process is not None: metadata.update(pid=process.pid, pgid=process.pid)
            if requested is not None: metadata['signal'] = requested
            save(prefix.with_suffix('.json'), metadata); primary_error = error; raise
        finally:
            for sig, handler in previous.items(): signal.signal(sig, handler)
            if requested is not None and metadata.get('outcome') == 'interrupted' and metadata.get('signal') != requested:
                metadata['signal'] = requested
                try: save(prefix.with_suffix('.json'), metadata)
                except OSError as receipt_error:
                    if primary_error is None: raise
                    raise primary_error from receipt_error
        # A signal recorded while restoring prior handlers is still failure.
        # Reaching here already proved group absence; do not restart settlement
        # under the restored handlers or publish a completed command receipt.
        if requested is not None:
            error = CommandInterrupted(requested)
            metadata.update(outcome='interrupted', error_type=type(error).__name__, process_group_absent=self.settled, signal=requested)
            save(prefix.with_suffix('.json'), metadata); raise error
        metadata.update(outcome='completed', exit_code=process.returncode, process_group_absent=self.settled); save(prefix.with_suffix('.json'), metadata)
        result = subprocess.CompletedProcess(args, process.returncode, prefix.with_suffix('.stdout').read_text(), prefix.with_suffix('.stderr').read_text())
        require(not check or result.returncode == 0, 'Tool failed; preserve private command evidence')
        return result

    def aws(self, service, operation, *args, check=True):
        return self.run(['aws', '--region', self.v['region'], '--no-cli-pager', service, operation, *args, '--output', 'json'], timeout=120, check=check)

    def identity(self, phase):
        value = json.loads(self.aws('sts', 'get-caller-identity').stdout)
        caller(value, self.v, phase); return value

    def packet(self): return read(self.path('create.packet.json'))

    def sealed_context(self, original):
        # Local provenance seal, never a source of credentials or approval authority.
        path = self.path('original-capability-context.json')
        value = context_provenance(path.read_text(), original, self.v)
        fingerprint = sha(path)
        for name in ['phase.json', 'candidate-contract.json', 'created.json', 'destroy.packet.json', 'network-created.json', 'domain-absence.json', 'network-absence.json']:
            if self.path(name).exists():
                require(read(self.path(name)).get('context_sha256') == fingerprint, 'Original capability context seal differs from lifecycle evidence')
        return value, fingerprint

    def authority(self, original, initial=False):
        value = context(self.env.get('PIPPEN_SANDBOX_CAPABILITY_CONTEXT'), original, self.v)
        if self.path('original-capability-context.json').exists():
            sealed, _ = self.sealed_context(original)
            require(value == sealed, 'All 16 original capability context fields must remain identical')
        else:
            require(initial, 'Missing original capability context seal; quarantine lifecycle')
        identity = self.identity('control') # Fresh CLI call; never Terraform's cached data source.
        return value, identity

    def bindings(self):
        repo = ROOT.parents[2]
        commit = subprocess.check_output(['git', '-C', str(repo), 'rev-parse', 'HEAD'], text=True).strip()
        require(commit == self.v['source_sha'], 'Source does not match committed inputs')
        require(not subprocess.check_output(['git', '-C', str(repo), 'status', '--porcelain'], text=True).strip(), 'Commit all source before preparing an operational packet')
        tracked = subprocess.check_output(['git', '-C', str(repo), 'ls-files', '--', str(ROOT.relative_to(repo)), str(MODULE.relative_to(repo))], text=True).splitlines()
        sources = {name: sha(repo / name) for name in tracked}
        version = json.loads(subprocess.check_output([self.terraform, 'version', '-json'], cwd=ROOT, env=self.env, text=True))
        selected_platform = version.get('platform')
        require(selected_platform in ['darwin_arm64', 'darwin_amd64', 'linux_arm64', 'linux_amd64'], 'Unsupported Terraform execution platform')
        selected = ROOT / f'.terraform/providers/registry.terraform.io/hashicorp/aws/6.72.0/{selected_platform}'
        binaries = {str(p.relative_to(ROOT)): sha(p) for p in selected.glob('terraform-provider-aws*') if p.is_file()}
        require(len(binaries) == 1, 'Exactly the locked AWS provider executable is required')
        binaries['terraform'] = sha(self.terraform)
        backend_metadata = ROOT / '.terraform/terraform.tfstate'
        require(backend_metadata.exists() and read(backend_metadata).get('backend', {}).get('type') == 'local', 'Initialized isolated local backend required')
        require(read(backend_metadata)['backend']['config']['path'] == str(self.state), 'Initialized backend points outside this execution')
        baseline = self.path('network-before.json'); require(baseline.exists(), 'Fresh common-role network/ENI/SLR baseline required')
        artifact = {'sources': sources, 'runner_sha256': sha(__file__), 'execution_owner_sha256': sha(self.path('execution-owner.json')), 'network_baseline_sha256': sha(baseline), 'terraform_cli_config_sha256': sha(self.cli_config)}
        backend = {'config_sha256': sha(self.backend), 'metadata_sha256': sha(backend_metadata), 'workspace': 'default', 'state_sha256': sha(self.state) if self.state.exists() else None}
        return {'source_commit': commit, 'inputs_sha256': sha(self.variables), 'provider_lock_sha256': sha(ROOT / '.terraform.lock.hcl'), 'provider_binaries_sha256': digest(canonical(binaries)), 'artifact_sha256': digest(canonical(artifact)), 'backend_state_sha256': digest(canonical(backend)), 'backend': backend, 'runner_sha256': sha(__file__), 'selector_sha256': sha(self.env['AWS_CONFIG_FILE'])}

    def immutable(self, original):
        current = self.bindings()
        # The selector is freshly minted per CLI operation, not a durable profile.
        for key in ['source_commit', 'inputs_sha256', 'provider_lock_sha256', 'provider_binaries_sha256', 'artifact_sha256', 'runner_sha256']:
            require(current[key] == original[key], 'Immutable creation source/input/provider/artifact binding changed')
        require(current['backend']['config_sha256'] == original['backend']['config_sha256'] and current['backend']['metadata_sha256'] == original['backend']['metadata_sha256'], 'Backend/workspace changed')
        return current

    def prepare(self, destroy=False):
        original = self.packet() if destroy else None
        if destroy:
            self.authority(original); self.immutable(original)
            require(read(self.path('phase.json')).get('status') == 'captured', 'Incomplete apply is quarantined; reconcile exact names/state/native resources')
            ledger = read(self.path('created.json')); require(self.path('network-created.json').exists(), 'Capture complete service ENI inventory before teardown')
            self.native_domain(ledger)
        else:
            require(not self.path('create.packet.json').exists() and not self.state.exists() and not self.path('phase.json').exists(), 'Fresh isolated lifecycle required; no blind reuse/adoption')
            require(not self.env.get('PIPPEN_SANDBOX_CAPABILITY_CONTEXT'), 'Initial common-role preparation must not inherit capability metadata')
            self.identity('common'); ledger = None
        name = 'destroy' if destroy else 'create'
        if not destroy:
            self.run([self.terraform, 'init', '-input=false', '-no-color', '-lockfile=readonly', '-reconfigure', '-backend-config=' + str(self.backend)])
        before = self.bindings()
        saved = self.path(name + '.tfplan'); require(not saved.exists(), 'Do not overwrite reviewed saved plans')
        args = [self.terraform, 'plan', '-input=false', '-no-color', '-lock-timeout=60s', '-var-file=' + str(self.variables), '-out=' + str(saved)]
        if destroy: args.append('-destroy')
        self.run(args)
        plan = json.loads(self.run([self.terraform, 'show', '-json', str(saved)]).stdout)
        history = changes(plan, self.v, destroy, ledger)
        after = self.bindings(); require(after == before, 'Source/input/provider/backend/state changed while preparing the saved plan')
        packet = {**after, 'plan_sha256': sha(saved), 'plan_json_sha256': digest(canonical(plan)), 'operation': name, 'search_mode_history': history}
        if destroy:
            packet.update(context_sha256=self.sealed_context(original)[1], original_packet_sha256=sha(self.path('create.packet.json')), created_sha256=sha(self.path('created.json')), network_created_sha256=sha(self.path('network-created.json')))
        save(self.path(name + '.plan.json'), plan); save(self.path(name + '.packet.json'), packet)
        return {'operation': name, 'packet_sha256': sha(self.path(name + '.packet.json')), 'plan_sha256': packet['plan_sha256'], 'scope': 'local review packet; no new server approval inferred'}

    def apply(self, reviewed_plan_sha256, reviewed_packet_sha256, destroy=False):
        require(self.settled, 'Unsettled prior command group')
        require(destroy or not self.path('phase.json').exists(), 'An attempted creation cannot be retried or adopted; reconcile pending/captured lifecycle explicitly')
        name = 'destroy' if destroy else 'create'; original = self.packet(); packet = read(self.path(name + '.packet.json'))
        cap, identity = self.authority(original, initial=not destroy)
        require(sha(self.path(name + '.packet.json')) == reviewed_packet_sha256 and packet['plan_sha256'] == reviewed_plan_sha256 and sha(self.path(name + '.tfplan')) == reviewed_plan_sha256, 'Exact saved plan/packet review required')
        current = self.immutable(original)
        require(current['backend_state_sha256'] == packet['backend_state_sha256'], 'Current state differs from the reviewed saved plan')
        plan = json.loads(self.run([self.terraform, 'show', '-json', str(self.path(name + '.tfplan'))]).stdout)
        require(digest(canonical(plan)) == packet['plan_json_sha256'], 'Saved plan JSON changed')
        ledger = read(self.path('created.json')) if destroy else None
        require(changes(plan, self.v, destroy, ledger) == packet.get('search_mode_history'), 'Search history qualification differs from the reviewed packet')
        expiry = dt.datetime.fromisoformat(cap['profile_expires_at'].replace('Z', '+00:00'))
        require((expiry - dt.datetime.now(dt.timezone.utc)).total_seconds() >= (3600 if destroy else 7200), 'Immutable profile needs adequate creation/cleanup time; no expiry extension/fallback')
        if destroy:
            require(packet['original_packet_sha256'] == sha(self.path('create.packet.json')) and read(self.path('phase.json')).get('status') == 'captured', 'Original scope or complete lifetime capture missing')
            require(packet['created_sha256'] == sha(self.path('created.json')) and packet['network_created_sha256'] == sha(self.path('network-created.json')), 'Captured physical domain/ENI ledger changed after review')
            self.native_domain(ledger)
        else:
            baseline = read(self.path('network-before.json'))
            require(time.time() - baseline['observed_at'] <= 900 and baseline['inputs_sha256'] == sha(self.variables), 'Common-role native baseline is stale or foreign; prepare a new approval packet')
            result = self.aws('opensearch', 'describe-domain', '--domain-name', domain_name(self.v['pippen']['session_id']), check=False)
            require(result.returncode != 0 and native_error(result.stderr, 'DescribeDomain', 'ResourceNotFoundException'), 'Refuse existing/foreign/unknown domain; a name or create success cannot establish ownership')
        if not destroy and not self.path('original-capability-context.json').exists():
            save(self.path('original-capability-context.json'), cap)
        _, context_sha256 = self.sealed_context(original)
        save(self.path('phase.json'), {'context_sha256': context_sha256, 'operation': name, 'status': 'pending', 'plan_sha256': reviewed_plan_sha256, 'apply_caller': identity, 'approval_id': cap['approval_id'], 'approval_fingerprint': cap['approval_fingerprint']})
        self.run([self.terraform, 'apply', '-input=false', '-no-color', str(self.path(name + '.tfplan'))])
        if destroy:
            save(self.path('phase.json'), {'context_sha256': context_sha256, 'operation': 'destroy', 'status': 'destroyed-pending-native-absence'})
        else:
            candidate = json.loads(self.run([self.terraform, 'output', '-json', 'proof_contract']).stdout)
            candidate['context_sha256'] = context_sha256
            save(self.path('candidate-contract.json'), candidate)
            native = self.native_domain(candidate)
            save(self.path('created.json'), {**candidate, 'native_domain_id': native['DomainId'], 'apply_caller': identity, 'original_packet_sha256': sha(self.path('create.packet.json'))})
            save(self.path('phase.json'), {'context_sha256': context_sha256, 'operation': 'create', 'status': 'captured', 'ledger_sha256': sha(self.path('created.json'))})
        return {'operation': name, 'scope': 'Terraform operation completed; independent native retirement still required'}

    def native_domain(self, ledger):
        status = json.loads(self.aws('opensearch', 'describe-domain', '--domain-name', ledger['domain_name']).stdout)['DomainStatus']
        arn = f"arn:aws:es:{self.v['region']}:{self.v['account_id']}:domain/{domain_name(self.v['pippen']['session_id'])}"
        require(status['ARN'] == arn == ledger['domain_arn'] and status['DomainName'] == ledger['domain_name'] and status['Created'] and not status['Deleted'] and not status['Processing'], 'Domain is foreign, missing or still processing')
        require(set(status['VPCOptions']['SubnetIds']) == set(self.v['subnet_ids']) and status['VPCOptions']['SecurityGroupIds'] == [self.v['domain_security_group_id']] and status['VPCOptions']['VPCId'] == self.v['vpc_id'], 'Native domain network changed')
        endpoint = status.get('Endpoints', {}).get('vpc') or status.get('Endpoint')
        require(endpoint == ledger['endpoint'] and status['EngineVersion'] == self.v['engine_version'], 'Native endpoint/version no longer matches captured Terraform identity')
        require(status['EncryptionAtRestOptions']['Enabled'] is True and status['NodeToNodeEncryptionOptions']['Enabled'] is True and status['DomainEndpointOptions']['EnforceHTTPS'] is True and status['DomainEndpointOptions']['TLSSecurityPolicy'] == 'Policy-Min-TLS-1-2-PFS-2023-10' and status['AdvancedSecurityOptions']['Enabled'] is True and status['AdvancedSecurityOptions']['InternalUserDatabaseEnabled'] is False and status['AdvancedSecurityOptions'].get('AnonymousAuthEnabled', False) is False, 'Native encryption/TLS/FGAC prerequisites differ from the reviewed plan')
        tags = json.loads(self.aws('opensearch', 'list-tags', '--arn', arn).stdout)['TagList']
        require({r['Key']: r['Value'] for r in tags} == expected_tags(self.v), 'Native metadata changed or ownership is foreign')
        return status

    def domain_absence(self):
        original = self.packet(); self.authority(original); self.immutable(original)
        require(read(self.path('phase.json')).get('status') == 'destroyed-pending-native-absence', 'Terraform destruction is not complete')
        result = self.aws('opensearch', 'describe-domain', '--domain-name', domain_name(self.v['pippen']['session_id']), check=False)
        require(result.returncode != 0 and native_error(result.stderr, 'DescribeDomain', 'ResourceNotFoundException'), 'Exact domain absence is not proved')
        save(self.path('domain-absence.json'), {'ok': True, 'context_sha256': self.sealed_context(original)[1], 'domain_name': domain_name(self.v['pippen']['session_id']), 'original_packet_sha256': sha(self.path('create.packet.json')), 'caller': self.identity('control')})
        return {'ok': True, 'scope': 'exact typed domain absence only; common-role ENI absence remains required'}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=['network-before', 'prepare', 'apply', 'network-created', 'prepare-destroy', 'destroy', 'domain-absence', 'network-absence'])
    parser.add_argument('--execution', required=True); parser.add_argument('--variables', required=True); parser.add_argument('--terraform', required=True)
    parser.add_argument('--reviewed-plan-sha256'); parser.add_argument('--reviewed-packet-sha256')
    args = parser.parse_args(); runner = Runner(args.execution, args.variables, args.terraform)
    lock = runner.path('runner.lock').open('a'); fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    if args.operation.startswith('network-'):
        from network import network
        result = network(runner, args.operation)
    elif args.operation in ['prepare', 'prepare-destroy']: result = runner.prepare(args.operation == 'prepare-destroy')
    elif args.operation in ['apply', 'destroy']: result = runner.apply(args.reviewed_plan_sha256, args.reviewed_packet_sha256, args.operation == 'destroy')
    else: result = runner.domain_absence()
    print(json.dumps(result))

if __name__ == '__main__': main()
