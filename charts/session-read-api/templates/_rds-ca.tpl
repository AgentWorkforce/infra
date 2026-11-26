{{- /* Chart-managed RDS CA: global.rdsCa, set in the agent-relay umbrella chart,
which renders the ConfigMap (key ca.crt) from the AWS bundle it ships.
GENERATED from ci/rds-ca/_rds-ca.tpl by ci/rds-ca/sync.sh: edit that file and
rerun the script; CI fails when a chart's copy differs.

session-read-api.rdsCa: "" while global.rdsCa.bundle is empty; otherwise JSON
{bundle, configMap, sha256}: the ConfigMap the umbrella renders and the sha256
of the bundle in it (global.rdsCa.bundleSha256, which the umbrella checks
against the bundle file when it renders the ConfigMap). */ -}}
{{- define "session-read-api.rdsCa" -}}
{{- $g := dig "rdsCa" dict (.Values.global | default dict) | default dict -}}
{{- $bundle := dig "bundle" "" $g | default "" | toString -}}
{{- if $bundle -}}
{{- $sha := dig "bundleSha256" $bundle "" $g | default "" | toString -}}
{{- if not (regexMatch "^[a-f0-9]{64}$" $sha) }}{{ fail (printf "session-read-api: global.rdsCa.bundle=%q is not an RDS CA bundle the agent-relay chart ships. Use the AWS region of the database (us-east-1) or global; global.rdsCa.bundleSha256 lists them. Without the agent-relay chart, leave global.rdsCa empty and name your own CA." $bundle) }}{{ end -}}
{{- $name := dig "configMapName" "rds-ca" $g | default "rds-ca" | toString -}}
{{- dict "bundle" $bundle "configMap" $name "sha256" $sha | toJson -}}
{{- end -}}
{{- end -}}

{{- /* session-read-api.rdsCa.apply: the CA fields the chart-managed RDS CA sets on one CA
block, as JSON; {} when it sets none.
  root:   the chart context
  ca:     the block (postgresCa, or a postgres TLS block)
  path:   its values path, for error messages
  fields: its field names: configMap, key, sha256, and optionally secret and enabled
The chart-managed CA applies when global.rdsCa.bundle is set and the block names
no CA source of its own, or names the chart-managed ConfigMap. A block that names
another ConfigMap or a Secret keeps it (a private CA, or a database that is not
RDS). A key other than ca.crt, or a hand-set hash that differs from the bundle's,
contradicts the chart-managed CA and fails the render; the all-zero placeholder
hash counts as unset. */ -}}
{{- define "session-read-api.rdsCa.apply" -}}
{{- $out := dict -}}
{{- $rds := include "session-read-api.rdsCa" .root -}}
{{- if $rds -}}
{{- $rds = fromJson $rds -}}
{{- $f := .fields -}}
{{- $ca := .ca | default dict -}}
{{- $cm := get $ca $f.configMap | default "" | toString -}}
{{- $secret := "" -}}
{{- if $f.secret }}{{ $secret = get $ca $f.secret | default "" | toString }}{{ end -}}
{{- if and (not $secret) (or (not $cm) (eq $cm $rds.configMap)) -}}
{{- $key := get $ca $f.key | default "ca.crt" | toString -}}
{{- if ne $key "ca.crt" }}{{ fail (printf "session-read-api: %s.%s=%q contradicts the chart-managed RDS CA (global.rdsCa.bundle=%s), whose ConfigMap %s holds ca.crt. Remove %s.%s, or name your own ConfigMap or Secret." .path $f.key $key $rds.bundle $rds.configMap .path $f.key) }}{{ end -}}
{{- $sha := get $ca $f.sha256 | default "" | toString -}}
{{- /* 64 zeros is the placeholder values-eks-rds-native.yaml ships, never a real hash. */ -}}
{{- if eq $sha (repeat 64 "0") }}{{ $sha = "" }}{{ end -}}
{{- if and $sha (ne $sha $rds.sha256) }}{{ fail (printf "session-read-api: %s.%s=%s does not match the chart-managed RDS CA (global.rdsCa.bundle=%s, sha256 %s). Remove the hand-set hash (the chart computes it), or name your own ConfigMap or Secret and keep your hash." .path $f.sha256 $sha $rds.bundle $rds.sha256) }}{{ end -}}
{{- $_ := set $out $f.configMap $rds.configMap -}}
{{- $_ = set $out $f.key "ca.crt" -}}
{{- $_ = set $out $f.sha256 $rds.sha256 -}}
{{- if $f.enabled }}{{ $_ = set $out $f.enabled true }}{{ end -}}
{{- end -}}
{{- end -}}
{{- toJson $out -}}
{{- end -}}
