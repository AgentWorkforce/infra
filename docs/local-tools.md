# Checkout-local Kind prerequisites

On an Apple Silicon Mac with Git, Python 3.9+ and Docker Desktop installed:

```sh
git clone https://github.com/AgentWorkforce/infra
cd infra
make local-tools
```

This installs Kind v0.30.0, Helm v4.3.1 and the pinned Python dependencies
under the ignored `.kind/tools` directory. Downloads are checked against
SHA-256 hashes recorded in source. No Homebrew, sudo, shell profile changes,
global Python packages or Docker configuration changes are needed. Repeating
the command reuses the tools after checking their cached hashes. amd64 Linux
is also supported.

To use those binaries with existing commands:

```sh
PATH="$PWD/.kind/tools:$PATH" make kind-render PYTHON="$PWD/.kind/tools/venv/bin/python3"
```

`local-tools` only prepares prerequisites. It creates no cluster, installs no
applications, and changes no hostname or certificate trust settings. Docker
Desktop supplies the `docker` and `kubectl` commands; Docker must be running
before provisioning a stack.
