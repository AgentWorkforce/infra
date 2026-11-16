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
{{- if (.Values.relaygate.url | default "" | trim) }}
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
{{- if .Values.sessions.upload.enabled }}
{{- if not (.Values.relaygate.url | default "" | trim) }}
{{- fail "slack-relay: sessions.upload.enabled needs relaygate.url (sessions are uploaded as each agent through the gate)" }}
{{- end }}
{{- if or (not .Values.sessions.upload.orgId) (not .Values.sessions.upload.workspaceId) }}
{{- fail "slack-relay: sessions.upload.enabled needs sessions.upload.orgId and sessions.upload.workspaceId" }}
{{- end }}
{{- if and .Values.sessions.upload.relayControlUrl (not .Values.secrets.sessionsEnrollmentKey.name) }}
{{- fail "slack-relay: sessions.upload.relayControlUrl needs secrets.sessionsEnrollmentKey.name (a Desktop enrollment key)" }}
{{- end }}
{{- end }}
{{- if .Values.sessions.mcp.enabled }}
{{- if not (.Values.relaygate.url | default "" | trim) }}
{{- fail "slack-relay: sessions.mcp.enabled needs relaygate.url (agents read sessions as themselves through the gate)" }}
{{- end }}
{{- if or (not .Values.sessions.upload.orgId) (not .Values.sessions.upload.workspaceId) (not .Values.sessions.upload.relayControlUrl) (not .Values.secrets.sessionsEnrollmentKey.name) }}
{{- fail "slack-relay: sessions.mcp.enabled needs sessions.upload.orgId, workspaceId, relayControlUrl and secrets.sessionsEnrollmentKey.name (read credentials are minted as the uploader user)" }}
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
{{- range $source, $server := .Values.ingest.sourceServers }}
{{- $ok := false }}
{{- range $.Values.mcpServers }}{{- if eq .name $server }}{{- $ok = true }}{{- end }}{{- end }}
{{- if not $ok }}
{{- fail (printf "slack-relay: ingest.sourceServers.%s (%s) must name an entry in mcpServers" $source $server) }}
{{- end }}
{{- end }}
{{- end }}
{{- if and (eq .Values.slack.mode "http") (not .Values.ingress.enabled) }}
{{- fail "slack-relay: http mode needs ingress.enabled so Slack can reach /slack/events" }}
{{- end }}
{{- if not (has .Values.router.orchestrator (list "claude" "deterministic")) }}
{{- fail "slack-relay: router.orchestrator must be claude or deterministic" }}
{{- end }}
{{- if .Values.repos.enabled }}
{{- $app := .Values.repos.app | default dict }}
{{- $appKey := ($app.privateKey | default dict).name }}
{{- if and $appKey .Values.repos.token.name }}
{{- fail "slack-relay: set one of repos.app.privateKey.name and repos.token.name, not both" }}
{{- end }}
{{- if not (or $appKey .Values.repos.token.name) }}
{{- fail "slack-relay: repos.enabled needs repos.app.privateKey.name (a GitHub App, recommended) or repos.token.name (a Secret with a read-only GitHub token)" }}
{{- end }}
{{- if $appKey }}
{{- $id := include "slack-relay.reposAppId" . }}
{{- if not (or (regexMatch "^([0-9]+|Iv[0-9A-Za-z.]+)$" $id) (and (eq $id "") $app.appIdKey)) }}
{{- fail "slack-relay: repos.app.appId must be the GitHub App's numeric ID or client ID (or empty with repos.app.appIdKey)" }}
{{- end }}
{{- if not (regexMatch "^[0-9]*$" (include "slack-relay.reposInstallationId" .)) }}
{{- fail "slack-relay: repos.app.installationId must be a number" }}
{{- end }}
{{- if not ($app.privateKey.key | default "") }}
{{- fail "slack-relay: repos.app.privateKey.key is required" }}
{{- end }}
{{- end }}
{{- $seen := dict }}
{{- range (include "slack-relay.repos" . | fromJsonArray) }}
{{- if or (not (regexMatch "^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$" .repo)) (regexMatch "(^|/)\\.\\.?(/|$)" .repo) }}
{{- fail (printf "slack-relay: repos.list entry %q must be owner/name" .repo) }}
{{- end }}
{{- if and .ref (or (not (regexMatch "^[A-Za-z0-9._/-]+$" .ref)) (hasPrefix "-" .ref) (contains ".." .ref)) }}
{{- fail (printf "slack-relay: repos.list ref %q for %s must be a branch, tag or commit" .ref .repo) }}
{{- end }}
{{- if hasKey $seen (lower .repo) }}
{{- fail (printf "slack-relay: repos.list names %s more than once (one ref per repo)" .repo) }}
{{- end }}
{{- $_ := set $seen (lower .repo) true }}
{{- end }}
{{- if not (regexMatch "^(https?://)?[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~/-]*)?$" (.Values.repos.host | default "")) }}
{{- fail "slack-relay: repos.host must be a host name or base URL without credentials, e.g. github.com or https://ghe.example.com" }}
{{- end }}
{{- if not (regexMatch "^(https?://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~/-]*)?)?$" (.Values.repos.apiUrl | default "")) }}
{{- fail "slack-relay: repos.apiUrl must be an http(s) URL without credentials, e.g. https://ghe.example.com/api/v3" }}
{{- end }}
{{- $m := .Values.repos.refreshMinutes }}
{{- if not (and (or (kindIs "int" $m) (kindIs "int64" $m) (kindIs "float64" $m)) (ge (float64 $m) 1.0) (eq (float64 (int $m)) (float64 $m))) }}
{{- fail "slack-relay: repos.refreshMinutes must be a whole number of minutes, at least 1" }}
{{- end }}
{{- end }}
{{- end }}

{{/* repos.app.appId / installationId as strings (YAML numbers render as floats otherwise); a fractional number stays as written, so validation refuses it. */}}
{{- define "slack-relay.reposAppId" -}}
{{- $v := (.Values.repos.app | default dict).appId | default "" }}
{{- if or (kindIs "int64" $v) (kindIs "int" $v) (and (kindIs "float64" $v) (eq (float64 (int64 $v)) $v)) }}{{ int64 $v }}{{ else }}{{ $v | toString | trim }}{{ end }}
{{- end }}
{{- define "slack-relay.reposInstallationId" -}}
{{- $v := (.Values.repos.app | default dict).installationId | default "" }}
{{- if or (kindIs "int64" $v) (kindIs "int" $v) (and (kindIs "float64" $v) (eq (float64 (int64 $v)) $v)) }}{{ int64 $v }}{{ else }}{{ $v | toString | trim }}{{ end }}
{{- end }}

{{/* repos.list as JSON [{repo, ref}], strings and maps alike. */}}
{{- define "slack-relay.repos" -}}
{{- $out := list }}
{{- range .Values.repos.list }}
{{- if kindIs "string" . }}
{{- $out = append $out (dict "repo" . "ref" "") }}
{{- else }}
{{- $out = append $out (dict "repo" (.repo | default "" | toString) "ref" (.ref | default "" | toString)) }}
{{- end }}
{{- end }}
{{- $out | toJson }}
{{- end }}

{{/* Clone base URL from repos.host: a bare host gets https://. */}}
{{- define "slack-relay.reposBaseUrl" -}}
{{- $h := .Values.repos.host | default "github.com" | trimSuffix "/" }}
{{- if contains "://" $h }}{{ $h }}{{ else }}{{ printf "https://%s" $h }}{{ end }}
{{- end }}

{{/* GitHub API base for listing repos: api.github.com, or <base>/api/v3 on GHE. */}}
{{- define "slack-relay.reposApiUrl" -}}
{{- $base := include "slack-relay.reposBaseUrl" . }}
{{- if .Values.repos.apiUrl }}{{ .Values.repos.apiUrl | trimSuffix "/" }}
{{- else if eq $base "https://github.com" }}https://api.github.com
{{- else }}{{ printf "%s/api/v3" $base }}
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
{{- if (.Values.relaygate.url | default "" | trim) }}
- name: RELAYGATE_URL
  value: {{ .Values.relaygate.url | trim | quote }}
{{- else }}
- name: RELAYCAST_BASE_URL
  value: {{ .Values.relaycast.baseUrl | quote }}
{{- end }}
- name: RELAY_CHANNEL
  value: {{ .Values.relaycast.channel | quote }}
- name: ROUTER_AGENT_NAME
  value: {{ .Values.router.agentName | quote }}
{{- if (.Values.relaygate.url | default "" | trim) }}
{{ include "slack-relay.secretEnv" (dict "env" "RELAYGATE_ENROLLMENT_KEY" "ref" .Values.secrets.relaygateEnrollmentKey) }}
{{- else }}
{{ include "slack-relay.secretEnv" (dict "env" "RELAYCAST_WORKSPACE_KEY" "ref" .Values.secrets.relaycastWorkspaceKey) }}
{{- end }}
{{- if .Values.secrets.agentIdentitySecret.name }}
{{ include "slack-relay.secretEnv" (dict "env" "AGENT_IDENTITY_SECRET" "ref" .Values.secrets.agentIdentitySecret) }}
{{- end }}
{{- end }}
