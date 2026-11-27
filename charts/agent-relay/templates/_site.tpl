{{- /*
Site values (top-level `site:`) and the aggregated values check.

templates/site/runs-before-subcharts/1/2/3/4/5/site.yaml includes
"agent-relay.site.run" once. That file is the deepest template path in the
chart, and Helm renders templates deepest path first (engine sortTemplates),
so it runs before every subchart template. It:

1. fills each subchart value that site derives (domain, hosts, region,
   sessionsBucket, opensearchUrl, orgId, orgName, adminEmail) when the value
   is empty or still the chart/profile default, by setting it in .Values.
   A subchart's .Values is the same map as the umbrella's .Values.<subchart>,
   so the subcharts render with the filled values. Globals are copied per
   chart, so global.tenant.orgId is set in every chart's copy.
2. collects every problem it can see (site values, a per-component value
   that contradicts site, and the subchart checks mirrored here) and fails
   once with the whole list.

ci/agent-relay/test_site_values.py keeps both properties honest: it fails
when any template in the built chart is as deep as site.yaml, and when an
aggregated failure does not come out before a subchart's own.
*/ -}}

{{- /* agent-relay.site.get: {"found": bool, "v": value} at .path (a list of
keys) under .root. */ -}}
{{- define "agent-relay.site.get" -}}
{{- $node := .root -}}
{{- $found := true -}}
{{- range $k := .path -}}
{{- if and $found (kindIs "map" $node) (hasKey $node $k) -}}
{{- $node = index $node $k -}}
{{- else -}}
{{- $found = false -}}
{{- end -}}
{{- end -}}
{{- toJson (dict "found" $found "v" (ternary $node nil $found)) -}}
{{- end -}}

{{- /* agent-relay.site.put: sets .value at .path under .root, creating maps. */ -}}
{{- define "agent-relay.site.put" -}}
{{- $node := .root -}}
{{- range $k := initial .path -}}
{{- if not (kindIs "map" (index $node $k)) }}{{ $_ := set $node $k (dict) }}{{ end -}}
{{- $node = index $node $k -}}
{{- end -}}
{{- $_ := set $node (last .path) .value -}}
{{- end -}}

{{- /* agent-relay.site.same: "true" when .a and .b are the same value, ignoring
one trailing slash on strings (https://x/ and https://x name one origin). */ -}}
{{- define "agent-relay.site.same" -}}
{{- if and (kindIs "string" .a) (kindIs "string" .b) -}}
{{- if eq (trimSuffix "/" .a) (trimSuffix "/" .b) }}true{{ end -}}
{{- else if eq (toJson .a) (toJson .b) }}true{{ end -}}
{{- end -}}

{{- /* agent-relay.site.problem: appends one problem to .st.problems.
.where (the value's path), .value (its current value, or nil), .why, .fix.
.mirror: a mirrored subchart check, skipped when .value came from a site value
already reported (.st.bad). */ -}}
{{- define "agent-relay.site.problem" -}}
{{- if not (and .mirror (has (toString .value) (.st.bad | default (list)))) -}}
{{- $_ := set .st "problems" (append .st.problems (dict "where" .where "value" .value "why" .why "fix" .fix)) -}}
{{- end -}}
{{- end -}}

{{- /* agent-relay.site.unset: "true" when the value at .path under .root
counts as not set: missing or empty, one of .defaults (a subchart default such
as us-east-1), or what a values-*.yaml profile the chart ships has at the same
path (values-eks.yaml's placeholder.company hosts, example bucket and region).
With .pair (the path of the bucket or URL a region belongs to), a profile value
counts only while the pair is unset too: us-west-2 is a placeholder next to the
example bucket, and a real region next to a real one. */ -}}
{{- define "agent-relay.site.unset" -}}
{{- $got := include "agent-relay.site.get" (dict "root" .root "path" .path) | fromJson -}}
{{- $cur := $got.v -}}
{{- $unset := or (not $got.found) (empty $cur) -}}
{{- if not $unset -}}
{{- range $d := (.defaults | default (list)) }}{{ if include "agent-relay.site.same" (dict "a" $cur "b" $d) }}{{ $unset = true }}{{ end }}{{ end -}}
{{- end -}}
{{- if not $unset -}}
{{- $profile := false -}}
{{- range $p := .st.profiles -}}
{{- $v := include "agent-relay.site.get" (dict "root" $p "path" $.path) | fromJson -}}
{{- if and $v.found (not (empty $v.v)) (include "agent-relay.site.same" (dict "a" $cur "b" $v.v)) }}{{ $profile = true }}{{ end -}}
{{- end -}}
{{- if and $profile .pair -}}
{{- $profile = include "agent-relay.site.unset" (dict "st" .st "root" .root "path" .pair) -}}
{{- end -}}
{{- $unset = $profile -}}
{{- end -}}
{{- if $unset }}true{{ end -}}
{{- end -}}

{{- /* agent-relay.site.derive: one derived value.
  .st     state: problems, profiles (the chart's values-*.yaml, parsed)
  .root   .Values
  .path   list of keys under .root
  .value  the site-derived value (skipped when empty)
  .from   the site key it comes from, for messages (site.domain, ...)
  .must   true: the value must equal the site value (an explicit value that
          differs is a contradiction); false: an explicit value wins
  .defaults, .pair  see agent-relay.site.unset
  .clear  instead of .value: empty a profile placeholder (single-host mode)
An unset value gets the site value. */ -}}
{{- define "agent-relay.site.derive" -}}
{{- if .clear -}}
{{- /* .clear: a profile placeholder here is emptied (an explicit value stays). */ -}}
{{- $got := include "agent-relay.site.get" (dict "root" .root "path" .path) | fromJson -}}
{{- if and $got.found (not (empty $got.v)) (include "agent-relay.site.unset" .) -}}
{{- include "agent-relay.site.put" (dict "root" .root "path" .path "value" "") -}}
{{- end -}}
{{- else if .value -}}
{{- if include "agent-relay.site.unset" . -}}
{{- include "agent-relay.site.put" (dict "root" .root "path" .path "value" .value) -}}
{{- else -}}
{{- $cur := (include "agent-relay.site.get" (dict "root" .root "path" .path) | fromJson).v -}}
{{- if and .must (not (include "agent-relay.site.same" (dict "a" $cur "b" .value))) -}}
{{- include "agent-relay.site.problem" (dict "st" .st "where" (join "." .path) "value" $cur
  "why" (printf "contradicts %s, which sets it to %s" .from (toJson .value))
  "fix" (printf "delete %s (%s sets it), or change %s so the two agree" (join "." .path) .from .from)) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- /* agent-relay.site.setGlobal: sets global.<.path> = .value in .ctx's
values and in every subchart's copy below it. */ -}}
{{- define "agent-relay.site.setGlobal" -}}
{{- if not (kindIs "map" .ctx.Values.global) }}{{ $_ := set .ctx.Values "global" (dict) }}{{ end -}}
{{- include "agent-relay.site.put" (dict "root" .ctx.Values.global "path" .path "value" .value) -}}
{{- range $name, $sub := (.ctx.Subcharts | default dict) -}}
{{- include "agent-relay.site.setGlobal" (dict "ctx" $sub "path" $.path "value" $.value) -}}
{{- end -}}
{{- end -}}

{{- /* agent-relay.site.publicHost: "" when .host is a public DNS name the
History, Control and ingest charts accept, else why not. */ -}}
{{- define "agent-relay.site.publicHost" -}}
{{- $h := toString .host -}}
{{- if not (regexMatch "^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z]([a-z0-9-]{0,61}[a-z0-9])?$" $h) -}}
must be a lowercase DNS name with at least two labels (letters, digits and inner hyphens), with no scheme, port or path
{{- else if gt (len $h) 245 -}}
must be at most 245 characters (history.<domain> must fit in 253)
{{- else if regexMatch "\\.(localhost|local|internal|lan|invalid|test|example|home\\.arpa|onion)$" $h -}}
is a private or reserved name (.internal, .local, .lan, .test, .example, .localhost, .invalid, .home.arpa, .onion); the History origin, the ingest edge and Control's public URLs must be public DNS names that clients resolve, so use a name under a domain you own
{{- else if regexMatch "(^|\\.)(example\\.(com|net|org)|placeholder\\.company)$" $h -}}
is a documentation placeholder (example.com/.net/.org, placeholder.company); use your own domain
{{- end -}}
{{- end -}}

{{- /* agent-relay.site.message: the fail message for .problems. */ -}}
{{- define "agent-relay.site.message" -}}
{{- $n := len .problems -}}
agent-relay: {{ $n }} values {{ ternary "problem" "problems" (eq $n 1) }}. Nothing was installed. Fix {{ ternary "it" "all of them" (eq $n 1) }}, then run helm again
(scripts/selfhost/check-values.sh lists them without a cluster):
{{- range $i, $p := .problems }}

{{ add1 $i }}. {{ $p.where }}{{ if not (kindIs "invalid" $p.value) }} = {{ toJson $p.value }}{{ end }}
   {{ $p.why }}
   fix: {{ $p.fix }}
{{- end }}
{{- end -}}
