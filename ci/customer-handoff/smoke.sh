#!/usr/bin/env bash
# Builds the development-preview customer handoff from HEAD, verifies both
# archive formats, extracts the tar.gz, and proves the extracted umbrella is
# installable on its own: helm dependency build + helm template with the
# shipped values-gcp.yaml. Also reports (as warnings) relative Markdown links
# in shipped documents that point outside the archive; the generated
# requirements doc links repository sources by design.
#
# Requires: git, python3, helm, tar, unzip. No Helm repositories need to be
# added: the dependency build runs against an empty repository config, the way
# a customer's fresh machine does.
set -euo pipefail

repo=$(git -C "$(dirname "$0")/../.." rev-parse --show-toplevel)
work=$(mktemp -d "${TMPDIR:-/tmp}/customer-handoff-smoke.XXXXXX")
trap 'rm -rf "$work"' EXIT

bash "$repo/scripts/package-customer-handoff.sh" build \
  --mode preview --dev-allow-dirty --format both --output-dir "$work/out"
bash "$repo/scripts/package-customer-handoff.sh" verify "$work/out" --dev-allow-preview

rev12=$(git -C "$repo" rev-parse HEAD | cut -c1-12)
tarball="$work/out/agent-relay-customer-handoff-$rev12-DEVELOPMENT-PREVIEW.tar.gz"
zipball="$work/out/agent-relay-customer-handoff-$rev12-DEVELOPMENT-PREVIEW.zip"
test -f "$tarball" && test -f "$zipball"

mkdir -p "$work/tar" "$work/zip"
tar -xzf "$tarball" -C "$work/tar"
unzip -q "$zipball" -d "$work/zip"
diff -r "$work/tar" "$work/zip" >/dev/null \
  || { echo "error: tar.gz and zip payloads differ" >&2; exit 1; }
root="$work/tar/agent-relay-customer-handoff"

# The umbrella resolves every file:// dependency inside the archive, and the
# shipped helm-deps.sh (included with scripts/selfhost) builds them with no
# `helm repo add` (empty repository config, as on a customer's fresh machine).
test -f "$root/scripts/selfhost/helm-deps.sh" \
  || { echo "error: handoff is missing scripts/selfhost/helm-deps.sh" >&2; exit 1; }
: >"$work/repositories.yaml"
HELM_REPOSITORY_CONFIG="$work/repositories.yaml" HELM_REPOSITORY_CACHE="$work/repository-cache" \
  bash "$root/scripts/selfhost/helm-deps.sh" >/dev/null
helm template agent-relay "$root/charts/agent-relay" \
  --namespace agent-relay -f "$root/charts/agent-relay/values-gcp.yaml" >"$work/rendered.yaml"
test -s "$work/rendered.yaml"

# The packaged skill finds the packaged layout.
(
  cd "$root"
  unset HANDOFF_ROOT
  # shellcheck disable=SC1091
  . .agents/skills/setting-up-self-hosted-agent-relay-gcp/scripts/resolve-layout.sh
  resolve_agent_relay_layout
  test "$AGENT_RELAY_BASE_VALUES_FILE" -ef "$root/charts/agent-relay/values-gcp.yaml"
)

# The hidden .agents skill directory ships complete (every tracked file, same
# bytes and mode), the Cursor-only location is gone, and the architecture
# diagrams ship with their renders.
skill=.agents/skills/setting-up-self-hosted-agent-relay-gcp
test -f "$root/$skill/SKILL.md" || { echo "error: $skill/SKILL.md is not in the handoff" >&2; exit 1; }
# Compare against the committed blobs: the handoff is built from HEAD.
while read -r mode _ _ f; do
  git -C "$repo" show "HEAD:$f" | cmp -s - "$root/$f" || { echo "error: $f is missing from or differs in the handoff" >&2; exit 1; }
  if test "$mode" = 100755 && ! test -x "$root/$f"; then echo "error: $f lost its executable bit" >&2; exit 1; fi
done < <(git -C "$repo" ls-tree -r HEAD -- "$skill")
test ! -e "$root/.cursor" || { echo "error: the handoff still ships .cursor/" >&2; exit 1; }
for d in agent-relay-architecture agent-relay-request-flow; do
  for ext in mmd svg png; do
    test -s "$root/docs/diagrams/$d.$ext" || { echo "error: docs/diagrams/$d.$ext is not in the handoff" >&2; exit 1; }
  done
done

# Relative links in shipped Markdown that do not resolve inside the archive.
python3 -I - "$root" <<'PY'
import re
import sys
from pathlib import Path

root = Path(sys.argv[1]).resolve()
link = re.compile(r"\]\(([^)\s]+)\)")
broken = []
for doc in sorted(root.rglob("*.md")):
    for target in link.findall(doc.read_text(encoding="utf-8")):
        if re.match(r"^[a-z][a-z0-9+.-]*:", target) or target.startswith("#"):
            continue
        path = target.split("#", 1)[0]
        if path and not (doc.parent / path).resolve().exists():
            broken.append(f"{doc.relative_to(root)}: {target}")
for item in broken:
    print(f"::warning::shipped Markdown links outside the handoff: {item}")
PY

echo "customer handoff smoke: OK ($(find "$root" -type f | wc -l | tr -d ' ') files)"
