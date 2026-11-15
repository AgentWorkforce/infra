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
