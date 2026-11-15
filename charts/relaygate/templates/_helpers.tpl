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
{{- if and (trim .Values.proxy.sessionsUrl) (not .Values.secrets.sessionsToken.name) }}
{{- fail "relaygate: proxy.sessionsUrl needs secrets.sessionsToken.name" }}
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
