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

{{- define "relaygate.validate" -}}
{{- if include "relaygate.gateOnly" . }}
{{- /* Gate-only (global.relaygate.gateOnly.enabled, agent-relay umbrella):
Relaycast and Sessions admit only relaygate, so a proxy or the Control
mapping left off would cut clients off instead of gating them. */ -}}
{{- $g := .Values.global.relaygate.gateOnly -}}
{{- if or (not (trim .Values.proxy.relaycastUrl)) (not (trim .Values.proxy.sessionsUrl)) (not (trim .Values.proxy.sessionsUploadUrl)) (not (trim .Values.proxy.sessionsReadUrl)) (not .Values.proxy.sessionsHosts) }}
{{- fail "relaygate: global.relaygate.gateOnly.enabled needs proxy.relaycastUrl, proxy.sessionsUrl, proxy.sessionsUploadUrl, proxy.sessionsReadUrl (the in-cluster Services) and proxy.sessionsHosts (the history host)" }}
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
{{- if or (lt $sp 1) (gt $sp 65535) (eq $sp (int .Values.service.port)) }}
{{- fail "relaygate: global.relaygate.gateOnly.enabled needs global.relaygate.gateOnly.sessionsPort (relaygate SESSIONS_PORT, e.g. 8081, not service.port): relay-control reaches Sessions there at the root" }}
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
{{- if and (not (trim .Values.proxy.sessionsUrl)) (or .Values.proxy.sessionsCorsOrigins (trim .Values.control.introspectUrl) .Values.secrets.sessionsInternalSecret.name) }}
{{- fail "relaygate: proxy.sessionsCorsOrigins, control.introspectUrl and secrets.sessionsInternalSecret need proxy.sessionsUrl" }}
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
{{- if not .Values.existingConfigMap }}
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
