{{/*
Relaycast on TerseAI durable-actors (runtime.backend=durable-actors).
Env contract v1: relaycast branch selfhost/terse-actors-relaycast, mirrored in
docs/self-hosted-durable-actors.md. Every env name the gateway, the deployer
and the dev sidecar read is wired in this file only.
*/}}

{{/* "true" when the value is an integer (YAML numbers arrive as float64). */}}
{{- define "relaycast.isInt" -}}
{{- $v := . -}}
{{- if or (kindIs "int" $v) (kindIs "int64" $v) (and (kindIs "float64" $v) (eq ($v | int64 | float64) $v)) }}true{{ end -}}
{{- end }}

{{- define "relaycast.actors.enabled" -}}
{{- if eq (toString .Values.runtime.backend) "durable-actors" }}true{{ end -}}
{{- end }}

{{- define "relaycast.actors.dev" -}}
{{- if and (include "relaycast.actors.enabled" .) .Values.runtime.durableActors.devRuntime.enabled }}true{{ end -}}
{{- end }}

{{/* PVC needed: sqlite always; durable-actors only for the local file store. */}}
{{- define "relaycast.needsDataClaim" -}}
{{- if or (not (include "relaycast.actors.enabled" .)) (eq (toString .Values.runtime.durableActors.fileStore.driver) "local") }}true{{ end -}}
{{- end }}

{{- define "relaycast.actors.deployerName" -}}
{{- printf "%s-actors-deploy" (include "relaycast.fullname" . | trunc 45 | trimSuffix "-") -}}
{{- end }}

{{/*
Deploy Job name: <deployerName>-<8-hex pod-template hash>. The Job name is
copied into the pod's job-name label (max 63 characters), so the prefix is cut
to 54 before the 9-character suffix. Short names are unchanged.
*/}}
{{- define "relaycast.actors.deployJobName" -}}
{{- printf "%s-%s" (include "relaycast.actors.deployerName" .root | trunc 54 | trimSuffix "-") .hash -}}
{{- end }}

{{/*
The durable-actors control-plane Service name. Must equal the vendored chart's
`actors.name` (`<release>-durable-actors`, truncated to 63 as a whole).
*/}}
{{- define "relaycast.actors.controlPlaneServiceName" -}}
{{- printf "%s-durable-actors" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end }}

{{/* Env names the actor gateway sets itself; extraEnv must not repeat them. */}}
{{- define "relaycast.actors.reservedEnv" -}}
{{- list "PORT" "DURABLE_ACTORS_CONTROL_PLANE_URL" "DURABLE_ACTORS_PROJECT_ID" "DURABLE_ACTORS_SECRET" "DURABLE_ACTORS_HOME_REGION" "RELAYCAST_FILE_SIGNING_SECRET" "RELAYCAST_CREDENTIAL_KEYRING_FILE" "RELAYCAST_INTERNAL_SECRET_FILE" "RELAYCAST_WORKSPACE_BOOTSTRAP_SECRET" "RELAYCAST_WORKSPACE_BOOTSTRAP_SECRET_FILE" "RELAYCAST_WORKSPACE_BOOTSTRAP_PROOF_REQUIRED" "RELAYCAST_PUBLIC_WORKSPACE_CREATE" "RELAYCAST_FILE_STORE" "RELAYCAST_FILE_DIR" "RELAYCAST_GCS_BUCKET" "RELAYCAST_GCS_PREFIX" "RELAYCAST_S3_BUCKET" "RELAYCAST_S3_REGION" "RELAYCAST_S3_ENDPOINT" "RELAYCAST_S3_PREFIX" "RELAYCAST_S3_FORCE_PATH_STYLE" "AWS_ACCESS_KEY_ID" "AWS_SECRET_ACCESS_KEY" "RELAYCAST_MAX_UPLOAD_BYTES" "RELAYCAST_SHUTDOWN_GRACE_MS" "RELAYCAST_LOG_FORMAT" "RELAYCAST_ENV" | toJson -}}
{{- end }}

{{- define "relaycast.actors.imageRef" -}}
{{- $img := .image -}}
{{- if $img.digest -}}
{{- if not (regexMatch "^sha256:[a-f0-9]{64}$" $img.digest) }}{{ fail (printf "%s.digest must be sha256:<64 lowercase hex characters>" .path) }}{{ end -}}
{{- printf "%s@%s" $img.repository $img.digest -}}
{{- else if $img.tag -}}
{{- printf "%s:%s" $img.repository $img.tag -}}
{{- else -}}
{{- fail (printf "%s.digest (or, for local proofs, %s.tag) is required" .path .path) -}}
{{- end -}}
{{- end }}

{{- define "relaycast.actors.controlPlaneUrl" -}}
{{- $da := .Values.runtime.durableActors -}}
{{- if include "relaycast.actors.dev" . -}}
{{- printf "http://127.0.0.1:%d" ($da.devRuntime.port | int) -}}
{{- else if $da.controlPlaneUrl -}}
{{- $da.controlPlaneUrl -}}
{{- else -}}
{{- printf "http://%s.%s.svc.cluster.local:7100" (include "relaycast.actors.controlPlaneServiceName" .) .Release.Namespace -}}
{{- end -}}
{{- end }}

{{- define "relaycast.actors.validate" -}}
{{- $da := .Values.runtime.durableActors -}}
{{- $fs := $da.fileStore -}}
{{- $driver := toString $fs.driver -}}
{{- if not (regexMatch "^[A-Za-z0-9._-]{1,64}$" (toString $da.projectId)) }}{{ fail "runtime.durableActors.projectId must match [A-Za-z0-9._-]{1,64}" }}{{ end -}}
{{- if not (regexMatch "^[A-Za-z0-9._-]{1,64}$" (toString $da.organizationId)) }}{{ fail "runtime.durableActors.organizationId must match [A-Za-z0-9._-]{1,64}" }}{{ end -}}
{{- if $da.controlPlaneUrl }}{{ if not (regexMatch "^https?://[^/?#@]+$" $da.controlPlaneUrl) }}{{ fail "runtime.durableActors.controlPlaneUrl must be an http(s) origin with no path" }}{{ end }}{{ end -}}
{{- if ne (dig "format" "legacy" (.Values.credentials | default dict)) "ar" }}{{ fail "runtime.backend=durable-actors requires credentials.format=ar: the actor runtime mints and accepts only ar_ credentials" }}{{ end -}}
{{- if not .Values.secretKeys.credentialKeyring }}{{ fail "runtime.backend=durable-actors requires secretKeys.credentialKeyring: the gateway routes by the keyring-signed ar_ tag" }}{{ end -}}
{{- if not $da.fileSigningSecretKey }}{{ fail "runtime.durableActors.fileSigningSecretKey is required (RELAYCAST_FILE_SIGNING_SECRET)" }}{{ end -}}
{{- if .Values.backup.enabled }}{{ fail "backup.enabled backs up the SQLite volume; runtime.backend=durable-actors keeps state in actors (back up the durable-actors bucket and Postgres instead)" }}{{ end -}}
{{- if or (not (kindIs "invalid" .Values.retention.messageTtlDays)) (not (kindIs "invalid" .Values.mailbox.ttlMs)) (not (kindIs "invalid" .Values.mailbox.depthCap)) }}{{ fail "retention.* and mailbox.* configure the SQLite image; with runtime.backend=durable-actors set RELAYCAST_MESSAGE_TTL_DAYS / RELAYCAST_MAILBOX_* in the actor env Secret" }}{{ end -}}
{{- if not (kindIs "bool" .Values.bootstrapProofRequired) }}{{ fail "bootstrapProofRequired must be true or false" }}{{ end -}}
{{- if and .Values.bootstrapProofRequired (not .Values.secretKeys.workspaceBootstrapSecret) }}{{ fail "bootstrapProofRequired=true with runtime.backend=durable-actors requires secretKeys.workspaceBootstrapSecret (the proof is checked against it)" }}{{ end -}}
{{- if not (has $driver (list "local" "gcs" "s3")) }}{{ fail "runtime.durableActors.fileStore.driver must be local, gcs or s3" }}{{ end -}}
{{- if and (ne $driver "local") (not $fs.bucket) }}{{ fail (printf "runtime.durableActors.fileStore.bucket is required for driver %s" $driver) }}{{ end -}}
{{- if or (not (include "relaycast.isInt" $da.gateway.replicaCount)) (lt ($da.gateway.replicaCount | int64) 1) }}{{ fail "runtime.durableActors.gateway.replicaCount must be a positive integer" }}{{ end -}}
{{- if and (eq $driver "local") (gt (int $da.gateway.replicaCount) 1) }}{{ fail "runtime.durableActors.gateway.replicaCount > 1 requires fileStore.driver gcs or s3: the local file store is one RWO volume" }}{{ end -}}
{{- if lt (int $da.gateway.replicaCount) 1 }}{{ fail "runtime.durableActors.gateway.replicaCount must be >= 1" }}{{ end -}}
{{- if or (not (include "relaycast.isInt" $da.maxUploadBytes)) (lt ($da.maxUploadBytes | int64) 1) }}{{ fail "runtime.durableActors.maxUploadBytes must be a positive integer (and equal the actor's RELAYCAST_MAX_UPLOAD_BYTES)" }}{{ end -}}
{{- if or (not (include "relaycast.isInt" $da.shutdownGraceMs)) (lt ($da.shutdownGraceMs | int64) 0) }}{{ fail "runtime.durableActors.shutdownGraceMs must be a non-negative integer" }}{{ end -}}
{{- $reserved := include "relaycast.actors.reservedEnv" . | fromJsonArray -}}
{{- range .Values.extraEnv }}{{ if has (toString .name) $reserved }}{{ fail (printf "%s is set by the durable-actors gateway and must not appear in extraEnv" .name) }}{{ end }}{{ end -}}
{{- if not (has (toString $da.logFormat) (list "json" "text")) }}{{ fail "runtime.durableActors.logFormat must be json or text" }}{{ end -}}
{{- if $da.devRuntime.enabled -}}
{{- if not $da.devRuntime.acknowledgeNonProduction }}{{ fail "runtime.durableActors.devRuntime.enabled requires devRuntime.acknowledgeNonProduction=true: the dev runtime is single-process with local state and its key sits in the gateway pod" }}{{ end -}}
{{- if not $da.devRuntime.secretKey }}{{ fail "runtime.durableActors.devRuntime.secretKey is required: the dev runtime must not run unauthenticated" }}{{ end -}}
{{- if $da.controlPlaneUrl }}{{ fail "runtime.durableActors.controlPlaneUrl must be empty with devRuntime (the sidecar is the control plane)" }}{{ end -}}
{{- if gt (int $da.gateway.replicaCount) 1 }}{{ fail "runtime.durableActors.devRuntime forces one gateway replica" }}{{ end -}}
{{- else -}}
{{- if .Values.allowInsecureBaseUrl }}{{ fail "runtime.backend=durable-actors requires an HTTPS public baseUrl: actors fetch RELAYCAST_PUBLIC_URL from the sandbox, whose NetworkPolicy blocks private ranges (allowInsecureBaseUrl is only allowed with devRuntime)" }}{{ end -}}
{{- if not $da.invocationSecret.name }}{{ fail "runtime.durableActors.invocationSecret.name is required: the gateway's DURABLE_ACTORS_SECRET lives in its own Secret" }}{{ end -}}
{{- if not $da.invocationSecret.key }}{{ fail "runtime.durableActors.invocationSecret.key is required" }}{{ end -}}
{{- if not (has (toString $da.invocationSecret.scope) (list "admin" "invoke-only")) }}{{ fail "runtime.durableActors.invocationSecret.scope must be admin or invoke-only" }}{{ end -}}
{{- if eq $da.invocationSecret.name $da.adminKeySecret.name }}{{ fail "runtime.durableActors.invocationSecret must not be the admin key Secret (adminKeySecret): the internet-facing gateway must never mount the deployer's admin api-key Secret" }}{{ end -}}
{{- if eq $da.invocationSecret.name .Values.existingSecret }}{{ fail "runtime.durableActors.invocationSecret must be its own Secret, not existingSecret, so an invoke-only key is a values change only" }}{{ end -}}
{{- if $da.deployer.enabled -}}
{{- if or (not $da.adminKeySecret.name) (not $da.adminKeySecret.key) }}{{ fail "runtime.durableActors.adminKeySecret.name and .key are required for the deployer" }}{{ end -}}
{{- if or (not (include "relaycast.isInt" $da.deployer.activeDeadlineSeconds)) (lt ($da.deployer.activeDeadlineSeconds | int64) 1) }}{{ fail "runtime.durableActors.deployer.activeDeadlineSeconds must be a positive integer" }}{{ end -}}
{{- if not $da.deployer.artifactBucket }}{{ fail "runtime.durableActors.deployer.artifactBucket is required when the deployer is enabled (the durable-actors storage.bucket)" }}{{ end -}}
{{- if not $da.actorEnvSecrets }}{{ fail "runtime.durableActors.actorEnvSecrets is required: the actor needs RELAYCAST_PUBLIC_URL and RELAYCAST_FILE_SIGNING_SECRET from a terse.ai/customer-secret Secret" }}{{ end -}}
{{- range $da.actorEnvSecrets }}{{ if not (regexMatch "^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$" (toString .)) }}{{ fail "runtime.durableActors.actorEnvSecrets entries must be Kubernetes Secret names" }}{{ end }}{{ end -}}
{{- end -}}
{{- end -}}
{{- end }}

{{- define "relaycast.actors.secretEnv" -}}
- name: {{ .name }}
  valueFrom:
    secretKeyRef:
      name: {{ .secret | quote }}
      key: {{ .key | quote }}
{{- end }}

{{/*
Keyed workspace creates (Idempotency-Key). The gateway and every actor must
read the same bytes: the gateway derives the actor id from the secret and the
actor's engine derives the replayed credential from it. Both read it as a
plain env var from a Secret key (no _FILE, whose loader drops one trailing
newline), so the gateway's existingSecret key and the actor env Secret's
RELAYCAST_WORKSPACE_BOOTSTRAP_SECRET must hold identical bytes. Unset: a
keyed create answers 503 workspace_create_idempotency_unavailable.
*/}}
{{- define "relaycast.actors.bootstrapEnv" -}}
{{- with .Values.secretKeys.workspaceBootstrapSecret }}
{{ include "relaycast.actors.secretEnv" (dict "name" "RELAYCAST_WORKSPACE_BOOTSTRAP_SECRET" "secret" $.Values.existingSecret "key" .) }}
{{- end }}
- name: RELAYCAST_WORKSPACE_BOOTSTRAP_PROOF_REQUIRED
  value: {{ ternary "true" "false" .Values.bootstrapProofRequired | quote }}
{{- end }}

{{/* Gateway env (contract v1). */}}
{{- define "relaycast.actors.gatewayEnv" -}}
{{- $da := .Values.runtime.durableActors -}}
{{- $fs := $da.fileStore -}}
- name: PORT
  value: {{ .Values.server.port | quote }}
- name: DURABLE_ACTORS_CONTROL_PLANE_URL
  value: {{ include "relaycast.actors.controlPlaneUrl" . | quote }}
- name: DURABLE_ACTORS_PROJECT_ID
  value: {{ $da.projectId | quote }}
{{- if include "relaycast.actors.dev" . }}
{{ include "relaycast.actors.secretEnv" (dict "name" "DURABLE_ACTORS_SECRET" "secret" .Values.existingSecret "key" $da.devRuntime.secretKey) }}
{{- else }}
{{ include "relaycast.actors.secretEnv" (dict "name" "DURABLE_ACTORS_SECRET" "secret" $da.invocationSecret.name "key" $da.invocationSecret.key) }}
{{- end }}
{{- with $da.homeRegion }}
- name: DURABLE_ACTORS_HOME_REGION
  value: {{ . | quote }}
{{- end }}
{{ include "relaycast.actors.secretEnv" (dict "name" "RELAYCAST_FILE_SIGNING_SECRET" "secret" .Values.existingSecret "key" $da.fileSigningSecretKey) }}
- name: RELAYCAST_CREDENTIAL_KEYRING_FILE
  value: {{ include "relaycast.secretMountPath" . }}/credential-keyring
- name: RELAYCAST_INTERNAL_SECRET_FILE
  value: {{ include "relaycast.secretMountPath" . }}/internal-secret
- name: RELAYCAST_PUBLIC_WORKSPACE_CREATE
  value: {{ ternary "true" "false" .Values.publicWorkspaceCreate | quote }}
{{- include "relaycast.actors.bootstrapEnv" . }}
- name: RELAYCAST_FILE_STORE
  value: {{ $fs.driver | quote }}
{{- if eq (toString $fs.driver) "local" }}
- name: RELAYCAST_FILE_DIR
  value: {{ $fs.dir | quote }}
{{- else if eq (toString $fs.driver) "gcs" }}
- name: RELAYCAST_GCS_BUCKET
  value: {{ $fs.bucket | quote }}
{{- with $fs.prefix }}
- name: RELAYCAST_GCS_PREFIX
  value: {{ . | quote }}
{{- end }}
{{- else }}
- name: RELAYCAST_S3_BUCKET
  value: {{ $fs.bucket | quote }}
- name: RELAYCAST_S3_REGION
  value: {{ $fs.s3.region | quote }}
{{- with $fs.s3.endpoint }}
- name: RELAYCAST_S3_ENDPOINT
  value: {{ . | quote }}
{{- end }}
{{- with $fs.prefix }}
- name: RELAYCAST_S3_PREFIX
  value: {{ . | quote }}
{{- end }}
- name: RELAYCAST_S3_FORCE_PATH_STYLE
  value: {{ $fs.s3.forcePathStyle | toString | quote }}
{{- with $fs.s3.existingSecret }}
{{ include "relaycast.actors.secretEnv" (dict "name" "AWS_ACCESS_KEY_ID" "secret" . "key" "AWS_ACCESS_KEY_ID") }}
{{ include "relaycast.actors.secretEnv" (dict "name" "AWS_SECRET_ACCESS_KEY" "secret" . "key" "AWS_SECRET_ACCESS_KEY") }}
{{- end }}
{{- end }}
- name: RELAYCAST_MAX_UPLOAD_BYTES
  value: {{ $da.maxUploadBytes | int64 | toString | quote }}
- name: RELAYCAST_SHUTDOWN_GRACE_MS
  value: {{ $da.shutdownGraceMs | int64 | toString | quote }}
- name: RELAYCAST_LOG_FORMAT
  value: {{ $da.logFormat | quote }}
- name: RELAYCAST_ENV
  value: {{ .Values.server.environment | quote }}
{{- with .Values.extraEnv }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/*
Dev sidecar env: in `durable-actors dev`, actors inherit the process env, so
the actor env contract (normally the terse.ai/customer-secret Secret) is set
on the sidecar.
*/}}
{{- define "relaycast.actors.devEnv" -}}
{{- $da := .Values.runtime.durableActors -}}
- name: DURABLE_ACTORS_PORT
  value: {{ $da.devRuntime.port | quote }}
- name: DURABLE_ACTORS_PROJECT_ID
  value: {{ $da.projectId | quote }}
- name: DURABLE_ACTORS_DATA_DIR
  value: /data
- name: HOME
  value: /tmp
{{ include "relaycast.actors.secretEnv" (dict "name" "DURABLE_ACTORS_SECRET" "secret" .Values.existingSecret "key" $da.devRuntime.secretKey) }}
- name: RELAYCAST_PUBLIC_URL
  value: {{ .Values.baseUrl | quote }}
{{ include "relaycast.actors.secretEnv" (dict "name" "RELAYCAST_FILE_SIGNING_SECRET" "secret" .Values.existingSecret "key" $da.fileSigningSecretKey) }}
{{ include "relaycast.actors.secretEnv" (dict "name" "RELAYCAST_INTERNAL_SECRET" "secret" .Values.existingSecret "key" .Values.secretKeys.internalSecret) }}
{{- include "relaycast.actors.bootstrapEnv" . }}
- name: RELAYCAST_MAX_UPLOAD_BYTES
  value: {{ $da.maxUploadBytes | int64 | toString | quote }}
- name: RELAYCAST_ENV
  value: {{ .Values.server.environment | quote }}
{{- end }}

{{/* Deployer env (contract v1): the only consumer of the admin api-key. */}}
{{- define "relaycast.actors.deployerEnv" -}}
{{- $da := .Values.runtime.durableActors -}}
- name: DURABLE_ACTORS_CONTROL_PLANE_URL
  value: {{ include "relaycast.actors.controlPlaneUrl" . | quote }}
- name: DURABLE_ACTORS_PROJECT_ID
  value: {{ $da.projectId | quote }}
- name: DURABLE_ACTORS_ORGANIZATION_ID
  value: {{ $da.organizationId | quote }}
{{ include "relaycast.actors.secretEnv" (dict "name" "DURABLE_ACTORS_SECRET" "secret" $da.adminKeySecret.name "key" $da.adminKeySecret.key) }}
- name: DURABLE_ACTORS_ARTIFACT_BUCKET
  value: {{ $da.deployer.artifactBucket | quote }}
{{- include "relaycast.actors.artifactStoreEnv" $da.deployer.artifactStore }}
- name: DURABLE_ACTORS_SECRET_REFS
  value: {{ join "," $da.actorEnvSecrets | quote }}
- name: HOME
  value: /tmp
{{- end }}

{{/* Deployer artifact store: S3 variables only in s3 mode (the deployer rejects them otherwise). */}}
{{- define "relaycast.actors.artifactStoreEnv" -}}
{{- $store := . | default dict -}}
{{- $driver := $store.driver | default "gcs" -}}
{{- if not (has $driver (list "gcs" "s3")) }}{{ fail "runtime.durableActors.deployer.artifactStore.driver must be gcs or s3" }}{{ end -}}
{{- if eq $driver "s3" }}
{{- if not $store.s3.region }}{{ fail "runtime.durableActors.deployer.artifactStore.s3.region is required for driver s3" }}{{ end }}
- name: DURABLE_ACTORS_ARTIFACT_STORE
  value: s3
- name: DURABLE_ACTORS_S3_REGION
  value: {{ $store.s3.region | quote }}
{{- with $store.s3.endpoint }}
- name: DURABLE_ACTORS_S3_ENDPOINT
  value: {{ . | quote }}
{{- end }}
- name: DURABLE_ACTORS_S3_FORCE_PATH_STYLE
  value: {{ $store.s3.forcePathStyle | default false | toString | quote }}
{{- end }}
{{- end }}
