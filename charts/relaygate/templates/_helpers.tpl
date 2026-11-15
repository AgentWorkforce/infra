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

{{- define "relaygate.validate" -}}
{{- if not (regexMatch "^sha256:[a-f0-9]{64}$" (.Values.image.digest | default "")) }}
{{- fail "relaygate: image.digest is required (sha256:<64 hex>)" }}
{{- end }}
{{- if and (trim .Values.proxy.relaycastUrl) (or (not .Values.secrets.relaycastWorkspaceKey.name) (not .Values.secrets.relaygateSecret.name)) }}
{{- fail "relaygate: proxy.relaycastUrl needs secrets.relaycastWorkspaceKey.name and secrets.relaygateSecret.name" }}
{{- end }}
{{- if and (not (trim .Values.proxy.sessionsUrl)) (or (trim .Values.proxy.sessionsUploadUrl) (trim .Values.proxy.sessionsReadUrl) .Values.proxy.sessionsHosts) }}
{{- fail "relaygate: proxy.sessionsUploadUrl, sessionsReadUrl and sessionsHosts need proxy.sessionsUrl" }}
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
{{- range .Values.proxy.sessionsCorsOrigins }}{{ if not (regexMatch "^https?://[^/?#*]+$" (toString .)) }}{{ fail (printf "relaygate: proxy.sessionsCorsOrigins entries must be exact origins (scheme and host, no path or wildcard): %s" .) }}{{ end }}{{ end }}
{{- if and .Values.proxy.sessionsCorsOrigins (not (trim .Values.proxy.sessionsUrl)) }}{{ fail "relaygate: proxy.sessionsCorsOrigins needs proxy.sessionsUrl" }}{{ end }}
{{- with .Values.controlPrincipals }}
{{- if and (or (trim .introspectUrl) (trim .ingestAudience)) (or (not (trim .introspectUrl)) (not (trim .ingestAudience)) (not $.Values.secrets.relaycontrolIntrospectSecret.name)) }}
{{- fail "relaygate: controlPrincipals.introspectUrl, controlPrincipals.ingestAudience and secrets.relaycontrolIntrospectSecret.name are set together" }}
{{- end }}
{{- with trim .introspectUrl }}{{ if not (regexMatch "^https?://[^/?#]+/internal/v1/auth/introspect$" .) }}{{ fail "relaygate: controlPrincipals.introspectUrl must be Control's in-cluster origin plus /internal/v1/auth/introspect" }}{{ end }}{{ end }}
{{- with trim .ingestAudience }}{{ if not (regexMatch "^https://[^/?#]+$" .) }}{{ fail "relaygate: controlPrincipals.ingestAudience must be the bare https ingest origin" }}{{ end }}{{ end }}
{{- end }}
{{- if include "relaygate.gateOnly" . }}
{{- /* Gate-only: Relaycast and Sessions admit only relaygate, so a proxy left
off would cut clients off instead of gating them. */ -}}
{{- $g := .Values.global.relaygate.gateOnly -}}
{{- if or (not (trim .Values.proxy.relaycastUrl)) (not (trim .Values.proxy.sessionsUrl)) (not (trim .Values.proxy.sessionsUploadUrl)) (not (trim .Values.proxy.sessionsReadUrl)) (not .Values.proxy.sessionsHosts) }}
{{- fail "relaygate: global.relaygate.gateOnly.enabled needs proxy.relaycastUrl, proxy.sessionsUrl, proxy.sessionsUploadUrl, proxy.sessionsReadUrl (the in-cluster Services) and proxy.sessionsHosts (the history host)" }}
{{- end }}
{{- if or (not (trim .Values.controlPrincipals.introspectUrl)) (not (trim .Values.controlPrincipals.ingestAudience)) }}
{{- fail "relaygate: global.relaygate.gateOnly.enabled needs controlPrincipals.introspectUrl, controlPrincipals.ingestAudience and secrets.relaycontrolIntrospectSecret (dashboard and desktop callers reach Sessions through relaygate)" }}
{{- end }}
{{- $want := dig "serviceName" "" $g | default (include "relaygate.gateOnly.defaultName" .) -}}
{{- if ne $want (include "relaygate.fullname" .) }}
{{- fail (printf "relaygate: the Service is %s but global.relaygate.gateOnly.serviceName resolves to %s; set global.relaygate.gateOnly.serviceName to the Service name" (include "relaygate.fullname" .) $want) }}
{{- end }}
{{- if ne (int (dig "servicePort" 8080 $g)) (int .Values.service.port) }}
{{- fail "relaygate: global.relaygate.gateOnly.servicePort must equal service.port" }}
{{- end }}
{{- if .Values.nameOverride }}{{ fail "relaygate: nameOverride is unsupported with gate-only: the NetworkPolicies select app.kubernetes.io/name=relaygate" }}{{ end }}
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

{{- /* The gate's Service name every chart derives when global.relaygate.gateOnly.serviceName is empty. */ -}}
{{- define "relaygate.gateOnly.defaultName" -}}
{{- ternary .Release.Name (printf "%s-relaygate" .Release.Name) (contains "relaygate" .Release.Name) | trunc 63 | trimSuffix "-" -}}
{{- end }}
