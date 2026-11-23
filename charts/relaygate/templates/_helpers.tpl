{{- define "relaygate.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "relaygate.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "relaygate.selectorLabels" -}}
app.kubernetes.io/name: {{ include "relaygate.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "relaygate.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{ include "relaygate.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "relaygate.gateOnly" -}}
{{- if dig "relaygate" "gateOnly" "enabled" false (.Values.global | default dict) }}true{{ end -}}
{{- end }}

{{- /* The gate's Service name every chart derives when global.relaygate.gateOnly.serviceName is empty. */ -}}
{{- define "relaygate.gateOnly.defaultName" -}}
{{- ternary .Release.Name (printf "%s-relaygate" .Release.Name) (contains "relaygate" .Release.Name) | trunc 63 | trimSuffix "-" -}}
{{- end }}

{{- /* Gate-only: the internal Sessions listener (relaygate SESSIONS_PORT,
relaygate #28 or later) serves Sessions at its root with relay-control's
internal mint allowed. relay-control's SESSION_READ_API_URL must be an origin
without a path, so Control uses http://<this>.<ns>.svc.cluster.local:<port>
(relay-control.sessionReadApiUrl derives the same name and port from
global.relaygate.gateOnly). Never on an Ingress or NEG. */ -}}
{{- define "relaygate.sessionsServiceName" -}}
{{- printf "%s-sessions" (include "relaygate.fullname" . | trunc 54 | trimSuffix "-") -}}
{{- end }}

{{- define "relaygate.sessionsPort" -}}
{{- dig "relaygate" "gateOnly" "sessionsPort" 0 (.Values.global | default dict) | int -}}
{{- end }}

{{- /* Control-owned policy (global.relaygate.controlPolicy, agent-relay umbrella).
enabled: relay-control manages the policy (it gets relaygate's admin URL and
token and the policy secret); relaygate still reads its file, so the operator
can import it into Control. pull: relaygate then pulls it from relay-control
and the file and ConfigMap go away. */ -}}
{{- define "relaygate.controlPolicy" -}}
{{- dig "relaygate" "controlPolicy" dict (.Values.global | default dict) | default dict | toJson -}}
{{- end }}

{{- define "relaygate.controlPolicy.pull" -}}
{{- $cp := include "relaygate.controlPolicy" . | fromJson -}}
{{- if and (dig "enabled" false $cp) (dig "pull" false $cp) }}true{{ end -}}
{{- end }}

{{- /* relay-control's in-cluster policy route (relaygate docs/design/control-owned-policy.md). */ -}}
{{- define "relaygate.controlPolicy.url" -}}
{{- $cp := include "relaygate.controlPolicy" . | fromJson -}}
{{- $svc := dig "controlServiceName" "" $cp | default (printf "%s-relay-control" .Release.Name | trunc 63 | trimSuffix "-") -}}
{{- printf "http://%s.%s.svc.cluster.local:%d/internal/v1/relaygate/policy" $svc .Release.Namespace (int (dig "controlServicePort" 80 $cp)) -}}
{{- end }}

{{- /* RELAYGATE_ADMIN_TOKEN: the shared controlPolicy.adminToken when enabled
(relay-control uses the same Secret), else secrets.adminToken. */ -}}
{{- define "relaygate.adminToken" -}}
{{- $cp := include "relaygate.controlPolicy" . | fromJson -}}
{{- if dig "enabled" false $cp -}}
{{- dig "adminToken" dict $cp | toJson -}}
{{- else if .Values.secrets.adminToken.name -}}
{{- .Values.secrets.adminToken | toJson -}}
{{- else -}}
{{- "{}" -}}
{{- end -}}
{{- end }}

{{- /* Upstream verification (global.relaygate.upstreamAuth): relaygate signs
proxied Sessions requests. "enabled" without a current key fails the render. */ -}}
{{- define "relaygate.upstreamAuth" -}}
{{- dig "relaygate" "upstreamAuth" dict (.Values.global | default dict) | default dict | toJson -}}
{{- end }}

{{- /* A kid as a string: an unquoted number (YAML 1000000) would otherwise print as 1e+06. */ -}}
{{- define "relaygate.kid" -}}
{{- if or (kindIs "float64" .) (kindIs "int" .) (kindIs "int64" .) }}{{ printf "%.0f" (float64 .) }}{{ else }}{{ toString (. | default "") }}{{ end -}}
{{- end }}

{{- define "relaygate.validateUpstreamAuth" -}}
{{- $ua := include "relaygate.upstreamAuth" . | fromJson -}}
{{- $on := dig "enabled" false $ua -}}
{{- if not (kindIs "bool" $on) }}{{ fail "relaygate: global.relaygate.upstreamAuth.enabled must be true or false" }}{{ end -}}
{{- if $on }}
{{- if or (not (dig "privateKey" "name" "" $ua)) (not (dig "privateKey" "key" "" $ua)) }}{{ fail "relaygate: global.relaygate.upstreamAuth.enabled needs upstreamAuth.privateKey.name and privateKey.key (the Secret holding the Ed25519 private key, canonical base64 PKCS#8 DER)" }}{{ end -}}
{{- if not (regexMatch "^[A-Za-z0-9._-]{1,64}$" (include "relaygate.kid" (dig "kid" "" $ua))) }}{{ fail "relaygate: global.relaygate.upstreamAuth.kid is required: the signing key's id, 1-64 of A-Z a-z 0-9 . _ -" }}{{ end -}}
{{- $ttl := dig "ttlSeconds" 30 $ua -}}
{{- if or (not (or (kindIs "int" $ttl) (kindIs "int64" $ttl) (kindIs "float64" $ttl))) (ne (float64 $ttl) (float64 (int $ttl))) (lt (int $ttl) 5) (gt (int $ttl) 60) }}{{ fail "relaygate: global.relaygate.upstreamAuth.ttlSeconds must be a whole number of seconds from 5 to 60" }}{{ end -}}
{{- if not (trim .Values.proxy.sessionsUrl) }}{{ fail "relaygate: global.relaygate.upstreamAuth.enabled signs proxied Sessions requests; it needs proxy.sessionsUrl (the Sessions proxy)" }}{{ end -}}
{{- end }}
{{- end }}

{{- define "relaygate.validate" -}}
{{- include "relaygate.validateUpstreamAuth" . -}}
{{- $cp := include "relaygate.controlPolicy" . | fromJson -}}
{{- if dig "enabled" false $cp }}
{{- if not (include "relaygate.gateOnly" .) }}{{ fail "relaygate: global.relaygate.controlPolicy.enabled needs global.relaygate.gateOnly.enabled (relay-control manages the policy only on gate-only installs)" }}{{ end }}
{{- if or (not (dig "adminToken" "name" "" $cp)) (not (dig "adminToken" "key" "" $cp)) (not (dig "policySecret" "name" "" $cp)) (not (dig "policySecret" "key" "" $cp)) }}{{ fail "relaygate: global.relaygate.controlPolicy.enabled needs controlPolicy.adminToken and controlPolicy.policySecret ({name, key}): relaygate and relay-control share both" }}{{ end }}
{{- if and .Values.secrets.adminToken.name (or (ne .Values.secrets.adminToken.name $cp.adminToken.name) (ne .Values.secrets.adminToken.key $cp.adminToken.key)) }}{{ fail "relaygate: with global.relaygate.controlPolicy.enabled, RELAYGATE_ADMIN_TOKEN comes from controlPolicy.adminToken; leave secrets.adminToken empty or set it to the same Secret" }}{{ end }}
{{- if and (dig "policySecret" "name" "" $cp) (eq (dig "policySecret" "name" "" $cp) .Values.secrets.relaycontrolIntrospectSecret.name) (eq (dig "policySecret" "key" "" $cp) .Values.secrets.relaycontrolIntrospectSecret.key) }}{{ fail "relaygate: controlPolicy.policySecret must be a different secret from the introspection secret" }}{{ end }}
{{- else if dig "pull" false $cp }}
{{- fail "relaygate: global.relaygate.controlPolicy.pull needs controlPolicy.enabled" }}
{{- end }}
{{- if and (include "relaygate.controlPolicy.pull" .) .Values.existingConfigMap }}{{ fail "relaygate: global.relaygate.controlPolicy.pull pulls the policy from relay-control; existingConfigMap would be ignored, so leave it empty" }}{{ end }}
{{- if include "relaygate.gateOnly" . }}
{{- /* Gate-only (global.relaygate.gateOnly.enabled, agent-relay umbrella):
Relaycast and Sessions admit only relaygate, so a proxy or the Control
mapping left off would cut clients off instead of gating them. */ -}}
{{- $g := .Values.global.relaygate.gateOnly -}}
{{- $scope := dig "scope" "all" $g | default "all" | toString -}}
{{- if not (has $scope (list "all" "sessions")) }}{{ fail (printf "relaygate: global.relaygate.gateOnly.scope must be all or sessions, got %q" $scope) }}{{ end -}}
{{- if and (eq $scope "all") (not (trim .Values.proxy.relaycastUrl)) }}
{{- fail "relaygate: global.relaygate.gateOnly.enabled needs proxy.relaycastUrl, proxy.sessionsUrl, proxy.sessionsUploadUrl, proxy.sessionsReadUrl (the in-cluster Services) and proxy.sessionsHosts (the history host)" }}
{{- end }}
{{- if or (not (trim .Values.proxy.sessionsUrl)) (not (trim .Values.proxy.sessionsUploadUrl)) (not (trim .Values.proxy.sessionsReadUrl)) (not .Values.proxy.sessionsHosts) }}
{{- fail (printf "relaygate: global.relaygate.gateOnly.enabled needs %sproxy.sessionsUrl, proxy.sessionsUploadUrl, proxy.sessionsReadUrl (the in-cluster Services) and proxy.sessionsHosts (the history host)" (ternary "proxy.relaycastUrl, " "" (eq $scope "all"))) }}
{{- end }}
{{- if not (trim .Values.control.introspectUrl) }}
{{- fail "relaygate: global.relaygate.gateOnly.enabled needs control.introspectUrl, control.sessionIngestAudience and secrets.relaycontrolIntrospectSecret (dashboard and desktop callers reach Sessions through relaygate)" }}
{{- end }}
{{- $want := dig "serviceName" "" $g | default (include "relaygate.gateOnly.defaultName" .) -}}
{{- if ne $want (include "relaygate.fullname" .) }}
{{- fail (printf "relaygate: the Service is %s but global.relaygate.gateOnly.serviceName resolves to %s; set global.relaygate.gateOnly.serviceName to the Service name" (include "relaygate.fullname" .) $want) }}
{{- end }}
{{- if ne (int (dig "servicePort" 8080 $g)) (int .Values.service.port) }}
{{- fail "relaygate: global.relaygate.gateOnly.servicePort must equal service.port" }}
{{- end }}
{{- $sp := int (include "relaygate.sessionsPort" .) -}}
{{- /* The main listener always binds 8080 (PORT); service.port only remaps the Service. */ -}}
{{- if or (lt $sp 1) (gt $sp 65535) (eq $sp 8080) }}
{{- fail "relaygate: global.relaygate.gateOnly.enabled needs global.relaygate.gateOnly.sessionsPort (relaygate SESSIONS_PORT, e.g. 8081, not 8080, the main listener): relay-control reaches Sessions there at the root" }}
{{- end }}
{{- $peers := .Values.sessionsListener.controlFrom -}}
{{- if or (not (kindIs "slice" $peers)) (empty $peers) }}
{{- fail "relaygate: gate-only needs sessionsListener.controlFrom (the relay-control pods): an empty peer list would admit every source to the internal Sessions listener" }}
{{- end }}
{{- /* Every peer must select pods by label: no ipBlock, and no bare (or empty)
namespaceSelector, which would admit every pod in the selected namespaces. */ -}}
{{- range $peers }}
{{- if or (not (kindIs "map" .)) (empty .) }}{{ fail "relaygate: sessionsListener.controlFrom entries must be NetworkPolicy peers with selectors; an empty peer admits every source" }}{{ end -}}
{{- if hasKey . "ipBlock" }}{{ fail "relaygate: sessionsListener.controlFrom must select the relay-control pods by label, never an ipBlock" }}{{ end -}}
{{- if and (empty (dig "podSelector" "matchLabels" dict .)) (empty (dig "podSelector" "matchExpressions" list .)) }}{{ fail "relaygate: sessionsListener.controlFrom podSelector entries must name the relay-control pods by label (a namespaceSelector alone admits every pod it selects)" }}{{ end -}}
{{- end }}
{{- if .Values.nameOverride }}{{ fail "relaygate: nameOverride is unsupported with gate-only: the NetworkPolicies select app.kubernetes.io/name=relaygate" }}{{ end }}
{{- end }}
{{- if not (regexMatch "^sha256:[a-f0-9]{64}$" (.Values.image.digest | default "")) }}
{{- fail "relaygate: image.digest is required (sha256:<64 hex>)" }}
{{- end }}
{{- if and (trim .Values.proxy.relaycastUrl) (or (not .Values.secrets.relaycastWorkspaceKey.name) (not .Values.secrets.relaygateSecret.name)) }}
{{- fail "relaygate: proxy.relaycastUrl needs secrets.relaycastWorkspaceKey.name and secrets.relaygateSecret.name" }}
{{- end }}
{{- if and (not (trim .Values.proxy.sessionsUrl)) (or (trim .Values.proxy.sessionsUploadUrl) (trim .Values.proxy.sessionsReadUrl) .Values.proxy.sessionsHosts) }}
{{- fail "relaygate: proxy.sessionsUploadUrl, sessionsReadUrl and sessionsHosts need proxy.sessionsUrl" }}
{{- end }}
{{- if and (not (trim .Values.proxy.sessionsUrl)) (or .Values.proxy.sessionsCorsOrigins .Values.secrets.sessionsInternalSecret.name) }}
{{- fail "relaygate: proxy.sessionsCorsOrigins and secrets.sessionsInternalSecret need proxy.sessionsUrl" }}
{{- end }}
{{- if and (not (trim .Values.control.introspectUrl)) (or (trim .Values.control.sessionIngestAudience) .Values.secrets.relaycontrolIntrospectSecret.name) }}
{{- fail "relaygate: control.sessionIngestAudience and secrets.relaycontrolIntrospectSecret need control.introspectUrl" }}
{{- end }}
{{- if and (trim .Values.control.introspectUrl) (or (not (trim .Values.control.sessionIngestAudience)) (not .Values.secrets.relaycontrolIntrospectSecret.name)) }}
{{- fail "relaygate: control.introspectUrl needs control.sessionIngestAudience and secrets.relaycontrolIntrospectSecret.name" }}
{{- end }}
{{- with .Values.proxy.sessionsHosts }}
{{- if or (not (trim $.Values.proxy.sessionsUploadUrl)) (not (trim $.Values.proxy.sessionsReadUrl)) }}
{{- fail "relaygate: proxy.sessionsHosts needs proxy.sessionsUploadUrl and proxy.sessionsReadUrl (the upstream Services, not the history origin that now points at relaygate)" }}
{{- end }}
{{- range $u := list $.Values.proxy.sessionsUploadUrl $.Values.proxy.sessionsReadUrl }}
{{- $h := first (splitList ":" (urlParse (trim $u)).host) | lower }}
{{- range $.Values.proxy.sessionsHosts }}
{{- if eq (lower .) $h }}
{{- fail (printf "relaygate: proxy.sessionsHosts lists %s, which is also an upstream (%s); requests would loop back to relaygate" . $u) }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}
{{- /* The inline policy is checked only when relaygate reads it (not with
existingConfigMap, nor when it pulls its policy from relay-control). */ -}}
{{- if and (not .Values.existingConfigMap) (not (include "relaygate.controlPolicy.pull" .)) }}
{{- range .Values.policy.enrollmentKeys }}
{{- if not (regexMatch "^[a-f0-9]{64}$" (.sha256 | default "")) }}
{{- fail (printf "relaygate: enrollmentKeys[%s].sha256 must be the 64-hex sha256 of the key, never the key itself" (.id | default "?")) }}
{{- end }}
{{- end }}
{{- if and .Values.policy.classifier.model.enabled (not .Values.secrets.anthropicApiKey.name) }}
{{- fail "relaygate: policy.classifier.model.enabled needs secrets.anthropicApiKey.name" }}
{{- end }}
{{- end }}
{{- end }}
