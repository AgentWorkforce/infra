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
{{- if .Values.relaygate.url }}
{{- if not .Values.secrets.relaygateEnrollmentKey.name }}
{{- fail "slack-relay: relaygate.url needs secrets.relaygateEnrollmentKey.name (the group's enrollment key)" }}
{{- end }}
{{- if not .Values.secrets.agentIdentitySecret.name }}
{{- fail "slack-relay: relaygate.url needs secrets.agentIdentitySecret.name (agents recover their identity with it)" }}
{{- end }}
{{- else }}
{{- if not .Values.relaycast.baseUrl }}
{{- fail "slack-relay: relaycast.baseUrl is required" }}
{{- end }}
{{- if not .Values.secrets.relaycastWorkspaceKey.name }}
{{- fail "slack-relay: secrets.relaycastWorkspaceKey.name is required" }}
{{- end }}
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
{{- $envNames := dict }}
{{- range .Values.mcpServers }}
{{- if not (and .name .url .tokenUrl .clientId .clientSecret .clientSecret.name) }}
{{- fail "slack-relay: each mcpServers entry needs name, url, tokenUrl, clientId and clientSecret.name" }}
{{- end }}
{{- if not (regexMatch "^[a-z][a-z0-9-]{0,40}$" .name) }}
{{- fail (printf "slack-relay: mcpServers name %q must be lowercase letters, digits and hyphens" .name) }}
{{- end }}
{{- $env := printf "MCP_%s_CLIENT_SECRET" (.name | upper | replace "-" "_") }}
{{- if hasKey $envNames $env }}
{{- fail (printf "slack-relay: mcpServers names %q and %q map to the same %s" (get $envNames $env) .name $env) }}
{{- end }}
{{- $_ := set $envNames $env .name }}
{{- end }}
{{- if .Values.ingest.enabled }}
{{- $found := false }}
{{- range .Values.mcpServers }}{{- if eq .name $.Values.ingest.mcpServer }}{{- $found = true }}{{- end }}{{- end }}
{{- if not $found }}
{{- fail "slack-relay: ingest.mcpServer must name an entry in mcpServers" }}
{{- end }}
{{- end }}
{{- if and (eq .Values.slack.mode "http") (not .Values.ingress.enabled) }}
{{- fail "slack-relay: http mode needs ingress.enabled so Slack can reach /slack/events" }}
{{- end }}
{{- if not (has .Values.router.orchestrator (list "claude" "deterministic")) }}
{{- fail "slack-relay: router.orchestrator must be claude or deterministic" }}
{{- end }}
{{- end }}

{{/* OAuth MCP servers: the JSON list (no secrets) plus one secret env per server. */}}
{{- define "slack-relay.mcpEnv" -}}
{{- if .Values.mcpServers }}
{{- $list := list }}
{{- range .Values.mcpServers }}
{{- $env := printf "MCP_%s_CLIENT_SECRET" (.name | upper | replace "-" "_") }}
{{- $list = append $list (dict "name" .name "url" .url "tokenUrl" .tokenUrl "scope" (.scope | default "") "clientId" .clientId "clientSecretEnv" $env) }}
{{- end }}
- name: MCP_OAUTH_SERVERS_JSON
  value: {{ $list | toJson | quote }}
{{- range .Values.mcpServers }}
{{ include "slack-relay.secretEnv" (dict "env" (printf "MCP_%s_CLIENT_SECRET" (.name | upper | replace "-" "_")) "ref" .clientSecret) }}
{{- end }}
{{- end }}
{{- end }}

{{/* Env both roles share. */}}
{{- define "slack-relay.commonEnv" -}}
{{- if .Values.relaygate.url }}
- name: RELAYGATE_URL
  value: {{ .Values.relaygate.url | quote }}
{{- else }}
- name: RELAYCAST_BASE_URL
  value: {{ .Values.relaycast.baseUrl | quote }}
{{- end }}
- name: RELAY_CHANNEL
  value: {{ .Values.relaycast.channel | quote }}
- name: ROUTER_AGENT_NAME
  value: {{ .Values.router.agentName | quote }}
{{- if .Values.relaygate.url }}
{{ include "slack-relay.secretEnv" (dict "env" "RELAYGATE_ENROLLMENT_KEY" "ref" .Values.secrets.relaygateEnrollmentKey) }}
{{- else }}
{{ include "slack-relay.secretEnv" (dict "env" "RELAYCAST_WORKSPACE_KEY" "ref" .Values.secrets.relaycastWorkspaceKey) }}
{{- end }}
{{- if .Values.secrets.agentIdentitySecret.name }}
{{ include "slack-relay.secretEnv" (dict "env" "AGENT_IDENTITY_SECRET" "ref" .Values.secrets.agentIdentitySecret) }}
{{- end }}
{{- end }}
