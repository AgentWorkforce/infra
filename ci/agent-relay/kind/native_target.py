"""Explicit native-only instance layout; no commands run during import.

This is the real Stack transport with a different validated identity and Kind
port map. It never changes an ownership, artifact, Docker, SQL or TLS guard.
The public Python seam may select it; the legacy CLI keeps its original layout.
"""
from dataclasses import dataclass
import errno
import hashlib
import json
import os
from pathlib import Path
import re
import socket

from native_recipe import require
from stack import Stack


@dataclass(frozen=True)
class NativeInstanceTarget:
    cluster_name: str
    state_relative: str
    http_port: int
    history_https_port: int
    site_https_port: int = 443
    listen_address: str = "127.0.0.1"

    def __post_init__(self):
        require(type(self.cluster_name) is str and
                re.fullmatch(r"agent-relay-core-native-[a-z0-9](?:[a-z0-9-]{0,36}[a-z0-9])?", self.cluster_name),
                "native_target_explicit_new_core_name_required")
        require(type(self.state_relative) is str and self.state_relative == ".kind/native-instances/" + self.cluster_name,
                "native_target_state_must_match_instance")
        require(type(self.listen_address) is str and self.listen_address == "127.0.0.1" and type(self.site_https_port) is int and
                self.site_https_port == 443, "native_target_loopback_site443_required")
        require(all(type(p) is int and 1024 <= p <= 65535 and p not in (8080, 8443)
                    for p in (self.http_port, self.history_https_port)) and
                self.http_port != self.history_https_port, "native_target_noncolliding_ports_required")

    @property
    def history_origin(self):
        return "https://history.kind.agentrelay.com:" + str(self.history_https_port)

    def document(self):
        return {"version": 1, "profile": "core", "clusterName": self.cluster_name,
                "stateRelative": self.state_relative, "listenAddress": self.listen_address,
                "httpPort": self.http_port, "siteHttpsPort": self.site_https_port,
                "historyHttpsPort": self.history_https_port,
                "siteOrigin": "https://relay.kind.agentrelay.com", "historyOrigin": self.history_origin}

    def binding(self):
        value = self.document()
        value["factorySourceSha256"] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
        return {**value, "targetSha256": hashlib.sha256(
            json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()}

    def state_path(self, root):
        root = Path(root)
        path = root / self.state_relative
        for part in (root, *list(path.parents)[:len(path.relative_to(root).parts) - 1], path):
            require(not part.is_symlink(), "native_target_state_symlink_refused")
        require(path.resolve().is_relative_to(root.resolve()), "native_target_state_escape_refused")
        return path

    def port_mappings(self):
        return [{"containerPort": container, "hostPort": host, "listenAddress": self.listen_address}
                for container, host in ((30080, self.http_port), (30443, self.site_https_port),
                                        (30443, self.history_https_port))]


class NativeInstanceStack(Stack):
    def __init__(self, profile, target):
        require(profile == "core" and type(target) is NativeInstanceTarget, "native_target_core_transport_required")
        self.native_target = target
        self._native_target_binding = target.binding()
        super().__init__(profile)

    def identity_layout(self, profile):
        require(profile == "core", "native_target_core_transport_required")
        return self.native_target.cluster_name, self.native_target.state_path(self.root)

    def prepare_private_directory(self, path, chmod=False):
        # Work through directory descriptors: a raced symlink must not turn a
        # constructor chmod/mkdir into an operation on retained state.
        state = self.native_target.state_path(self.root)
        require(path in (state, state / "tmp"), "native_target_private_path_required")
        fd = None
        try:
            flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
            fd = os.open(self.root, flags)
            for part in path.relative_to(self.root).parts:
                try:
                    os.mkdir(part, 0o700, dir_fd=fd)
                except FileExistsError:
                    pass
                child = os.open(part, flags, dir_fd=fd)
                os.close(fd); fd = child
            os.fchmod(fd, 0o700)
        except OSError:
            require(False, "native_target_private_directory_refused")
        finally:
            if fd is not None:
                os.close(fd)

    def native_port_mappings(self):
        return self.native_target.port_mappings()


def binding(stack):
    target = getattr(stack, "native_target", None)
    if target is None:
        require(not getattr(stack, "_native_target_binding", None), "native_target_transport_binding_missing")
        return None
    require(type(stack) is NativeInstanceStack and type(target) is NativeInstanceTarget,
            "native_target_real_stack_required")
    value = target.binding()
    require(value == stack._native_target_binding and stack.profile == "core" and
            stack.name == target.cluster_name and stack.state == target.state_path(stack.root) and
            stack.kubeconfig == stack.state / "kubeconfig" and stack.marker == stack.state / "cluster.json" and
            stack.native_port_mappings() == target.port_mappings(), "native_target_changed_since_admission")
    return value


def require_record(stack, record):
    value = binding(stack)
    require(record.get("nativeTarget") == value if value is not None else "nativeTarget" not in record,
            "native_target_ownership_binding_mismatch")


def require_free_ports(stack):
    """Preflight, not a reservation: Kind remains the final name/port arbiter."""
    value = binding(stack)
    if value is None:
        return
    for port in (value["httpPort"], value["siteHttpsPort"], value["historyHttpsPort"]):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
            probe.settimeout(1)
            if port == 443:
                # Do not require privileged host bind permission merely to
                # inspect the Desktop-compatible port. Kind owns final bind.
                require(probe.connect_ex((value["listenAddress"], port)) == errno.ECONNREFUSED,
                        "native_target_port_unavailable")
            else:
                try:
                    probe.bind((value["listenAddress"], port))
                except OSError:
                    require(False, "native_target_port_unavailable")
