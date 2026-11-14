{{- define "slack-relay.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "slack-relay.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 50 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 50 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 50 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "slack-relay.selectorLabels" -}}
app.kubernetes.io/name: {{ include "slack-relay.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "slack-relay.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{ include "slack-relay.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "slack-relay.image" -}}
{{- printf "%s@%s" .Values.image.repository .Values.image.digest }}
{{- end }}

{{/* env var from an existing Secret: (dict "env" NAME "ref" .Values.secrets.x) */}}
{{- define "slack-relay.secretEnv" -}}
- name: {{ .env }}
  valueFrom:
    secretKeyRef:
      name: {{ .ref.name }}
      key: {{ .ref.key }}
{{- end }}

{{/* Fail closed on what the runtime cannot default. */}}
{{- define "slack-relay.validate" -}}
{{- if not (regexMatch "^sha256:[a-f0-9]{64}$" (.Values.image.digest | default "")) }}
{{- fail "slack-relay: image.digest is required (sha256:<64 hex>)" }}
{{- end }}
{{- if not .Values.relaycast.baseUrl }}
{{- fail "slack-relay: relaycast.baseUrl is required" }}
{{- end }}
{{- if not .Values.secrets.relaycastWorkspaceKey.name }}
{{- fail "slack-relay: secrets.relaycastWorkspaceKey.name is required" }}
{{- end }}
{{- if not .Values.secrets.slackBotToken.name }}
{{- fail "slack-relay: secrets.slackBotToken.name is required" }}
{{- end }}
{{- if not .Values.secrets.anthropicApiKey.name }}
{{- fail "slack-relay: secrets.anthropicApiKey.name is required (the agent host runs Claude Code)" }}
{{- end }}
{{- if not (has .Values.slack.mode (list "socket" "http")) }}
{{- fail "slack-relay: slack.mode must be socket or http" }}
{{- end }}
{{- if and (eq .Values.slack.mode "socket") (not .Values.secrets.slackAppToken.name) }}
{{- fail "slack-relay: secrets.slackAppToken.name is required in socket mode" }}
{{- end }}
{{- if and (eq .Values.slack.mode "http") (not .Values.secrets.slackSigningSecret.name) }}
{{- fail "slack-relay: secrets.slackSigningSecret.name is required in http mode" }}
{{- end }}
{{- if and (eq .Values.slack.mode "http") (not .Values.ingress.enabled) }}
{{- fail "slack-relay: http mode needs ingress.enabled so Slack can reach /slack/events" }}
{{- end }}
{{- if not (has .Values.router.orchestrator (list "claude" "deterministic")) }}
{{- fail "slack-relay: router.orchestrator must be claude or deterministic" }}
{{- end }}
{{- end }}

{{/* Env both roles share. */}}
{{- define "slack-relay.commonEnv" -}}
- name: RELAYCAST_BASE_URL
  value: {{ .Values.relaycast.baseUrl | quote }}
- name: RELAY_CHANNEL
  value: {{ .Values.relaycast.channel | quote }}
- name: ROUTER_AGENT_NAME
  value: {{ .Values.router.agentName | quote }}
{{ include "slack-relay.secretEnv" (dict "env" "RELAYCAST_WORKSPACE_KEY" "ref" .Values.secrets.relaycastWorkspaceKey) }}
{{- if .Values.secrets.agentIdentitySecret.name }}
{{ include "slack-relay.secretEnv" (dict "env" "AGENT_IDENTITY_SECRET" "ref" .Values.secrets.agentIdentitySecret) }}
{{- end }}
{{- end }}
