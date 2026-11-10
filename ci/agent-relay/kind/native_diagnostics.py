"""Closed command diagnostics; never retain argv, output, paths or input data."""
from pathlib import Path
import re


_COMMANDS = {
    "helm": {"version", "list", "template", "upgrade", "repo", "dependency", "package"},
    "kind": {"get", "load", "create", "delete", "export", "version"},
    "kubectl": {"get", "exec", "apply", "create", "replace", "wait", "rollout", "label", "config"},
    "docker": {"image", "exec", "run", "inspect", "load", "pull", "ps", "info", "version"},
}
STAGES = {"transport_command"} | {tool + "_" + command for tool, commands in _COMMANDS.items() for command in commands}
REASONS = {"command_failed", "command_timeout", "workload_rename_guard", "unknown_flag",
           "chart_schema_refused", "resource_ownership_refused", "database_permission_denied",
           "database_undefined_column", "database_undefined_table", "database_invalid_password",
           "database_lock_unavailable", "native_operator_refused"}


def validate_details(value):
    if value is None or value == {}:
        return {}
    if (type(value) is not dict or set(value) not in ({"commandStage", "reasonCode"}, {"commandStage", "reasonCode", "exitCode"})
            or type(value["commandStage"]) is not str or value["commandStage"] not in STAGES
            or type(value["reasonCode"]) is not str or value["reasonCode"] not in REASONS
            or ("exitCode" in value and (type(value["exitCode"]) is not int or not -255 <= value["exitCode"] <= 255 or value["exitCode"] == 0))):
        raise ValueError("invalid_safe_command_diagnostic")
    return dict(value)


def command_details(argv, *, exit_code=None, stdout="", stderr="", timeout=False):
    tool = Path(str(argv[0])).name if argv else ""
    stage = "transport_command"
    # Fixed vocabulary only. Stop before a child command after kubectl exec;
    # neither an argument value nor an unknown executable is ever returned.
    for item in argv[1:]:
        if str(item) == "--":
            break
        if str(item) in _COMMANDS.get(tool, ()):
            stage = tool + "_" + str(item)
            break
    reason = "command_timeout" if timeout else "command_failed"
    text = (stderr or "")[-65536:] + (stdout or "")[-65536:]
    if not timeout:
        for literal, code in (
            ("sessions-pipeline-worker: workload rename requires a drained cutover", "workload_rename_guard"),
            ("unknown flag:", "unknown_flag"),
            ("values don't meet the specifications of the schema", "chart_schema_refused"),
            ("invalid ownership metadata", "resource_ownership_refused"),
        ):
            if literal in text:
                reason = code
                break
        else:
            match = re.search(r'"errorCode"\s*:\s*"(42501|42703|42P01|28P01|55P03|native_operator_failed)"', text)
            if match:
                reason = {"42501": "database_permission_denied", "42703": "database_undefined_column",
                          "42P01": "database_undefined_table", "28P01": "database_invalid_password",
                          "55P03": "database_lock_unavailable", "native_operator_failed": "native_operator_refused"}[match[1]]
    result = {"commandStage": stage, "reasonCode": reason}
    if type(exit_code) is int and -255 <= exit_code <= 255 and exit_code != 0:
        result["exitCode"] = exit_code
    return validate_details(result)
