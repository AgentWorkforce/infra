#!/usr/bin/env python3
"""Saved-plan lifecycle runner for the RDS application proof.

Operator-driven, one phase at a time, under `pippen sandbox exec aws-proof -- ...`.
`plan` writes a saved plan, its digest and a readable summary, then stops.
`apply` runs only the saved plan whose digest a person passes back.

Tests inject a transport. Importing this file never invokes a tool or provider.
Catchable TERM/HUP/INT settle the owned process group. SIGKILL and host loss
cannot, so a pending record is always written before a mutation starts.

Forward phases refuse an expired deadline. Retirement does not, because refusing
would strand resources; it still needs the exact leased caller.
"""
import argparse
import configparser
import datetime as dt
import fcntl
import hashlib
import json
import os
from pathlib import Path
import signal
import stat
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
ACCOUNT = '361835732085'
AGENT = 'aws-proof'
EXECUTION_PREFIX = '/Volumes/T7/'
FORWARD = ('provision', 'prerequisites', 'upload', 'seed', 'seed-receipt', 'restore', 'restore-receipt')
RETIRE = ('release', 'inventory', 'drain', 'destroy', 'backups', 'absence')
TERRAFORM_PHASES = ('provision', 'seed', 'restore', 'release', 'destroy')
DONE = ('captured', 'ok')
RELEASED = DONE + ('not-required',)
FORWARD_TERRAFORM = ('provision', 'seed', 'restore')
UNSETTLED = ('pending', 'unknown', 'failed', 'interrupted', 'captured-invalid')
UNRECONCILED = ('pending', 'unknown')
RECONCILABLE = TERRAFORM_PHASES + ('upload',)


class Refused(RuntimeError):
    pass


class CommandInterrupted(InterruptedError):
    def __init__(self, signum):
        self.signum = signum
        super().__init__(f'Owned command interrupted by signal {signum}')


def require(value, message):
    if not value:
        raise Refused(message)


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':')).encode()


def digest(data):
    return hashlib.sha256(data).hexdigest()


def sha(path):
    return digest(Path(path).read_bytes())


def read(path):
    return json.loads(Path(path).read_text())


def save(path, value):
    path = Path(path)
    tmp = path.with_name(path.name + '.tmp')
    with tmp.open('w') as handle:
        os.chmod(tmp, 0o600)
        handle.write(json.dumps(value, indent=2, sort_keys=True) + '\n')
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(tmp, path)


def now():
    return dt.datetime.now(dt.timezone.utc)


def validate_variables(value):
    require(value.get('account_id') == ACCOUNT, f'Only account {ACCOUNT} is allowed')
    require(isinstance(value.get('pippen'), dict) and value['pippen'].get('agent') == AGENT, f'Only agent {AGENT} is allowed')
    require(isinstance(value['pippen'].get('session_id'), str) and value['pippen']['session_id'], 'A lease session id is required')
    for name in ['region', 'run_id', 'source_sha', 'payload_sha256', 'deadline', 'guest_sources']:
        require(value.get(name), f'Variable {name} is required')
    # The runner derives these per phase; base inputs must not pre-set them.
    require(value.get('payload_version_id') is None and value.get('restore_checkpoint') is None and not value.get('retire'),
            'Base variables must leave payload_version_id, restore_checkpoint and retire unset')
    dt.datetime.fromisoformat(value['deadline'].replace('Z', '+00:00'))


class Runner:
    def __init__(self, execution, variables, terraform, env=None, transport=None):
        self.execution = Path(execution).resolve()
        self.variables = Path(variables).resolve()
        self.terraform = str(Path(terraform).resolve())
        self.env = dict(os.environ if env is None else env)
        self.transport = transport
        self.v = read(self.variables)
        validate_variables(self.v)
        self.execution.mkdir(mode=0o700, parents=True, exist_ok=True)
        require(stat.S_IMODE(self.execution.stat().st_mode) == 0o700, 'Execution directory must be mode 0700')
        require(not str(self.execution).startswith(str(ROOT.parents[2]) + os.sep), 'Keep state and evidence outside the repository')
        if sys.platform == 'darwin':
            require(str(self.execution).startswith(EXECUTION_PREFIX), 'Execution output belongs on mounted T7')
        owner = self.path('execution-owner.json')
        expected = {'format': 'aws-rds-application-proof-execution-v1', 'source_sha': self.v['source_sha'], 'inputs_sha256': sha(self.variables)}
        if owner.exists():
            require(read(owner) == expected, 'Execution directory belongs to another source or input lifecycle')
        else:
            allowed = {self.variables.name} if self.variables.parent == self.execution else set()
            require({p.name for p in self.execution.iterdir()} <= allowed, 'Refuse an existing unrelated execution directory')
            save(owner, expected)
        self.state = self.path('state.tfstate')
        for key in list(self.env):
            if key.startswith(('TF_VAR_', 'TF_CLI_ARGS', 'TF_LOG')):
                self.env.pop(key)
        require(not self.env.get('TF_DATA_DIR'), 'Terraform data directory overrides are not supported')
        require(self.env.get('TF_WORKSPACE', 'default') == 'default', 'Only the default workspace is supported')
        self.env.update(TF_IN_AUTOMATION='1', TF_INPUT='0', AWS_PAGER='')
        self.env.pop('TF_WORKSPACE', None)
        self.cli_config = self.path('terraform.rc')
        contents = 'disable_checkpoint = true\n'
        if self.cli_config.exists():
            require(self.cli_config.read_text() == contents, 'Terraform CLI configuration changed')
        else:
            self.cli_config.write_text(contents)
            self.cli_config.chmod(0o600)
        self.env['TF_CLI_CONFIG_FILE'] = str(self.cli_config)

    def path(self, name):
        return self.execution / name

    # ----- unsettled process groups ----------------------------------------

    def record_unsettled(self, group):
        """Survives this process: every later run refuses until `settle` proves the group gone."""
        save(self.path('unsettled.json'), {'process_group': group, 'at': now().isoformat()})

    def settled_guard(self):
        require(not self.path('unsettled.json').exists(), 'Unsettled owned process group from an earlier command; no further tool or AWS calls until `settle` proves it gone')

    def settle(self):
        marker = self.path('unsettled.json')
        require(marker.exists(), 'Nothing is unsettled')
        group = read(marker)['process_group']
        try:
            os.killpg(group, 0)
        except ProcessLookupError:
            marker.unlink()
            return {'status': 'settled', 'process_group': group}
        except PermissionError:
            pass
        raise Refused(f'Process group {group} still exists; stop it before any further tool or AWS call')

    def settle_group(self, process):
        if process is None:
            return True
        for sig in [signal.SIGTERM, signal.SIGKILL]:
            try:
                os.killpg(process.pid, sig)
            except ProcessLookupError:
                return True
            except PermissionError:
                pass
            end = time.monotonic() + 5
            while time.monotonic() < end:
                process.poll()
                try:
                    os.killpg(process.pid, 0)
                except ProcessLookupError:
                    return True
                except PermissionError:
                    pass
                time.sleep(.1)
        return False

    # ----- identity, deadline, bindings ------------------------------------

    def environment_guard(self):
        env = self.env
        require(not any(env.get(k) for k in ['AWS_ACCESS_KEY_ID', 'AWS_SECRET_ACCESS_KEY', 'AWS_SESSION_TOKEN', 'AWS_WEB_IDENTITY_TOKEN_FILE', 'AWS_ROLE_ARN', 'AWS_ENDPOINT_URL']),
                'Run under the refreshing pippen sandbox exec selector; static and fallback credentials are refused')
        require(not any(k.startswith('AWS_ENDPOINT_URL_') and v for k, v in env.items()), 'Endpoint overrides are refused')
        require(env.get('AWS_PROFILE') == 'pippen-sandbox' and env.get('AWS_SHARED_CREDENTIALS_FILE') == '/dev/null' and env.get('AWS_EC2_METADATA_DISABLED') == 'true',
                'Run under the refreshing pippen sandbox exec selector')
        require(env.get('PIPPEN_SANDBOX_ACCOUNT_ID') == ACCOUNT and env.get('PIPPEN_SANDBOX_AGENT_ID') == AGENT and env.get('PIPPEN_SANDBOX_SESSION_ID') == self.v['pippen']['session_id'],
                'The running lease does not match these inputs')
        config = configparser.ConfigParser(interpolation=None)
        require(config.read(env.get('AWS_CONFIG_FILE', '')), 'Missing refreshing selector')
        require(config.sections() == ['profile pippen-sandbox'] and set(config['profile pippen-sandbox']) == {'region', 'credential_process'}
                and config['profile pippen-sandbox']['region'] == self.v['region'], 'Unexpected AWS selector')

    def caller(self):
        result = self.aws('sts', 'get-caller-identity')
        value = json.loads(result.stdout)
        expected = f"arn:aws:sts::{ACCOUNT}:assumed-role/agent-session/agent-{self.v['pippen']['session_id']}"
        require(value.get('Account') == ACCOUNT, f'Wrong account; only {ACCOUNT} is allowed')
        require(value.get('Arn') == expected, 'Wrong caller; no fallback identity is inferred')
        return value['Arn']

    def deadline_guard(self):
        deadline = dt.datetime.fromisoformat(self.v['deadline'].replace('Z', '+00:00'))
        require(now() < deadline, 'Deadline expired; retire this lifecycle instead of extending it')

    def guards(self, forward):
        self.environment_guard()
        arn = self.caller()
        if forward:
            self.deadline_guard()
        return arn

    def bindings(self):
        repo = ROOT.parents[2]
        commit = subprocess.check_output(['git', '-C', str(repo), 'rev-parse', 'HEAD'], text=True).strip()
        require(commit == self.v['source_sha'], 'Source does not match committed inputs')
        require(not subprocess.check_output(['git', '-C', str(repo), 'status', '--porcelain'], text=True).strip(), 'Commit all source first')
        scope = [str(ROOT.relative_to(repo)), 'terraform/modules']
        tracked = subprocess.check_output(['git', '-C', str(repo), 'ls-files', '--', *scope], text=True).splitlines()
        version = json.loads(subprocess.check_output([self.terraform, 'version', '-json'], cwd=ROOT, env=self.env, text=True))
        providers = sorted(p for p in (ROOT / '.terraform/providers').rglob('terraform-provider-*') if p.is_file())
        require(providers, 'Initialized locked providers are required')
        return {
            'source_commit': commit,
            'sources_sha256': digest(canonical({name: sha(repo / name) for name in tracked})),
            'inputs_sha256': sha(self.variables),
            'provider_lock_sha256': sha(ROOT / '.terraform.lock.hcl'),
            'provider_binaries_sha256': digest(canonical({p.name: sha(p) for p in providers})),
            'terraform_sha256': sha(self.terraform),
            'terraform_version': version.get('terraform_version'),
            'runner_sha256': sha(__file__),
        }

    # ----- phase ledger ----------------------------------------------------

    def phases(self):
        path = self.path('phases.json')
        return read(path) if path.exists() else {}

    def mark(self, phase, status, **extra):
        phases = self.phases()
        record = {'status': status, 'at': now().isoformat(), **extra}
        phases[phase] = record
        save(self.path('phases.json'), phases)
        with self.path('attempts.jsonl').open('a') as handle:
            os.chmod(self.path('attempts.jsonl'), 0o600)
            handle.write(json.dumps({'phase': phase, **record}, sort_keys=True) + '\n')
            handle.flush()
            os.fsync(handle.fileno())

    def status_of(self, phase):
        return self.phases().get(phase, {}).get('status')

    def order_guard(self, phase):
        phases = self.phases()
        if phase in FORWARD:
            require(not any(p in phases for p in RETIRE), 'Retirement has started; forward phases are closed')
            for other, record in phases.items():
                require(record['status'] not in UNSETTLED, f'Phase {other} is {record["status"]}; retire or reconcile it, do not continue')
            index = FORWARD.index(phase)
            if index:
                require(phases.get(FORWARD[index - 1], {}).get('status') in DONE, f'Phase {FORWARD[index - 1]} must complete before {phase}')
            require(phases.get(phase, {}).get('status') not in DONE, f'Phase {phase} already ran; no blind re-run')
            return
        if phase in RETIRE:
            open_phases = sorted(p for p in RECONCILABLE if phases.get(p, {}).get('status') in UNRECONCILED)
            require(not open_phases, f'Phases {open_phases} never finished capture; run reconcile on each before retiring')
        if phase == 'release':
            require('destroy' not in phases, 'Destroy has started')
        elif phase == 'inventory':
            require(self.status_of('release') in RELEASED, 'Release must complete before inventory')
        elif phase == 'drain':
            require(self.status_of('inventory') in DONE, 'Inventory must complete before drain')
        elif phase == 'destroy':
            require(self.status_of('release') in RELEASED, 'Release must complete before destroy')
            if self.path('contract.json').exists():
                require(self.status_of('drain') in DONE, 'Drain must complete before destroy')
        elif phase == 'backups':
            require(self.status_of('destroy') in DONE, 'Destroy must complete before backups')
        elif phase == 'absence':
            require(self.status_of('backups') in DONE, 'Backups must complete before absence')

    def attempted(self):
        return any(p in self.phases() for p in TERRAFORM_PHASES)

    def backend_path(self):
        """The local state file the shared Terraform root is configured for, or None."""
        try:
            value = json.loads((ROOT / '.terraform/terraform.tfstate').read_text())
            return value['backend']['config']['path']
        except (OSError, ValueError, KeyError, TypeError):
            return None

    def own_backend(self):
        """Point the shared root at this execution's state and prove it before reading through it."""
        if self.backend_path() != str(self.state):
            self.run([self.terraform, 'init', '-input=false', '-no-color', '-lockfile=readonly', '-reconfigure', '-backend-config=path=' + str(self.state)], timeout=600)
        require(self.backend_path() == str(self.state), "The shared Terraform root points at another execution's state; refusing to read it")

    def read_state(self):
        """Parsed state of this execution, or None when it cannot be known."""
        try:
            self.own_backend()
            result = self.run([self.terraform, 'state', 'pull'], timeout=300, check=False)
        except (OSError, subprocess.SubprocessError, Refused, CommandInterrupted):
            return None
        if result.returncode or not result.stdout.strip():
            return None
        try:
            value = json.loads(result.stdout)
        except ValueError:
            return None
        return value if isinstance(value, dict) and isinstance(value.get('resources'), list) and 'serial' in value else None

    def partial_lifecycle(self):
        phases = self.phases()
        return any(p in phases and phases[p]['status'] not in DONE for p in FORWARD_TERRAFORM)

    def release_scope(self, value):
        """Exact addresses a partial lifecycle must release: protected databases and compute only."""
        targets = []
        for resource in value['resources']:
            if resource.get('mode') != 'managed' or resource.get('type') not in ('aws_db_instance', 'aws_instance'):
                continue
            base = '.'.join(x for x in [resource.get('module'), resource['type'], resource['name']] if x)
            for instance in resource.get('instances', []):
                key = instance.get('index_key')
                address = base if key is None else f'{base}[{json.dumps(key)}]'
                if resource['type'] == 'aws_db_instance' and (instance.get('status') == 'tainted' or instance.get('deposed')):
                    raise Refused(f'{address} is tainted or deposed, so release would replace it. Review it, run `terraform untaint` under the lease if it is intact, then plan release again')
                if resource['type'] == 'aws_instance' or instance.get('attributes', {}).get('deletion_protection') is not False:
                    targets.append(address)
        return sorted(targets)

    def state_guard(self, phase):
        """A failed or empty read after an attempted apply never means no resources."""
        value = self.read_state()
        if not self.attempted():
            require(value is not None and value['resources'], 'Nothing has been applied; there is nothing to retire')
            return value
        if value is None or not value['resources']:
            self.mark_unknown(phase)
            raise Refused('State is unknown after an attempted apply; exact-owned recovery is required, do not assume no resources')
        return value

    def mark_unknown(self, phase):
        self.mark(phase, 'unknown', reason='state unreadable or empty after an attempted apply')

    # ----- tools -----------------------------------------------------------

    def aws(self, service, operation, *args, check=True):
        return self.run(['aws', '--region', self.v['region'], '--no-cli-pager', service, operation, *args, '--output', 'json'], timeout=120, check=check)

    def run(self, args, timeout=2700, check=True):
        self.settled_guard()
        if self.transport:
            return self.transport(args, timeout=timeout, check=check)
        prefix = self.path('commands') / str(time.time_ns())
        prefix.parent.mkdir(mode=0o700, exist_ok=True)
        metadata = {'tool': args[0], 'subcommand': args[1:3], 'outcome': 'launching'}
        save(prefix.with_suffix('.json'), metadata)
        requested = None
        process = None
        previous = {}

        def interrupt(signum, _frame):
            nonlocal requested
            if requested is None:
                requested = signum

        try:
            for sig in [signal.SIGTERM, signal.SIGHUP, signal.SIGINT]:
                previous[sig] = signal.signal(sig, interrupt)
            with prefix.with_suffix('.stdout').open('w') as out, prefix.with_suffix('.stderr').open('w') as err:
                os.chmod(out.name, 0o600)
                os.chmod(err.name, 0o600)
                if requested is not None:
                    raise CommandInterrupted(requested)
                process = subprocess.Popen(args, cwd=ROOT, env=self.env, stdout=out, stderr=err, start_new_session=True, text=True)
                end = time.monotonic() + timeout
                while process.poll() is None:
                    if requested is not None:
                        raise CommandInterrupted(requested)
                    if time.monotonic() >= end:
                        raise subprocess.TimeoutExpired(args, timeout)
                    time.sleep(.1)
            settled = self.settle_group(process)
            if not settled:
                self.record_unsettled(process.pid)
            require(settled, 'Unsettled owned process group; quarantine before recovery')
        except BaseException as error:
            settled = self.settle_group(process)
            if not settled and process is not None:
                self.record_unsettled(process.pid)
            metadata.update(outcome='interrupted', error_type=type(error).__name__, process_group_absent=settled)
            save(prefix.with_suffix('.json'), metadata)
            raise
        finally:
            for sig, handler in previous.items():
                signal.signal(sig, handler)
        if requested is not None:
            metadata.update(outcome='interrupted', signal=requested)
            save(prefix.with_suffix('.json'), metadata)
            raise CommandInterrupted(requested)
        metadata.update(outcome='completed', exit_code=process.returncode)
        save(prefix.with_suffix('.json'), metadata)
        result = subprocess.CompletedProcess(args, process.returncode, prefix.with_suffix('.stdout').read_text(), prefix.with_suffix('.stderr').read_text())
        require(not check or result.returncode == 0, 'Tool failed; private command evidence is preserved')
        return result

    # ----- saved plans -----------------------------------------------------

    def phase_variables(self, phase):
        value = dict(self.v)
        # State only carries the uploaded version once a compute phase was attempted. Sending it to
        # retirement earlier would update the verifier resources, which the release guard refuses.
        if phase in ('seed', 'restore') or (phase in ('release', 'destroy') and 'seed' in self.phases()):
            value['payload_version_id'] = read(self.path('upload.json'))['version_id']
        if phase == 'restore' or (phase in ('release', 'destroy') and 'restore' in self.phases()):
            value['restore_checkpoint'] = read(self.path('restore-checkpoint.json'))
        value['retire'] = phase in ('release', 'destroy')
        return value

    def plan(self, phase):
        require(phase in TERRAFORM_PHASES, f'{phase} is not a Terraform phase')
        forward = phase in FORWARD
        self.guards(forward)
        self.order_guard(phase)
        targets = []
        if not forward:
            state = self.state_guard(phase)
            if phase == 'release' and self.partial_lifecycle():
                # An unfinished forward phase leaves resources missing, so an untargeted release
                # plan would create them. The guard below still refuses any create.
                targets = self.release_scope(state)
                if not targets:
                    self.mark('release', 'not-required', reason='partial lifecycle has no protected database or compute in state', state_serial=state['serial'])
                    return {'phase': 'release', 'status': 'not-required', 'next': 'plan --phase destroy'}
        self.run([self.terraform, 'init', '-input=false', '-no-color', '-lockfile=readonly', '-reconfigure', '-backend-config=path=' + str(self.state)])
        before = self.bindings()
        variables = self.path(phase + '.tfvars.json')
        save(variables, self.phase_variables(phase))
        saved = self.path(phase + '.tfplan')
        args = [self.terraform, 'plan', '-input=false', '-no-color', '-lock-timeout=60s', '-var-file=' + str(variables), '-out=' + str(saved)]
        if phase == 'destroy':
            args.append('-destroy')
        args += ['-target=' + address for address in targets]
        self.run(args)
        rendered = json.loads(self.run([self.terraform, 'show', '-json', str(saved)]).stdout)
        changes = summarize(rendered)
        guard_changes(phase, changes)
        require(self.bindings() == before, 'Source, inputs or providers changed while planning')
        packet = {'phase': phase, 'plan_sha256': sha(saved), 'plan_json_sha256': digest(canonical(rendered)), 'variables_sha256': sha(variables),
                  'state_sha256': sha(self.state) if self.state.exists() else None, 'bindings': before, 'changes': changes, 'targets': targets}
        save(self.path(phase + '.packet.json'), packet)
        summary = self.path(phase + '.summary.txt')
        summary.write_text(render_summary(changes, packet['plan_sha256'], targets))
        summary.chmod(0o600)
        return {'phase': phase, 'plan_sha256': packet['plan_sha256'], 'changes': len(changes), 'summary': str(summary), 'next': f'review, then apply --phase {phase} --plan-sha256 {packet["plan_sha256"]}'}

    def apply(self, phase, plan_sha256):
        self.settled_guard()
        require(phase in TERRAFORM_PHASES, f'{phase} is not a Terraform phase')
        forward = phase in FORWARD
        arn = self.guards(forward)
        self.order_guard(phase)
        saved = self.path(phase + '.tfplan')
        require(self.path(phase + '.packet.json').exists() and saved.exists(), 'Plan this phase first')
        packet = read(self.path(phase + '.packet.json'))
        require(plan_sha256 == packet['plan_sha256'] == sha(saved), 'The saved plan does not match the digest you reviewed')
        require(self.bindings() == packet['bindings'], 'Source, inputs, lock or provider changed since this plan; plan again')
        require((sha(self.state) if self.state.exists() else None) == packet['state_sha256'], 'State changed since this plan; plan again')
        require(sha(self.path(phase + '.tfvars.json')) == packet['variables_sha256'], 'Phase variables changed since this plan')
        rendered = json.loads(self.run([self.terraform, 'show', '-json', str(saved)]).stdout)
        require(digest(canonical(rendered)) == packet['plan_json_sha256'], 'Saved plan contents changed')
        self.mark(phase, 'pending', plan_sha256=plan_sha256, caller=arn)
        error = None
        code = 1
        try:
            code = self.run([self.terraform, 'apply', '-input=false', '-no-color', '-lock-timeout=60s', str(saved)], check=False).returncode
        except (OSError, subprocess.SubprocessError, Refused, CommandInterrupted) as caught:
            error = caught
        return self.capture(phase, code, error)

    def capture(self, phase, code, error):
        """Persist state and native IDs before anything is validated."""
        value = self.read_state()
        record = {'exit_code': code, 'error': type(error).__name__ if error else None, 'state_known': value is not None}
        destroying = phase == 'destroy'
        if value is None or (not value['resources'] and not (destroying and code == 0 and error is None)):
            save(self.path(phase + '.capture.json'), {**record, 'resources': None})
            self.mark_unknown(phase)
            raise Refused(f'State is unknown after apply of {phase}; do not assume no resources, exact-owned recovery is required')
        addresses = sorted(f"{r.get('module', '')}.{r.get('type')}.{r.get('name')}" for r in value['resources'])
        contract = None
        if not destroying:
            contract = self.capture_contract()
        # After a clean forward apply, or once a contract has been captured, the output must
        # exist, so a failed read is retryable. A failed apply or a partial lifecycle's cleanup
        # may legitimately have no output, and must not get stuck waiting for one.
        expected = phase in FORWARD or self.path('contract.json').exists()
        unreadable = not destroying and contract is None and self.contract_read_failed and code == 0 and error is None and expected
        native = False if unreadable else (self.capture_native(contract) if contract else None)
        save(self.path(phase + '.capture.json'), {**record, 'serial': value['serial'], 'resources': addresses, 'native_complete': native})
        if native is False:
            self.mark(phase, 'unknown', reason='contract or native metadata read failed after apply', exit_code=code)
            raise Refused(f'The contract or native metadata for {phase} could not be read, so the retirement ledger would be incomplete; run reconcile --phase {phase}')
        if error or code:
            self.mark(phase, 'interrupted' if error else 'failed', exit_code=code)
            raise Refused(f'Apply of {phase} did not complete; state was captured, retire this lifecycle')
        if phase in FORWARD or contract is not None:
            problems = validate_contract(contract, self.v, phase) if contract is not None else ['proof_contract']
            if problems:
                self.mark(phase, 'captured-invalid', problems=problems)
                raise Refused(f'Captured contract failed validation: {problems}')
        self.mark(phase, 'captured')
        return {'phase': phase, 'status': 'captured', 'resources': len(addresses)}

    def reconcile(self, phase):
        """Record what an interrupted apply or upload actually left, so retirement can count it."""
        require(phase in RECONCILABLE, f'{phase} cannot be reconciled')
        require(self.status_of(phase) in UNRECONCILED, f'{phase} is not pending or unknown; nothing to reconcile')
        self.guards(False)
        if phase == 'upload':
            self.mark(phase, 'failed', reason='upload outcome never confirmed; inventory lists every object version')
            return {'phase': phase, 'status': 'failed'}
        prior = read(self.path(phase + '.capture.json')) if self.path(phase + '.capture.json').exists() else {}
        # Only a clean apply whose native read alone failed can still finish as captured.
        clean = prior.get('native_complete') is False and prior.get('exit_code') == 0 and prior.get('error') is None
        try:
            self.capture(phase, 0 if clean else 1, None)
        except Refused:
            if self.status_of(phase) in UNRECONCILED:
                raise
        return {'phase': phase, 'status': self.status_of(phase)}

    def capture_contract(self):
        # A failed read says nothing about the contract: it stays recoverable, unlike a
        # successful read of a null or wrong-shaped output, which fails validation.
        self.contract_read_failed = False
        try:
            self.own_backend()
            result = self.run([self.terraform, 'output', '-json', 'proof_contract'], timeout=300, check=False)
            if result.returncode != 0:
                self.contract_read_failed = True
                return None
            value = json.loads(result.stdout) if result.stdout.strip() else None
        except (ValueError, OSError, subprocess.SubprocessError, Refused, CommandInterrupted):
            self.contract_read_failed = True
            return None
        if not isinstance(value, dict):
            return None
        save(self.path('contract.json'), value)
        history = read(self.path('compute-history.json')) if self.path('compute-history.json').exists() else []
        if value.get('compute') and value['compute'] not in history:
            history.append(value['compute'])
            save(self.path('compute-history.json'), history)
        return value

    def capture_native(self, contract):
        path = self.path('native.json')
        native = read(path) if path.exists() else {'database_resource_ids': [], 'database_network_interface_ids': []}
        complete = True
        identifiers = [contract['database']['identifier']] + ([contract['restored']['identifier']] if contract.get('restored') else [])
        for identifier in identifiers:
            value = self.try_aws('rds', 'describe-db-instances', '--db-instance-identifier', identifier)
            if value is None:
                complete = False
                continue
            resource = value['DBInstances'][0]['DbiResourceId']
            if resource not in native['database_resource_ids']:
                native['database_resource_ids'].append(resource)
        value = self.try_aws('ec2', 'describe-network-interfaces', '--filters', 'Name=group-id,Values=' + contract['security_group_ids'][0])
        if value is None:
            complete = False
        else:
            native['database_network_interface_ids'] = sorted(set(native['database_network_interface_ids']) | {x['NetworkInterfaceId'] for x in value['NetworkInterfaces']})
        save(path, native)
        return complete

    def try_aws(self, service, operation, *args):
        try:
            result = self.aws(service, operation, *args, check=False)
            return json.loads(result.stdout) if result.returncode == 0 else None
        except (ValueError, OSError, subprocess.SubprocessError, Refused, CommandInterrupted):
            return None

    def contract(self):
        require(self.path('contract.json').exists(), 'No proof contract was captured')
        return read(self.path('contract.json'))

    # ----- non-Terraform phases --------------------------------------------

    def prerequisites(self):
        self.guards(True)
        self.order_guard('prerequisites')
        c = self.contract()
        require(c.get('compute') is None, 'Prerequisites run before any compute exists')
        database = json.loads(self.aws('rds', 'describe-db-instances', '--db-instance-identifier', c['database']['identifier']).stdout)['DBInstances'][0]
        require(database['DBInstanceStatus'] == 'available' and database['Endpoint']['Address'] == c['database']['host'], 'Database is not available at the captured endpoint')
        require(database['EngineVersion'] == self.v['postgres_version'], 'Database engine version differs from the input')
        require(database.get('MasterUserSecret', {}).get('SecretArn') == c['database']['secret_arn'], 'Master secret mapping differs')
        versions = json.loads(self.aws('secretsmanager', 'list-secret-version-ids', '--secret-id', c['runtime_secret']['arn'], '--include-deprecated').stdout)
        require(versions.get('Versions', []) == [], 'Runtime secret must be empty before the seed')
        role = c['verifier_identity']['role_arn'].split('/')[-1]
        require(json.loads(self.aws('iam', 'get-role', '--role-name', role).stdout)['Role']['Arn'] == c['verifier_identity']['role_arn'], 'Verifier role differs')
        groups = json.loads(self.aws('ec2', 'describe-security-groups', '--group-ids', *c['security_group_ids']).stdout)['SecurityGroups']
        require({g['GroupId'] for g in groups} == set(c['security_group_ids']) and all(g['VpcId'] == c['vpc_id'] for g in groups), 'Security groups differ')
        subnets = json.loads(self.aws('ec2', 'describe-subnets', '--subnet-ids', *c['private_subnet_ids']).stdout)['Subnets']
        require({s['SubnetId'] for s in subnets} == set(c['private_subnet_ids']) and all(s['VpcId'] == c['vpc_id'] for s in subnets), 'Private subnets differ')
        versioning = json.loads(self.aws('s3api', 'get-bucket-versioning', '--bucket', c['bucket'], '--expected-bucket-owner', ACCOUNT).stdout)
        require(versioning.get('Status') == 'Enabled', 'Bucket versioning must be enabled')
        self.mark('prerequisites', 'ok')
        return {'phase': 'prerequisites', 'status': 'ok'}

    def upload(self, archive):
        arn = self.guards(True)
        self.order_guard('upload')
        c = self.contract()
        require(sha(archive) == self.v['payload_sha256'] == c['payload_sha256'], 'Archive does not match the reviewed payload digest')
        self.mark('upload', 'pending', caller=arn)
        args = ['--bucket', c['bucket'], '--key', c['payload_key'], '--expected-bucket-owner', ACCOUNT]
        value = self.try_aws('s3api', 'put-object', *args, '--body', str(archive), '--server-side-encryption', 'aws:kms')
        version = value.get('VersionId') if value else None
        if not version or version == 'null':
            self.mark('upload', 'unknown', reason='no immutable VersionId returned')
            raise Refused('Upload outcome is unknown; retire this lifecycle')
        head = self.try_aws('s3api', 'head-object', *args, '--version-id', version)
        if not head or head.get('ContentLength') != Path(archive).stat().st_size:
            self.mark('upload', 'unknown', reason='uploaded version could not be confirmed')
            raise Refused('Upload could not be confirmed; retire this lifecycle')
        save(self.path('upload.json'), {'version_id': version, 'key': c['payload_key'], 'sha256': self.v['payload_sha256']})
        self.mark('upload', 'ok', version_id=version)
        return {'phase': 'upload', 'status': 'ok', 'version_id': version}

    def receipt(self, phase):
        require(phase in ('seed', 'restore'), 'Receipts exist for seed and restore only')
        name = phase + '-receipt'
        self.guards(True)
        self.order_guard(name)
        c = self.contract()
        key = f'receipts/{phase}.json'
        listing = json.loads(self.aws('s3api', 'list-object-versions', '--bucket', c['bucket'], '--prefix', key, '--expected-bucket-owner', ACCOUNT).stdout)
        versions = [x for x in listing.get('Versions', []) if x['Key'] == key]
        require(versions, 'The receipt is not published yet; check again before the deadline')
        require(len(versions) == 1 and not listing.get('DeleteMarkers'), 'More than one receipt version; quarantine')
        version = versions[0]['VersionId']
        path = self.path(name + '.json')
        self.aws('s3api', 'get-object', '--bucket', c['bucket'], '--key', key, '--version-id', version, '--expected-bucket-owner', ACCOUNT, str(path))
        path.chmod(0o600)
        value = read(path)
        require(value.get('ok') is True and value.get('phase') == phase and value.get('source_sha') == self.v['source_sha'] and value.get('marker') == c['marker'], 'Receipt does not match this lifecycle')
        require(value.get('application_sql_ready') is False, 'A receipt may not claim application readiness')
        native = read(self.path('native.json'))['database_resource_ids']
        expected = (c.get('restored') or {}).get('resource_id') if phase == 'restore' else (native[0] if native else None)
        require(expected and value.get('database_resource_id') == expected, 'Receipt does not name the captured database')
        if phase == 'seed':
            save(self.path('restore-checkpoint.json'), {'seed_receipt_sha256': sha(path), 'seed_receipt_version_id': version, 'secret_version_id': value['secret_version_id'],
                                                         'runtime_secret_version_id': value['runtime_secret_version_id'], 'seed_evidence_sha256': value['guest']['receipt']['evidenceSha256']})
        else:
            seed = read(self.path('seed-receipt.json'))
            require(value['database_resource_id'] != seed['database_resource_id'], 'Restore must run on a distinct database')
        self.mark(name, 'ok', version_id=version, sha256=sha(path))
        return {'phase': name, 'status': 'ok', 'version_id': version}

    # ----- retirement ------------------------------------------------------

    def ledger(self):
        path = self.path('ledger.json')
        require(path.exists(), 'Inventory has not run')
        return read(path)

    def inventory(self):
        self.guards(False)
        self.order_guard('inventory')
        c = self.contract()
        native = read(self.path('native.json'))
        history = read(self.path('compute-history.json')) if self.path('compute-history.json').exists() else []
        running = json.loads(self.aws('ec2', 'describe-instances', '--filters', 'Name=tag:proof:run,Values=' + self.v['run_id']).stdout)
        found = {i['InstanceId'] for r in running.get('Reservations', []) for i in r.get('Instances', []) if i.get('State', {}).get('Name') != 'terminated'}
        require(found <= {x['instance_id'] for x in history}, 'Untracked compute exists; quarantine')
        secrets = json.loads(self.aws('secretsmanager', 'list-secret-version-ids', '--secret-id', c['runtime_secret']['arn'], '--include-deprecated').stdout)
        require(not secrets.get('NextToken'), 'Secret inventory is truncated')
        bucket = ['--bucket', c['bucket'], '--expected-bucket-owner', ACCOUNT]
        listed = json.loads(self.aws('s3api', 'list-object-versions', *bucket).stdout or '{}')
        uploads = json.loads(self.aws('s3api', 'list-multipart-uploads', *bucket).stdout or '{}')
        require(not listed.get('IsTruncated') and not uploads.get('IsTruncated'), 'Bucket inventory is truncated')
        save(self.path('ledger.json'), {
            'contract': c,
            'runtime_secret_inventory': {'arn': c['runtime_secret']['arn'], 'version_ids': [x['VersionId'] for x in secrets.get('Versions', [])], 'complete': True},
            'compute_history': history,
            'compute_released': self.status_of('release') in RELEASED and c.get('compute') is None,
            'compute_inventory': {'complete': True, 'instance_ids': [x['instance_id'] for x in history]},
            'database_resource_ids': native['database_resource_ids'],
            'database_network_interface_ids': native['database_network_interface_ids'],
            'managed_secret_arns': [c['database']['secret_arn']],
            'object_versions': [{'Key': x['Key'], 'VersionId': x['VersionId']} for x in listed.get('Versions', []) + listed.get('DeleteMarkers', [])],
            'multipart_uploads': [{'Key': x['Key'], 'UploadId': x['UploadId']} for x in uploads.get('Uploads', [])],
        })
        self.mark('inventory', 'ok')
        return {'phase': 'inventory', 'status': 'ok'}

    def drain(self, ledger_sha256):
        arn = self.guards(False)
        self.order_guard('drain')
        require(ledger_sha256 == sha(self.path('ledger.json')), 'The drain ledger does not match the digest you reviewed')
        self.mark('drain', 'pending', caller=arn, ledger_sha256=ledger_sha256)
        import drain_bucket
        try:
            result = drain_bucket.drain(self.ledger())
        except Exception as error:
            self.mark('drain', 'failed', error=type(error).__name__)
            raise Refused('Drain failed; re-run inventory before another attempt') from error
        self.mark('drain', 'ok', versions_deleted=result['versions_deleted'], ledger_sha256=ledger_sha256)
        return {'phase': 'drain', **result}

    def backups(self):
        """Delete retained automated backups of this lifecycle's own databases only."""
        arn = self.guards(False)
        self.order_guard('backups')
        # Deletion authority comes from the ledger the operator reviewed for drain,
        # and every ID must be one this lifecycle captured from AWS itself.
        reviewed = self.phases().get('drain', {}).get('ledger_sha256')
        require(reviewed and reviewed == sha(self.path('ledger.json')), 'The ledger changed after the reviewed drain; refusing to delete backups')
        ledger = self.ledger()
        captured = read(self.path('native.json'))['database_resource_ids']
        require(all(resource_id in captured for resource_id in ledger['database_resource_ids']), 'The ledger names a database this lifecycle did not capture; refusing to delete backups')
        self.mark('backups', 'pending', caller=arn)
        deleted, waiting = [], []
        for resource_id in ledger['database_resource_ids']:
            result = self.aws('rds', 'describe-db-instance-automated-backups', '--dbi-resource-id', resource_id, check=False)
            if result.returncode:
                if 'DBInstanceAutomatedBackupNotFound' in result.stderr:
                    continue
                self.mark('backups', 'failed', reason='could not list retained backups')
                raise Refused('Could not list retained automated backups; private command evidence is preserved')
            rows = json.loads(result.stdout or '{}').get('DBInstanceAutomatedBackups', [])
            if not all(row.get('DbiResourceId') == resource_id for row in rows):
                self.mark('backups', 'failed', reason='foreign backup returned')
                raise Refused('A backup for a different resource was returned; refusing to delete')
            if not rows:
                continue
            if any(row.get('Status') != 'retained' for row in rows):
                waiting.append(resource_id)
                continue
            if self.aws('rds', 'delete-db-instance-automated-backup', '--dbi-resource-id', resource_id, check=False).returncode:
                self.mark('backups', 'failed', reason='delete refused', deleted=deleted)
                raise Refused('Deleting a retained automated backup failed; absence will report it')
            deleted.append(resource_id)
        if waiting:
            self.mark('backups', 'failed', reason='not retained yet', waiting=waiting, deleted=deleted)
            raise Refused(f'Backups not retained yet for {waiting}; run backups again')
        self.mark('backups', 'ok', deleted=deleted)
        return {'phase': 'backups', 'status': 'ok', 'deleted': deleted}

    def absence(self):
        self.guards(False)
        self.order_guard('absence')
        import retirement
        try:
            result = retirement.check(self.ledger())
        except Exception as error:
            self.mark('absence', 'failed', error=type(error).__name__)
            raise Refused(f'Absence could not be established: {error}') from error
        self.mark('absence', 'ok' if result['ok'] else 'failed')
        return {'phase': 'absence', 'ok': result['ok'], 'absent': sum(result['checks'].values()), 'total': len(result['checks']),
                'still_present': sorted(k for k, v in result['checks'].items() if not v)}


def is_flagged(marks, key):
    return marks is True or (isinstance(marks, dict) and bool(marks.get(key)))


def show(value, sensitive):
    if sensitive:
        return '(sensitive)'
    if isinstance(value, (bool, int, float)) or value is None or (isinstance(value, str) and len(value) <= 80):
        return value
    return '(changed)'


def changed_attributes(change):
    before = change.get('before') if isinstance(change.get('before'), dict) else {}
    after = change.get('after') if isinstance(change.get('after'), dict) else {}
    unknown = change.get('after_unknown') if isinstance(change.get('after_unknown'), dict) else {}
    attributes = []
    for key in sorted(set(before) | set(after) | set(unknown)):
        pending = is_flagged(unknown, key)
        if not pending and before.get(key) == after.get(key):
            continue
        attributes.append({'name': key, 'before': show(before.get(key), is_flagged(change.get('before_sensitive'), key)),
                           'after': '(known after apply)' if pending else show(after.get(key), is_flagged(change.get('after_sensitive'), key))})
    return attributes


def summarize(rendered):
    changes = []
    for change in rendered.get('resource_changes', []):
        actions = change.get('change', {}).get('actions', [])
        if actions in ([], ['no-op'], ['read']):
            continue
        entry = {'address': change['address'], 'type': change['type'], 'action': 'replace' if len(actions) > 1 else actions[0]}
        if entry['action'] in ('update', 'replace'):
            entry['attributes'] = changed_attributes(change['change'])
        changes.append(entry)
    return changes


def render_summary(changes, plan_sha256, targets=()):
    lines = [f'targeted to a partial lifecycle: {address}' for address in targets]
    for change in changes:
        lines.append(f'{change["action"]:<8} {change["address"]}')
        for attribute in change.get('attributes', []):
            lines.append(f'         {attribute["name"]}: {json.dumps(attribute["before"])} -> {json.dumps(attribute["after"])}')
    return '\n'.join(lines + [f'{len(changes)} changes', f'plan_sha256 {plan_sha256}']) + '\n'


def release_change_allowed(change):
    if change['action'] == 'delete':
        return change['type'] == 'aws_instance'
    if change['action'] == 'update' and change['type'] == 'aws_db_instance':
        return change.get('attributes') == [{'name': 'deletion_protection', 'before': True, 'after': False}]
    return False


def guard_changes(phase, changes):
    kinds = {c['type'] for c in changes if c['action'] in ('create', 'replace')}
    if phase != 'destroy':
        require(not [c for c in changes if c['type'] in ('aws_db_instance', 'aws_s3_bucket') and c['action'] in ('delete', 'replace')], 'Only destroy may delete data resources')
    if phase == 'provision':
        require('aws_instance' not in kinds, 'Provision must not create compute')
    if phase == 'release':
        refused = [c['address'] for c in changes if not release_change_allowed(c)]
        require(not refused, f'Release may only clear database deletion_protection and remove compute; refused {refused}')
    if phase == 'destroy':
        require(all(c['action'] == 'delete' for c in changes), 'A destroy plan may only delete')


def validate_contract(contract, variables, phase):
    problems = []
    wanted = {'account_id': variables['account_id'], 'region': variables['region'], 'source_sha': variables['source_sha'], 'run_id': variables['run_id'], 'lease': variables['pippen'], 'deadline': variables['deadline']}
    problems += [key for key, value in wanted.items() if contract.get(key) != value]
    if phase in ('seed', 'restore') and not contract.get('compute'):
        problems.append('compute')
    if phase == 'restore' and not contract.get('restored'):
        problems.append('restored')
    return problems


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('operation', choices=['plan', 'apply', 'prerequisites', 'upload', 'receipt', 'inventory', 'drain', 'backups', 'absence', 'reconcile', 'settle', 'status'])
    parser.add_argument('--execution', required=True)
    parser.add_argument('--variables', required=True)
    parser.add_argument('--terraform', required=True)
    parser.add_argument('--phase')
    parser.add_argument('--plan-sha256')
    parser.add_argument('--ledger-sha256')
    parser.add_argument('--archive')
    args = parser.parse_args()
    try:
        runner = Runner(args.execution, args.variables, args.terraform)
        (ROOT / '.terraform').mkdir(exist_ok=True)
        with runner.path('runner.lock').open('a') as lock, (ROOT / '.terraform/proof-runner.lock').open('a') as root_lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            # The Terraform root is shared between executions, so only one runner may use it.
            fcntl.flock(root_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            if args.operation == 'plan':
                result = runner.plan(args.phase)
            elif args.operation == 'apply':
                result = runner.apply(args.phase, args.plan_sha256)
            elif args.operation == 'prerequisites':
                result = runner.prerequisites()
            elif args.operation == 'upload':
                result = runner.upload(args.archive)
            elif args.operation == 'receipt':
                result = runner.receipt(args.phase)
            elif args.operation == 'inventory':
                result = runner.inventory()
                result['ledger_sha256'] = sha(runner.path('ledger.json'))
            elif args.operation == 'drain':
                result = runner.drain(args.ledger_sha256)
            elif args.operation == 'backups':
                result = runner.backups()
            elif args.operation == 'absence':
                result = runner.absence()
            elif args.operation == 'reconcile':
                result = runner.reconcile(args.phase)
            elif args.operation == 'settle':
                result = runner.settle()
            else:
                result = runner.phases()
    except Refused as error:
        print(json.dumps({'ok': False, 'refused': str(error)}))
        raise SystemExit(3) from None
    print(json.dumps(result))


if __name__ == '__main__':
    main()
