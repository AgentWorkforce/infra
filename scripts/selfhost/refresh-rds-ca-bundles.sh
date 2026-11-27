#!/usr/bin/env bash
# The AWS RDS CA bundles the agent-relay chart ships (charts/agent-relay/files/rds-ca).
# With global.rdsCa.bundle set, the chart renders the rds-ca ConfigMap from one of
# them and gives every Postgres client its sha256, so operators never download the
# bundle, create the ConfigMap or paste the hash.
#
#   refresh-rds-ca-bundles.sh            download every bundle from
#                                        truststore.pki.rds.amazonaws.com and rewrite
#                                        the files, manifest.yaml and the
#                                        global.rdsCa.bundleSha256 table in
#                                        charts/agent-relay/values.yaml
#   refresh-rds-ca-bundles.sh --check    download and compare only; exit 1 and print
#                                        what changed when AWS has rotated a bundle
#   refresh-rds-ca-bundles.sh --verify   offline: the files, the manifest and the
#                                        values table agree (CI)
#
# A refresh changes the chart, so bump charts/agent-relay/Chart.yaml with it.
# Hash pinning means a rotated bundle reaches pods only through a chart upgrade.
set -euo pipefail
cd "$(dirname "$0")/../.."

mode=refresh
case "${1:-}" in
  "") ;;
  --check) mode=check ;;
  --verify) mode=verify ;;
  *) echo "usage: $0 [--check|--verify]" >&2; exit 2 ;;
esac

dir=charts/agent-relay/files/rds-ca
manifest=$dir/manifest.yaml
values=charts/agent-relay/values.yaml
base=https://truststore.pki.rds.amazonaws.com
# Commercial regions that publish a bundle (GovCloud and China use other truststores).
# A new AWS region goes here; the global bundle covers it in the meantime.
regions=(
  af-south-1 ap-east-1 ap-east-2 ap-northeast-1 ap-northeast-2 ap-northeast-3
  ap-south-1 ap-south-2 ap-southeast-1 ap-southeast-2 ap-southeast-3 ap-southeast-4
  ap-southeast-5 ap-southeast-6 ap-southeast-7 ca-central-1 ca-west-1 eu-central-1
  eu-central-2 eu-north-1 eu-south-1 eu-south-2 eu-west-1 eu-west-2 eu-west-3
  il-central-1 me-central-1 me-south-1 mx-central-1 sa-east-1 us-east-1 us-east-2
  us-west-1 us-west-2
)
bundles=(global "${regions[@]}")

sha() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }
url() { if [ "$1" = global ]; then echo "$base/global/global-bundle.pem"; else echo "$base/$1/$1-bundle.pem"; fi; }
# The manifest's recorded field for one bundle (one line per bundle).
recorded() { [ ! -f "$manifest" ] || sed -n "s/^  $1: .*$2: \([^,} ]*\).*/\1/p" "$manifest"; }

verify() {
  local fail=0 b f want table
  for b in "${bundles[@]}"; do
    f=$dir/$b-bundle.pem
    [ -f "$f" ] || { echo "::error::$f is missing"; fail=1; continue; }
    want=$(recorded "$b" sha256)
    [ "$(sha "$f")" = "$want" ] || { echo "::error::$f does not match its sha256 in $manifest"; fail=1; }
    table=$(sed -n "/# BEGIN rds-ca bundle hashes/,/# END rds-ca bundle hashes/s/^ *$b: \"\{0,1\}\([a-f0-9]*\)\"\{0,1\}$/\1/p" "$values")
    [ "$table" = "$want" ] || { echo "::error::global.rdsCa.bundleSha256.$b in $values does not match $manifest; rerun $0"; fail=1; }
    grep -q $'\r' "$f" && { echo "::error::$f has CR line endings"; fail=1; }
    grep -q -- '-----BEGIN CERTIFICATE-----' "$f" || { echo "::error::$f holds no certificate"; fail=1; }
  done
  local extra
  extra=$(comm -13 <({ printf '%s-bundle.pem\n' "${bundles[@]}"; echo manifest.yaml; } | sort) <(ls "$dir" | sort))
  [ -z "$extra" ] || { echo "::error::unexpected files in $dir: $extra"; fail=1; }
  [ "$(sed -n '/# BEGIN rds-ca bundle hashes/,/# END rds-ca bundle hashes/p' "$values" | grep -c '^ *[a-z0-9-]*: "[a-f0-9]\{64\}"$')" = "${#bundles[@]}" ] \
    || { echo "::error::the global.rdsCa.bundleSha256 table in $values must list exactly the ${#bundles[@]} shipped bundles"; fail=1; }
  return $fail
}

if [ "$mode" = verify ]; then
  verify && echo "rds-ca: ${#bundles[@]} bundles, manifest and values table agree"
  exit
fi

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
changed=()
for b in "${bundles[@]}"; do
  curl -fsS --retry 3 --proto '=https' -o "$tmp/$b-bundle.pem" "$(url "$b")"
  grep -q -- '-----BEGIN CERTIFICATE-----' "$tmp/$b-bundle.pem" || { echo "$(url "$b") returned no certificate" >&2; exit 1; }
  [ "$(sha "$tmp/$b-bundle.pem")" = "$(recorded "$b" sha256)" ] || changed+=("$b")
done

if [ "$mode" = check ]; then
  if [ ${#changed[@]} -eq 0 ]; then echo "rds-ca: all ${#bundles[@]} bundles match AWS"; exit 0; fi
  for b in "${changed[@]}"; do
    echo "::error::$(url "$b") changed: sha256 $(recorded "$b" sha256) -> $(sha "$tmp/$b-bundle.pem")"
    if [ -f "$dir/$b-bundle.pem" ]; then
      diff <(grep -c 'BEGIN CERTIFICATE' "$dir/$b-bundle.pem") <(grep -c 'BEGIN CERTIFICATE' "$tmp/$b-bundle.pem") >/dev/null \
        || echo "  certificates: $(grep -c 'BEGIN CERTIFICATE' "$dir/$b-bundle.pem") -> $(grep -c 'BEGIN CERTIFICATE' "$tmp/$b-bundle.pem")"
    fi
  done
  echo "Run scripts/selfhost/refresh-rds-ca-bundles.sh, bump charts/agent-relay/Chart.yaml and open a PR."
  exit 1
fi

today=$(date -u +%Y-%m-%d)
mkdir -p "$dir"
{
  echo "# Provenance of the AWS RDS CA bundles in this directory, which the chart"
  echo "# renders into the rds-ca ConfigMap when global.rdsCa.bundle is set."
  echo "# GENERATED by scripts/selfhost/refresh-rds-ca-bundles.sh; do not edit."
  echo "# fetched: the UTC date these exact bytes were first downloaded."
  echo "source: $base"
  echo "docs: https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/UsingWithRDS.SSL.html"
  echo "bundles:"
  for b in "${bundles[@]}"; do
    fetched=$(recorded "$b" fetched)
    if [ -z "$fetched" ] || printf '%s\n' "${changed[@]}" | grep -qx "$b"; then fetched=$today; fi
    printf '  %s: { url: %s, fetched: %s, bytes: %s, sha256: %s }\n' \
      "$b" "$(url "$b")" "$fetched" "$(wc -c < "$tmp/$b-bundle.pem" | tr -d ' ')" "$(sha "$tmp/$b-bundle.pem")"
  done
} > "$tmp/manifest.yaml"
rm -f "$dir"/*-bundle.pem
cp "$tmp"/*-bundle.pem "$dir/"
mv "$tmp/manifest.yaml" "$manifest"

# Rewrite the generated table in values.yaml between its markers.
python3 - "$values" "$manifest" <<'PY'
import re, sys
values, manifest = sys.argv[1], sys.argv[2]
rows = re.findall(r"^  ([a-z0-9-]+): \{.*sha256: ([a-f0-9]{64}) \}$", open(manifest).read(), re.M)
text = open(values).read()
m = re.search(r"^( *)# BEGIN rds-ca bundle hashes.*?\n(.*?)^ *# END rds-ca bundle hashes[^\n]*\n", text, re.M | re.S)
if not m:
    sys.exit(f"{values}: no '# BEGIN rds-ca bundle hashes' block")
ind = m.group(1)
block = [f"{ind}# BEGIN rds-ca bundle hashes (generated by scripts/selfhost/refresh-rds-ca-bundles.sh; do not edit)\n",
         f"{ind}bundleSha256:\n"]
block += [f'{ind}  {name}: "{digest}"\n' for name, digest in rows]
block.append(f"{ind}# END rds-ca bundle hashes\n")
open(values, "w").write(text[:m.start()] + "".join(block) + text[m.end():])
PY
verify
if [ ${#changed[@]} -eq 0 ]; then echo "rds-ca: no bundle changed"; else echo "rds-ca: refreshed ${changed[*]}; bump charts/agent-relay/Chart.yaml"; fi
