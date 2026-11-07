{{- define "relay-cloud-api.name" -}}{{ default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}{{- end -}}
{{- define "relay-cloud-api.fullname" -}}{{ if .Values.fullnameOverride }}{{ .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}{{ else }}{{ printf "%s-%s" .Release.Name (include "relay-cloud-api.name" .) | trunc 63 | trimSuffix "-" }}{{ end }}{{- end -}}
{{- define "relay-cloud-api.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{ include "relay-cloud-api.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: agent-relay
{{- end -}}
{{- /* Job metadata labels: the runtime component label is replaced by
migration so `kubectl wait job -l app.kubernetes.io/component=migration`
(NOTES.txt) finds the Job. */ -}}
{{- define "relay-cloud-api.migrationLabels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
app.kubernetes.io/name: {{ include "relay-cloud-api.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: migration
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: agent-relay
{{- end -}}
{{- define "relay-cloud-api.selectorLabels" -}}
app.kubernetes.io/name: {{ include "relay-cloud-api.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: api
{{- end -}}
{{- define "relay-cloud-api.serviceAccountName" -}}{{ if .Values.serviceAccount.create }}{{ default (include "relay-cloud-api.fullname" .) .Values.serviceAccount.name }}{{ else }}{{ default "default" .Values.serviceAccount.name }}{{ end }}{{- end -}}
{{- define "relay-cloud-api.image" -}}
{{- $digest := required "image.digest is required; relay-cloud-api images must be pinned by sha256 digest" .Values.image.digest -}}
{{- if not (regexMatch "^sha256:[a-f0-9]{64}$" $digest) }}{{ fail "image.digest must be sha256:<64 lowercase hex characters>" }}{{ end -}}
{{- printf "%s@%s" .Values.image.repository $digest -}}
{{- end -}}
{{- /* Single-host mode (global.singleHost.host, set once on the agent-relay
umbrella): the API is served on that host under /cloud/api, /login and /api
next to the dashboard, so publicUrl is https://<host> and is derived instead
of set a second time. Desktop and the CLI log in against that same origin. */ -}}
{{- define "relay-cloud-api.singleHost" -}}{{ dig "singleHost" "host" "" (.Values.global | default dict) }}{{- end -}}
{{- define "relay-cloud-api.publicUrl" -}}
{{- $single := include "relay-cloud-api.singleHost" . -}}
{{- if $single }}{{ printf "https://%s" $single }}{{ else }}{{ .Values.publicUrl }}{{ end -}}
{{- end -}}
{{- define "relay-cloud-api.validateSingleHost" -}}
{{- $single := include "relay-cloud-api.singleHost" . -}}
{{- if $single }}
{{- if or (gt (len $single) 253) (regexMatch "(^|\\.)[0-9]+$" $single) (not (regexMatch "^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)*[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$" $single)) }}{{ fail "global.singleHost.host must be a lowercase DNS hostname (no scheme, port or path; labels of 1-63 characters that start and end with a letter or digit, not an IP address)" }}{{ end -}}
{{- if and .Values.publicUrl (ne (trimSuffix "/" .Values.publicUrl) (printf "https://%s" $single)) }}{{ fail (printf "publicUrl is derived from global.singleHost.host (https://%s); leave publicUrl empty" $single) }}{{ end -}}
{{- if .Values.ingress.enabled }}{{ fail "global.singleHost.host serves the API through the dashboard host's routes (/cloud/api, /login, /api); set ingress.enabled=false (relay-dashboard.ingress or the agent-relay gkeIngress routes it)" }}{{ end -}}
{{- end -}}
{{- end -}}
{{- define "relay-cloud-api.validate" -}}
{{- $image := include "relay-cloud-api.image" . -}}
{{- if ne (int .Values.replicaCount) 1 }}{{ fail "replicaCount must be 1: the self-host API pilot has process-local login/device rate limits and is not HA" }}{{ end -}}
{{- if not .Values.existingSecret }}{{ fail "existingSecret is required; inline credentials are not supported" }}{{ end -}}
{{- if .Values.license.existingSecret -}}
{{- if not (regexMatch "^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$" .Values.license.existingSecret) }}{{ fail "license.existingSecret must be a Kubernetes Secret name" }}{{ end -}}
{{- if not (regexMatch "^[A-Za-z0-9._-]+$" .Values.license.key) }}{{ fail "license.key must be a Kubernetes Secret data key" }}{{ end -}}
{{- if and (eq .Values.license.existingSecret .Values.existingSecret) (eq .Values.license.key .Values.secretKeys.databaseMigrationsUrl) }}{{ fail "license must not mount the migration credential into the API pod" }}{{ end -}}
{{- end -}}
{{- $optionalSecretKeys := list "previousEncryptionKey" "internalToken" "telemetryInstallKey" "relaycastInternalSecret" "oidcClientSecret" "smtpPassword" -}}
{{- range $name, $key := .Values.secretKeys }}{{ if and (has $name $optionalSecretKeys) (empty $key) }}{{ continue }}{{ end }}{{ if not (regexMatch "^[A-Za-z0-9._-]+$" (toString $key)) }}{{ fail (printf "secretKeys.%s must be a Kubernetes Secret data key" $name) }}{{ end }}{{ end -}}
{{- /* Every non-empty secretKeys.* value must name a distinct Secret key. The
API pod projects the runtime and optional keys by key name, so a collision
with databaseMigrationsUrl would mount the migration (owner) credential into
the API pod, and any other collision would feed one credential to two
settings. */ -}}
{{- $seenSecretKeys := dict -}}
{{- range $name := keys .Values.secretKeys | sortAlpha }}{{ $key := toString (index $.Values.secretKeys $name) }}{{ if empty $key }}{{ continue }}{{ end }}{{ if hasKey $seenSecretKeys $key }}{{ fail (printf "secretKeys.%s and secretKeys.%s both name Secret key %q: every secretKeys value must be distinct (a collision with databaseMigrationsUrl would mount the migration credential into the API pod)" (get $seenSecretKeys $key) $name $key) }}{{ end }}{{ $_ := set $seenSecretKeys $key $name }}{{ end -}}
{{- include "relay-cloud-api.validateRuntime" . -}}
{{- if and .Values.migrations.enabled (not (regexMatch "^[A-Za-z_][A-Za-z0-9_$]{0,62}$" .Values.database.runtimeRole)) }}{{ fail "database.runtimeRole must be a valid PostgreSQL role name when migrations are enabled" }}{{ end -}}
{{- include "relay-cloud-api.validateSingleHost" . -}}
{{- include "relay-cloud-api.validateIdentity" . -}}
{{- include "relay-cloud-api.validateIntegrations" . -}}
{{- if not (regexMatch "^https://[^/?#]+$" (include "relay-cloud-api.publicUrl" .)) }}{{ fail "publicUrl must be an HTTPS origin with no path" }}{{ end -}}
{{- range $name, $url := dict "relayauthUrl" .Values.services.relayauthUrl "relaycastUrl" .Values.services.relaycastUrl "relayhistoryUrl" .Values.services.relayhistoryUrl }}{{ if not (regexMatch "^https?://[^/?#]+$" $url) }}{{ fail (printf "services.%s must be an HTTP(S) origin with no path" $name) }}{{ end }}{{ end -}}
{{- $publicOriginPattern := "^https://([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\\.)+[A-Za-z]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(:[0-9]{1,5})?$" -}}
{{- range $name, $url := dict "relaycastPublicUrl" .Values.services.relaycastPublicUrl "relayhistoryPublicUrl" .Values.services.relayhistoryPublicUrl -}}
{{- if or (not (regexMatch $publicOriginPattern $url)) (regexMatch "(?i)\\.(localhost|local|internal|lan|invalid|test|example|home\\.arpa|onion)(:[0-9]{1,5})?$" $url) (regexMatch "(?i)\\.example\\.(com|net|org)(:[0-9]{1,5})?$" $url) }}{{ fail (printf "services.%s must be a public HTTPS origin with multi-label DNS and no credentials, path, query, or fragment" $name) }}{{ end -}}
{{- $portToken := regexFind ":[0-9]+$" $url -}}
{{- if and $portToken (or (lt (int (trimPrefix ":" $portToken)) 1) (gt (int (trimPrefix ":" $portToken)) 65535)) }}{{ fail (printf "services.%s port must be between 1 and 65535" $name) }}{{ end -}}
{{- end -}}
{{- if and .Values.networkPolicy.enabled (not .Values.networkPolicy.allowAllEgress) (empty .Values.networkPolicy.additionalEgress) }}{{ fail "networkPolicy.enabled with allowAllEgress=false requires networkPolicy.additionalEgress: restricted egress allows only same-namespace pods and DNS, which blocks the external PostgreSQL database and any RelayAuth, Relaycast or Relay History URL outside the namespace" }}{{ end -}}
{{- range .Values.networkPolicy.additionalEgress }}{{ if empty .to }}{{ fail "every networkPolicy.additionalEgress rule needs a non-empty to (an empty to matches every destination; use ipBlock 0.0.0.0/0 to allow any destination explicitly)" }}{{ end }}{{ end -}}
{{- range $key, $_ := include "relay-cloud-api.selectorLabels" . | fromYaml }}{{ if hasKey ($.Values.podLabels | default dict) $key }}{{ fail (printf "podLabels must not set selector label %s: the Deployment selector would no longer match its pods" $key) }}{{ end }}{{ end -}}
{{- if ne .Values.service.type "ClusterIP" }}{{ fail "service.type must be ClusterIP" }}{{ end -}}
{{- if .Values.ingress.enabled }}{{ if empty .Values.ingress.hosts }}{{ fail "ingress.enabled=true requires at least one host" }}{{ end }}{{ if not (has (urlParse (include "relay-cloud-api.publicUrl" .)).hostname .Values.ingress.hosts) }}{{ fail "ingress.hosts must include the publicUrl host" }}{{ end }}{{ if and (not .Values.ingress.externalTls) (empty .Values.ingress.tls) }}{{ fail "ingress.enabled=true requires ingress.tls unless externalTls=true" }}{{ end }}{{ if and .Values.networkPolicy.enabled (empty .Values.networkPolicy.ingressFrom) }}{{ fail "ingress with networkPolicy requires networkPolicy.ingressFrom" }}{{ end }}{{ end -}}
{{- /* extraEnv is appended to the API and migration containers. Reject names
the chart already sets, including duplicates inside extraEnv. */ -}}
{{- $managed := list "PORT" "SELFHOST_PUBLIC_URL" "RELAYAUTH_URL" "RELAYCAST_URL" "RELAYCAST_PUBLIC_URL" "RELAYHISTORY_URL" "RELAYHISTORY_PUBLIC_URL" "DATABASE_MIGRATIONS_URL_FILE" "SELFHOST_RUNTIME_DATABASE_ROLE" "SELFHOST_LICENSE_FILE" -}}
{{- range $src := list (include "relay-cloud-api.runtimeEnv" .) (include "relay-cloud-api.secretEnv" .) -}}
{{- range $item := $src | fromYamlArray }}{{ $managed = append $managed (toString $item.name) }}{{ end -}}
{{- end -}}
{{- if .Values.integrations -}}
{{- $integrationEnv := include "relay-cloud-api.integrationEnv" . -}}
{{- if $integrationEnv }}{{ range $item := $integrationEnv | fromYamlArray }}{{ $managed = append $managed (toString $item.name) }}{{ end }}{{ end -}}
{{- end -}}
{{- range .Values.extraEnv -}}
{{- if or (not (kindIs "map" .)) (not .name) }}{{ fail "every extraEnv entry must be an object with a name" }}{{ end -}}
{{- if has (toString .name) $managed }}{{ fail (printf "%s is managed by structured chart values and must not appear in extraEnv" .name) }}{{ end -}}
{{- $managed = append $managed (toString .name) -}}
{{- end -}}
{{- end -}}
{{- /* Secret files mounted into the API pod: env name -> Secret data key.
Optional keys are left out while empty. */ -}}
{{- define "relay-cloud-api.secretFiles" -}}
{{- $files := dict "DATABASE_URL_FILE" .Values.secretKeys.databaseUrl "RELAYAUTH_API_KEY_FILE" .Values.secretKeys.relayauthApiKey "SELFHOST_BOOTSTRAP_TOKEN_FILE" .Values.secretKeys.bootstrapToken "SELFHOST_ENCRYPTION_KEY_FILE" .Values.secretKeys.encryptionKey -}}
{{- with .Values.secretKeys.previousEncryptionKey }}{{ $_ := set $files "SELFHOST_ENCRYPTION_PREVIOUS_KEY_FILE" . }}{{ end -}}
{{- with .Values.secretKeys.internalToken }}{{ $_ := set $files "SELFHOST_INTERNAL_TOKEN_FILE" . }}{{ end -}}
{{- with .Values.secretKeys.relaycastInternalSecret }}{{ $_ := set $files "RELAYCAST_INTERNAL_SECRET_FILE" . }}{{ end -}}
{{- if and .Values.auth.oidc.issuer .Values.secretKeys.oidcClientSecret }}{{ $_ := set $files "SELFHOST_OIDC_CLIENT_SECRET_FILE" .Values.secretKeys.oidcClientSecret }}{{ end -}}
{{- if and .Values.smtp.host .Values.smtp.username .Values.secretKeys.smtpPassword }}{{ $_ := set $files "SELFHOST_SMTP_PASSWORD_FILE" .Values.secretKeys.smtpPassword }}{{ end -}}
{{- if and (ne (include "relay-cloud-api.telemetryLevel" .) "off") .Values.secretKeys.telemetryInstallKey }}{{ $_ := set $files "SELFHOST_TELEMETRY_INSTALL_KEY_FILE" .Values.secretKeys.telemetryInstallKey }}{{ end -}}
{{- toJson $files -}}
{{- end -}}
{{- define "relay-cloud-api.secretEnv" -}}
{{- range $env, $key := include "relay-cloud-api.secretFiles" . | fromJson }}
- name: {{ $env }}
  value: /var/run/agent-relay/secrets/{{ $key }}
{{- end }}
{{- end -}}
{{- define "relay-cloud-api.secretItems" -}}
{{- range $key := include "relay-cloud-api.secretFiles" . | fromJson | values | sortAlpha | uniq }}
{{- if eq $key (toString $.Values.secretKeys.databaseMigrationsUrl) }}{{ fail "the API pod must never mount secretKeys.databaseMigrationsUrl" }}{{ end }}
- { key: {{ $key | quote }}, path: {{ $key | quote }} }
{{- end }}
{{- end -}}
{{- /* YAML 1.1 reads a bare off as false; treat it as "off". */ -}}
{{- /* telemetry.level as configured (validated against off|errors|full). */ -}}
{{- define "relay-cloud-api.telemetryConfiguredLevel" -}}
{{- $level := .Values.telemetry.level -}}
{{- if kindIs "bool" $level }}{{ ternary "on" "off" $level }}{{ else }}{{ $level | default "off" | toString | lower }}{{ end -}}
{{- end -}}
{{- /* True (non-empty) once the install is registered: any of installId,
secretKeys.telemetryInstallKey or endpoint is set. */ -}}
{{- define "relay-cloud-api.telemetryRegistered" -}}
{{- if or .Values.telemetry.installId .Values.secretKeys.telemetryInstallKey .Values.telemetry.endpoint }}true{{ end -}}
{{- end -}}
{{- /* Effective level: the configured level once the install is registered,
otherwise off. The default (errors) therefore takes effect only after the
operator supplies the registration; a partial registration fails the render. */ -}}
{{- define "relay-cloud-api.telemetryLevel" -}}
{{- if include "relay-cloud-api.telemetryRegistered" . }}{{ include "relay-cloud-api.telemetryConfiguredLevel" . }}{{ else }}off{{ end -}}
{{- end -}}
{{- /* True (non-empty) when the API sends telemetry over the network. */ -}}
{{- define "relay-cloud-api.telemetryEgress" -}}
{{- if and (ne (include "relay-cloud-api.telemetryLevel" .) "off") (eq (.Values.telemetry.transport | default "https") "https") }}true{{ end -}}
{{- end -}}
{{- /* Non-secret deployment shape for SELFHOST_TELEMETRY_DEPLOYMENT; the API
keeps only short keys, numbers, booleans and version-like strings.
telemetry.deployment is checked in validateRuntime before it is merged. */ -}}
{{- define "relay-cloud-api.telemetryDeployment" -}}
{{- $shape := dict "chart" .Chart.Name "chartVersion" .Chart.Version "appVersion" .Chart.AppVersion "replicas" 1 "flowsStorage" (.Values.flows.storage | default "postgres") "networkPolicy" (.Values.networkPolicy.enabled | default false) "ingress" (.Values.ingress.enabled | default false) -}}
{{- toJson (mergeOverwrite $shape (deepCopy (.Values.telemetry.deployment | default dict))) -}}
{{- end -}}
{{- define "relay-cloud-api.runtimeEnv" -}}
- { name: SELFHOST_ENCRYPTION_KEY_ID, value: {{ .Values.encryption.keyId | quote }} }
{{- with .Values.encryption.previousKeyId }}
- { name: SELFHOST_ENCRYPTION_PREVIOUS_KEY_ID, value: {{ . | quote }} }
{{- end }}
{{- with .Values.dashboardUrl }}
- { name: SELFHOST_DASHBOARD_URL, value: {{ . | quote }} }
{{- end }}
- { name: SELFHOST_FLOWS_STORAGE, value: {{ .Values.flows.storage | default "postgres" | quote }} }
{{- if eq (.Values.flows.storage | default "postgres") "gcs" }}
- { name: SELFHOST_FLOWS_GCS_BUCKET, value: {{ .Values.flows.gcsBucket | quote }} }
{{- with .Values.flows.gcsPrefix }}
- { name: SELFHOST_FLOWS_GCS_PREFIX, value: {{ . | quote }} }
{{- end }}
{{- end }}
{{- with .Values.flows.workerRelaycastUrl }}
- { name: SELFHOST_FLOWS_WORKER_RELAYCAST_URL, value: {{ . | quote }} }
{{- end }}
{{- if not (kindIs "invalid" .Values.flows.queuePingMs) }}{{ if ne (toString .Values.flows.queuePingMs) "" }}
- { name: SELFHOST_FLOWS_QUEUE_PING_MS, value: {{ int64 .Values.flows.queuePingMs | toString | quote }} }
{{- end }}{{ end }}
{{- include "relay-cloud-api.identityEnv" . }}
{{- $level := include "relay-cloud-api.telemetryLevel" . }}
- { name: SELFHOST_TELEMETRY_LEVEL, value: {{ $level | quote }} }
- { name: SELFHOST_TELEMETRY_TRANSPORT, value: {{ .Values.telemetry.transport | default "https" | quote }} }
{{- if ne $level "off" }}
{{- with .Values.telemetry.endpoint }}
- { name: SELFHOST_TELEMETRY_ENDPOINT, value: {{ . | quote }} }
{{- end }}
- { name: SELFHOST_TELEMETRY_INSTALL_ID, value: {{ .Values.telemetry.installId | quote }} }
{{- with .Values.telemetry.probes }}
- name: SELFHOST_TELEMETRY_PROBES
  value: {{ $probes := list }}{{ range . }}{{ $probes = append $probes (printf "%s=%s" (toString .name) (toString .url)) }}{{ end }}{{ join "," $probes | quote }}
{{- end }}
- name: SELFHOST_TELEMETRY_DEPLOYMENT
  value: {{ include "relay-cloud-api.telemetryDeployment" . | quote }}
{{- end }}
{{- end -}}
{{- /* Fail-closed checks for the relaycontrol runtime contract (src/config.ts,
src/flows/config.ts, src/telemetry/config.ts): everything the API would refuse
at startup is refused at render time instead of crash-looping. */ -}}
{{- define "relay-cloud-api.validateRuntime" -}}
{{- $idPattern := "^[A-Za-z0-9_-]{1,64}$" -}}
{{- if not .Values.encryption.keyId }}{{ fail "encryption.keyId is required (SELFHOST_ENCRYPTION_KEY_ID): the non-secret id of secretKeys.encryptionKey" }}{{ end -}}
{{- if not (regexMatch $idPattern (toString .Values.encryption.keyId)) }}{{ fail "encryption.keyId must contain 1-64 URL-safe characters (A-Z a-z 0-9 _ -)" }}{{ end -}}
{{- if ne (empty .Values.encryption.previousKeyId) (empty .Values.secretKeys.previousEncryptionKey) }}{{ fail "encryption.previousKeyId and secretKeys.previousEncryptionKey must be set together (both or neither)" }}{{ end -}}
{{- with .Values.encryption.previousKeyId }}
{{- if not (regexMatch $idPattern (toString .)) }}{{ fail "encryption.previousKeyId must contain 1-64 URL-safe characters (A-Z a-z 0-9 _ -)" }}{{ end -}}
{{- if eq (toString .) (toString $.Values.encryption.keyId) }}{{ fail "encryption.previousKeyId must differ from encryption.keyId" }}{{ end -}}
{{- if eq $.Values.secretKeys.previousEncryptionKey $.Values.secretKeys.encryptionKey }}{{ fail "secretKeys.previousEncryptionKey must name a different Secret key than secretKeys.encryptionKey" }}{{ end -}}
{{- end -}}
{{- with .Values.dashboardUrl }}{{ if not (regexMatch "^https?://[^/?#@\\s]+(/[^?#\\s]*)?$" .) }}{{ fail "dashboardUrl must be an absolute http(s) URL without credentials, query or fragment" }}{{ end }}{{ end -}}
{{- $storage := .Values.flows.storage | default "postgres" -}}
{{- if not (has $storage (list "postgres" "gcs")) }}{{ fail "flows.storage must be postgres or gcs" }}{{ end -}}
{{- if and (eq $storage "gcs") (not .Values.flows.gcsBucket) }}{{ fail "flows.gcsBucket is required when flows.storage=gcs" }}{{ end -}}
{{- if and (ne $storage "gcs") (or .Values.flows.gcsBucket .Values.flows.gcsPrefix) }}{{ fail "flows.gcsBucket and flows.gcsPrefix apply only to flows.storage=gcs" }}{{ end -}}
{{- with .Values.flows.gcsBucket }}
{{- $bucket := toString . -}}
{{- if not (regexMatch "^[a-z0-9][a-z0-9._-]{1,220}[a-z0-9]$" $bucket) }}{{ fail "flows.gcsBucket must be a GCS bucket name: 3-222 lowercase letters, digits, dots, dashes and underscores, starting and ending with a letter or digit" }}{{ end -}}
{{- if and (not (contains "." $bucket)) (gt (len $bucket) 63) }}{{ fail "flows.gcsBucket must be at most 63 characters unless it is a dotted name" }}{{ end -}}
{{- range $part := splitList "." $bucket }}{{ if or (empty $part) (gt (len $part) 63) (not (regexMatch "^[a-z0-9]([a-z0-9_-]*[a-z0-9])?$" $part)) }}{{ fail "flows.gcsBucket dotted components must each be 1-63 characters and start and end with a letter or digit" }}{{ end }}{{ end -}}
{{- if or (hasPrefix "goog" $bucket) (contains "google" $bucket) (regexMatch "^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$" $bucket) }}{{ fail "flows.gcsBucket must not start with goog, contain google, or be an IP address" }}{{ end -}}
{{- end -}}
{{- with .Values.flows.workerRelaycastUrl }}{{ if not (regexMatch "^https?://[^/?#@\\s]+(/[^?#\\s]*)?$" .) }}{{ fail "flows.workerRelaycastUrl must be an absolute http(s) URL without credentials, query or fragment" }}{{ end }}{{ end -}}
{{- if not (kindIs "invalid" .Values.flows.queuePingMs) }}{{ if ne (toString .Values.flows.queuePingMs) "" }}
{{- if not (regexMatch "^[0-9]+$" (toString .Values.flows.queuePingMs)) }}{{ fail "flows.queuePingMs must be an integer from 1000 to 120000" }}{{ end -}}
{{- if or (lt (int64 .Values.flows.queuePingMs) 1000) (gt (int64 .Values.flows.queuePingMs) 120000) }}{{ fail "flows.queuePingMs must be an integer from 1000 to 120000" }}{{ end -}}
{{- end }}{{ end -}}
{{- if not (has (include "relay-cloud-api.telemetryConfiguredLevel" .) (list "off" "errors" "full")) }}{{ fail "telemetry.level must be off, errors, or full" }}{{ end -}}
{{- $level := include "relay-cloud-api.telemetryLevel" . -}}
{{- $transport := .Values.telemetry.transport | default "https" -}}
{{- if not (has $transport (list "https" "file")) }}{{ fail "telemetry.transport must be https or file" }}{{ end -}}
{{- with .Values.telemetry.endpoint }}{{ if not (regexMatch "^https://[^/?#@\\s]+(/[^?#\\s]*)?$" .) }}{{ fail "telemetry.endpoint must be an https URL without credentials, query or fragment" }}{{ end }}{{ end -}}
{{- with .Values.telemetry.installId }}{{ if not (regexMatch "^inst_[A-Za-z0-9]{8,64}$" .) }}{{ fail "telemetry.installId must look like inst_<8-64 alphanumerics>" }}{{ end }}{{ end -}}
{{- if ne $level "off" }}
{{- if not .Values.telemetry.installId }}{{ fail "telemetry.installId is required once telemetry is registered (secretKeys.telemetryInstallKey or endpoint set) unless telemetry.level is off" }}{{ end -}}
{{- if not .Values.secretKeys.telemetryInstallKey }}{{ fail "secretKeys.telemetryInstallKey is required once telemetry is registered (installId or endpoint set) unless telemetry.level is off" }}{{ end -}}
{{- if and (eq $transport "https") (not .Values.telemetry.endpoint) }}{{ fail "telemetry.endpoint is required for telemetry.transport=https once telemetry is registered, unless telemetry.level is off" }}{{ end -}}
{{- if and (eq $transport "https") .Values.networkPolicy.enabled (not .Values.networkPolicy.allowAllEgress) (empty .Values.telemetry.egressTo) }}{{ fail "telemetry.egressTo must not be empty: restricted egress would block the telemetry endpoint (list the ingest endpoint's addresses)" }}{{ end -}}
{{- end -}}
{{- $probeNames := list -}}
{{- range .Values.telemetry.probes }}
{{- $probeName := toString .name -}}
{{- if not (kindIs "string" .name) }}{{ fail "telemetry.probes[].name must be a string (quote numeric names)" }}{{ end -}}
{{- if not (regexMatch "^[a-z0-9][a-z0-9-]{0,39}$" $probeName) }}{{ fail "telemetry.probes[].name must be lowercase letters, digits and dashes (max 40)" }}{{ end -}}
{{- if has $probeName $probeNames }}{{ fail (printf "telemetry.probes has a duplicate entry for %s" $probeName) }}{{ end -}}
{{- $probeNames = append $probeNames $probeName -}}
{{- if not (regexMatch "^https?://[^/?#@,\\s]+(/[^#,\\s]*)?$" (toString .url)) }}{{ fail (printf "telemetry.probes %s url must be an http(s) URL without credentials, fragment or commas" $probeName) }}{{ end -}}
{{- end -}}
{{- /* telemetry.deployment: flat, non-secret additions only, mirroring the
API's sanitizeDeploymentShape (src/telemetry/config.ts) so nothing the API
would silently drop, and nothing that could carry data, is rendered. */ -}}
{{- $deployment := .Values.telemetry.deployment | default dict -}}
{{- if not (kindIs "map" $deployment) }}{{ fail "telemetry.deployment must be a map of short keys to scalar values" }}{{ end -}}
{{- if gt (len $deployment) 32 }}{{ fail "telemetry.deployment allows at most 32 keys" }}{{ end -}}
{{- $reservedShape := list "chart" "chartVersion" "appVersion" "replicas" "flowsStorage" "networkPolicy" "ingress" -}}
{{- range $key, $value := $deployment }}
{{- if not (regexMatch "^[A-Za-z][A-Za-z0-9_.-]{0,47}$" $key) }}{{ fail (printf "telemetry.deployment key %q must start with a letter and contain at most 48 letters, digits, dots, dashes and underscores" $key) }}{{ end -}}
{{- if has $key $reservedShape }}{{ fail (printf "telemetry.deployment.%s is rendered by the chart and must not be overridden" $key) }}{{ end -}}
{{- if kindIs "string" $value }}
{{- if or (not (regexMatch "^[A-Za-z0-9][A-Za-z0-9_.+:@/-]{0,79}$" $value)) (contains "//" $value) }}{{ fail (printf "telemetry.deployment.%s must be a short version-like string (letters, digits and _.+:@/-, max 80, no URLs)" $key) }}{{ end -}}
{{- else if not (or (kindIs "bool" $value) (kindIs "int" $value) (kindIs "int64" $value) (kindIs "float64" $value)) }}{{ fail (printf "telemetry.deployment.%s must be a string, number or boolean (nested maps, lists and nulls are not allowed)" $key) }}{{ end -}}
{{- end -}}
{{- if gt (len .Values.telemetry.probes) 20 }}{{ fail "telemetry.probes allows at most 20 entries" }}{{ end -}}
{{- end -}}
{{- define "relay-cloud-api.migrationPodTemplate" -}}
metadata:
  labels:
    app.kubernetes.io/name: {{ include "relay-cloud-api.name" . }}
    app.kubernetes.io/instance: {{ .Release.Name }}
    app.kubernetes.io/component: migration
spec:
  restartPolicy: Never
  serviceAccountName: {{ include "relay-cloud-api.serviceAccountName" . }}
  automountServiceAccountToken: false
  securityContext: {{ toYaml .Values.podSecurityContext | nindent 4 }}
  {{- with .Values.imagePullSecrets }}
  imagePullSecrets: {{ toYaml . | nindent 4 }}
  {{- end }}
  containers:
    - name: migrate
      image: {{ include "relay-cloud-api.image" . | quote }}
      imagePullPolicy: {{ .Values.image.pullPolicy }}
      command: {{ toYaml .Values.migrations.command | nindent 8 }}
      args: {{ toYaml .Values.migrations.args | nindent 8 }}
      securityContext: {{ toYaml .Values.containerSecurityContext | nindent 8 }}
      env:
        - name: DATABASE_MIGRATIONS_URL_FILE
          value: /var/run/agent-relay/secrets/{{ .Values.secretKeys.databaseMigrationsUrl }}
        - name: SELFHOST_RUNTIME_DATABASE_ROLE
          value: {{ .Values.database.runtimeRole | quote }}
        {{- with .Values.extraEnv }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
      volumeMounts:
        - { name: database, mountPath: /var/run/agent-relay/secrets, readOnly: true }
        - { name: tmp, mountPath: /tmp }
      resources: {{ toYaml .Values.resources | nindent 8 }}
  volumes:
    - name: database
      secret:
        secretName: {{ .Values.existingSecret }}
        defaultMode: 0440
        items:
          - key: {{ .Values.secretKeys.databaseMigrationsUrl | quote }}
            path: {{ .Values.secretKeys.databaseMigrationsUrl | quote }}
    - name: tmp
      emptyDir: { sizeLimit: 64Mi }
{{- end -}}

{{- /* bootstrap-signup: first-boot bootstrap, OIDC, email links, SMTP and
invites (relaycontrol src/identity/config.ts). Nothing renders while the
blocks are empty, so existing renders are unchanged. */ -}}
{{- define "relay-cloud-api.identityEnv" -}}
{{- with .Values.bootstrap.orgName }}
- { name: SELFHOST_BOOTSTRAP_ORG_NAME, value: {{ . | quote }} }
- { name: SELFHOST_BOOTSTRAP_ADMIN_EMAIL, value: {{ $.Values.bootstrap.adminEmail | lower | quote }} }
{{- with $.Values.bootstrap.adminName }}
- { name: SELFHOST_BOOTSTRAP_ADMIN_NAME, value: {{ . | quote }} }
{{- end }}
{{- with $.Values.bootstrap.workspaceName }}
- { name: SELFHOST_BOOTSTRAP_WORKSPACE_NAME, value: {{ . | quote }} }
{{- end }}
{{- end }}
{{- $oidc := .Values.auth.oidc }}
{{- with $oidc.issuer }}
- { name: SELFHOST_OIDC_ISSUER, value: {{ . | quote }} }
- { name: SELFHOST_OIDC_CLIENT_ID, value: {{ $oidc.clientId | quote }} }
{{- with $oidc.allowedDomains }}
- { name: SELFHOST_OIDC_ALLOWED_DOMAINS, value: {{ join "," . | lower | quote }} }
{{- end }}
{{- with $oidc.displayName }}
- { name: SELFHOST_OIDC_DISPLAY_NAME, value: {{ . | quote }} }
{{- end }}
{{- with $oidc.scopes }}
- { name: SELFHOST_OIDC_SCOPES, value: {{ . | quote }} }
{{- end }}
{{- with $oidc.redirectUrl }}
- { name: SELFHOST_OIDC_REDIRECT_URL, value: {{ . | quote }} }
{{- end }}
{{- if $oidc.allowHttpIssuer }}
- { name: SELFHOST_OIDC_ALLOW_HTTP_ISSUER, value: "true" }
{{- end }}
{{- end }}
{{- with .Values.smtp.host }}
- { name: SELFHOST_SMTP_HOST, value: {{ . | quote }} }
- { name: SELFHOST_SMTP_PORT, value: {{ int64 (ternary 587 $.Values.smtp.port (or (kindIs "invalid" $.Values.smtp.port) (eq (toString $.Values.smtp.port) ""))) | toString | quote }} }
{{- with $.Values.smtp.security }}
- { name: SELFHOST_SMTP_SECURITY, value: {{ . | quote }} }
{{- end }}
{{- with $.Values.smtp.username }}
- { name: SELFHOST_SMTP_USERNAME, value: {{ . | quote }} }
{{- end }}
- { name: SELFHOST_EMAIL_FROM, value: {{ $.Values.smtp.from | quote }} }
{{- end }}
{{- if .Values.auth.emailLink.enabled }}
- { name: SELFHOST_EMAIL_LOGIN, value: "true" }
{{- end }}
{{- with .Values.auth.autoJoinDomains }}
- { name: SELFHOST_AUTO_JOIN_DOMAINS, value: {{ join "," . | lower | quote }} }
{{- end }}
{{- if not (kindIs "invalid" .Values.auth.inviteTtlHours) }}{{ if ne (toString .Values.auth.inviteTtlHours) "" }}
- { name: SELFHOST_INVITE_TTL_HOURS, value: {{ int64 .Values.auth.inviteTtlHours | toString | quote }} }
{{- end }}{{ end }}
{{- end -}}

{{- define "relay-cloud-api.validateIdentity" -}}
{{- $email := "^[^@\\s<>()\",;:]+@[^@\\s<>()\",;:]+\\.[^@\\s<>()\",;:]+$" -}}
{{- $domain := "^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z]([a-z0-9-]{0,61}[a-z0-9])?$" -}}
{{- $b := .Values.bootstrap -}}
{{- if ne (empty $b.orgName) (empty $b.adminEmail) }}{{ fail "bootstrap.orgName and bootstrap.adminEmail must be set together" }}{{ end -}}
{{- if $b.adminEmail }}{{ if not (regexMatch $email (toString $b.adminEmail)) }}{{ fail "bootstrap.adminEmail must be an email address" }}{{ end }}{{ end -}}
{{- if and $b.orgName (not .Values.secretKeys.relaycastInternalSecret) }}{{ fail "bootstrap.orgName requires secretKeys.relaycastInternalSecret (the Secret key holding relaycast's internal secret, e.g. relaycast-internal-secret): the API creates the default workspace's Relaycast workspace with it" }}{{ end -}}
{{- if and (or $b.adminName $b.workspaceName) (not $b.orgName) }}{{ fail "bootstrap.adminName and bootstrap.workspaceName need bootstrap.orgName and bootstrap.adminEmail" }}{{ end -}}
{{- $oidc := .Values.auth.oidc -}}
{{- if and (or $b.orgName $oidc.issuer .Values.auth.emailLink.enabled .Values.smtp.host) (not .Values.dashboardUrl) (not (include "relay-cloud-api.singleHost" .)) }}{{ fail "dashboardUrl is required with bootstrap, auth.oidc, auth.emailLink or smtp (outside single-host mode): sign-in and invite links land on the dashboard origin, where the session cookie must be set" }}{{ end -}}
{{- if $oidc.issuer }}
{{- if not (regexMatch (ternary "^https?://[^?#@\\s]+$" "^https://[^?#@\\s]+$" (eq $oidc.allowHttpIssuer true)) (toString $oidc.issuer)) }}{{ fail "auth.oidc.issuer must be an https URL without credentials, query or fragment (allowHttpIssuer=true, for tests only, also accepts http)" }}{{ end -}}
{{- if not $oidc.clientId }}{{ fail "auth.oidc.clientId is required with auth.oidc.issuer" }}{{ end -}}
{{- if not .Values.secretKeys.oidcClientSecret }}{{ fail "auth.oidc.issuer requires secretKeys.oidcClientSecret (the Secret key holding the OIDC client secret)" }}{{ end -}}
{{- with $oidc.redirectUrl }}{{ if not (regexMatch "^https?://[^/?#@\\s]+/login/oidc/callback$" (toString .)) }}{{ fail "auth.oidc.redirectUrl must be <origin>/login/oidc/callback" }}{{ end }}{{ end -}}
{{- else if or $oidc.clientId $oidc.allowedDomains $oidc.displayName $oidc.scopes $oidc.redirectUrl $oidc.allowHttpIssuer }}
{{- fail "auth.oidc.* settings need auth.oidc.issuer" -}}
{{- end -}}
{{- if not (kindIs "slice" ($oidc.allowedDomains | default list)) }}{{ fail "auth.oidc.allowedDomains must be a list of email domains" }}{{ end -}}
{{- if not (kindIs "slice" (.Values.auth.autoJoinDomains | default list)) }}{{ fail "auth.autoJoinDomains must be a list of email domains" }}{{ end -}}
{{- range $item := concat ($oidc.allowedDomains | default list) (.Values.auth.autoJoinDomains | default list) }}
{{- if not (regexMatch $domain (lower (toString $item))) }}{{ fail (printf "auth.oidc.allowedDomains and auth.autoJoinDomains list email domains such as example.com (got %q)" (toString $item)) }}{{ end -}}
{{- end -}}
{{- if not (kindIs "invalid" .Values.auth.inviteTtlHours) }}{{ if ne (toString .Values.auth.inviteTtlHours) "" }}
{{- if or (not (regexMatch "^[0-9]+$" (toString .Values.auth.inviteTtlHours))) (lt (int64 .Values.auth.inviteTtlHours) 1) (gt (int64 .Values.auth.inviteTtlHours) 720) }}{{ fail "auth.inviteTtlHours must be an integer from 1 to 720" }}{{ end -}}
{{- end }}{{ end -}}
{{- $smtp := .Values.smtp -}}
{{- if and .Values.auth.emailLink.enabled (not $smtp.host) }}{{ fail "auth.emailLink.enabled requires smtp.host" }}{{ end -}}
{{- if $smtp.host }}
{{- if not (regexMatch "^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$" (toString $smtp.host)) }}{{ fail "smtp.host must be a hostname" }}{{ end -}}
{{- $port := ternary 587 $smtp.port (or (kindIs "invalid" $smtp.port) (eq (toString $smtp.port) "")) -}}
{{- if or (not (regexMatch "^[0-9]+$" (toString $port))) (lt (int64 $port) 1) (gt (int64 $port) 65535) }}{{ fail "smtp.port must be 1-65535" }}{{ end -}}
{{- if and $smtp.security (not (has (toString $smtp.security) (list "tls" "starttls" "none"))) }}{{ fail "smtp.security must be tls, starttls or none" }}{{ end -}}
{{- if or (not $smtp.from) (not (contains "@" (toString $smtp.from))) }}{{ fail "smtp.from is required with smtp.host, e.g. \"Agent Relay <relay@example.com>\"" }}{{ end -}}
{{- if ne (empty $smtp.username) (empty .Values.secretKeys.smtpPassword) }}{{ fail "smtp.username and secretKeys.smtpPassword must be set together" }}{{ end -}}
{{- else if or $smtp.username $smtp.from $smtp.security }}
{{- fail "smtp.* settings need smtp.host" -}}
{{- end -}}
{{- if and .Values.secretKeys.oidcClientSecret (not $oidc.issuer) }}{{ fail "secretKeys.oidcClientSecret is set but auth.oidc.issuer is empty" }}{{ end -}}
{{- if and .Values.secretKeys.smtpPassword (not $smtp.username) }}{{ fail "secretKeys.smtpPassword needs smtp.host and smtp.username" }}{{ end -}}
{{- end -}}

{{- /* Operator OAuth apps for just-in-time integration connects:
SELFHOST_OAUTH_<PROVIDER>_CLIENT_ID from the Secret, the client secret as a
mounted file (_CLIENT_SECRET_FILE), optional _SCOPES. */ -}}
{{- define "relay-cloud-api.integrationEnv" -}}
{{- range $provider := keys (.Values.integrations | default dict) | sortAlpha }}
{{- $app := index $.Values.integrations $provider }}
{{- $prefix := printf "SELFHOST_OAUTH_%s" (upper (replace "-" "_" $provider)) }}
- name: {{ printf "%s_CLIENT_ID" $prefix }}
  valueFrom:
    secretKeyRef: { name: {{ $app.existingSecret | quote }}, key: {{ $app.clientIdKey | default "client-id" | quote }} }
- { name: {{ printf "%s_CLIENT_SECRET_FILE" $prefix }}, value: {{ printf "/var/run/agent-relay/integrations/%s/client-secret" $provider | quote }} }
{{- with $app.scopes }}
- { name: {{ printf "%s_SCOPES" $prefix }}, value: {{ . | quote }} }
{{- end }}
{{- end }}
{{- end -}}

{{- define "relay-cloud-api.validateIntegrations" -}}
{{- $allowed := list "existingSecret" "clientIdKey" "clientSecretKey" "scopes" -}}
{{- range $provider, $app := (.Values.integrations | default dict) }}
{{- if not (regexMatch "^[a-z0-9]([a-z0-9-]{0,38}[a-z0-9])?$" $provider) }}{{ fail (printf "integrations.%s: provider ids are lowercase letters, digits and inner -" $provider) }}{{ end }}
{{- if not (kindIs "map" $app) }}{{ fail (printf "integrations.%s must be a map with existingSecret" $provider) }}{{ end }}
{{- range $field, $_ := $app }}{{ if not (has $field $allowed) }}{{ fail (printf "integrations.%s.%s is not supported: client IDs and secrets come only from existingSecret (allowed: existingSecret, clientIdKey, clientSecretKey, scopes)" $provider $field) }}{{ end }}{{ end }}
{{- if empty $app.existingSecret }}{{ fail (printf "integrations.%s.existingSecret is required; client IDs and secrets are never inline" $provider) }}{{ end }}
{{- range $field := list "clientIdKey" "clientSecretKey" }}{{ with index $app $field }}{{ if not (regexMatch "^[A-Za-z0-9._-]+$" (toString .)) }}{{ fail (printf "integrations.%s.%s must be a Kubernetes Secret data key" $provider $field) }}{{ end }}{{ end }}{{ end }}
{{- $idKey := toString ($app.clientIdKey | default "client-id") }}
{{- $secretKey := toString ($app.clientSecretKey | default "client-secret") }}
{{- if eq $idKey $secretKey }}{{ fail (printf "integrations.%s.clientIdKey and clientSecretKey must name different Secret keys" $provider) }}{{ end }}
{{- /* Never hand an API credential (the migration owner credential included) to an integration reference. */ -}}
{{- if eq (toString $app.existingSecret) (toString $.Values.existingSecret) }}{{- range $name, $key := $.Values.secretKeys }}{{- if and (not (empty $key)) (or (eq $idKey (toString $key)) (eq $secretKey (toString $key))) }}{{ fail (printf "integrations.%s must not reuse secretKeys.%s from existingSecret" $provider $name) }}{{ end }}{{ end }}{{ end }}
{{- end }}
{{- end -}}
