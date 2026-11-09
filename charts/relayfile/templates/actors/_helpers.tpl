{{/*
Relayfile on TerseAI durable-actors (runtime.backend=durable-actors).
Env contract: docs/self-hosted-durable-actors.md ("Relayfile env contract").
*/}}

{{/* "true" when the value is an integer (YAML numbers arrive as float64). */}}
{{- define "relayfile.isInt" -}}
{{- $v := . -}}
{{- if or (kindIs "int" $v) (kindIs "int64" $v) (and (kindIs "float64" $v) (eq ($v | int64 | float64) $v)) }}true{{ end -}}
{{- end }}

{{- define "relayfile.actors.enabled" -}}
{{- if eq (toString .Values.runtime.backend) "durable-actors" }}true{{ end -}}
{{- end }}

{{- define "relayfile.actors.dev" -}}
{{- if and (include "relayfile.actors.enabled" .) .Values.runtime.durableActors.devRuntime.enabled }}true{{ end -}}
{{- end }}

{{- define "relayfile.actors.brokerName" -}}
{{- printf "%s-session-broker" (include "relayfile.fullname" . | trunc 48 | trimSuffix "-") -}}
{{- end }}

{{- define "relayfile.actors.deployerName" -}}
{{- printf "%s-actors-deploy" (include "relayfile.fullname" . | trunc 45 | trimSuffix "-") -}}
{{- end }}

{{/*
Deploy Job name: <deployerName>-<8-hex pod-template hash>. The Job name is
copied into the pod's job-name label (max 63 characters), so the prefix is cut
to 54 before the 9-character suffix. Short names are unchanged.
*/}}
{{- define "relayfile.actors.deployJobName" -}}
{{- printf "%s-%s" (include "relayfile.actors.deployerName" .root | trunc 54 | trimSuffix "-") .hash -}}
{{- end }}

{{/*
The durable-actors control-plane Service name. Must equal the vendored chart's
`actors.name` (`<release>-durable-actors`, truncated to 63 as a whole).
*/}}
{{- define "relayfile.actors.controlPlaneServiceName" -}}
{{- printf "%s-durable-actors" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end }}

{{/* Env names the actor gateway sets itself; extraEnv must not repeat them. */}}
{{- define "relayfile.actors.reservedEnv" -}}
{{- list "PORT" "DURABLE_ACTORS_CONTROL_PLANE_URL" "DURABLE_ACTORS_PROJECT_ID" "DURABLE_ACTORS_SECRET" "RELAYFILE_ACTORS_ALLOW_ADMIN_KEY" "RELAYFILE_ACTORS_BROKER_URL" "RELAYFILE_ACTORS_BROKER_TOKEN" "RELAYFILE_JWT_SECRET" "RELAYAUTH_JWKS_URL" "RELAYFILE_INTERNAL_HMAC_SECRET" "RELAYFILE_BLOB_STORE" "RELAYFILE_BLOB_BUCKET" "RELAYFILE_BLOB_PREFIX" "RELAYFILE_BLOB_INLINE_MAX_BYTES" "RELAYFILE_S3_ENDPOINT" "RELAYFILE_S3_REGION" "RELAYFILE_S3_FORCE_PATH_STYLE" "AWS_ACCESS_KEY_ID" "AWS_SECRET_ACCESS_KEY" | toJson -}}
{{- end }}

{{/* image reference: repository@digest, else repository:tag. */}}
{{- define "relayfile.actors.imageRef" -}}
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

{{- define "relayfile.actors.controlPlaneUrl" -}}
{{- $ta := .Values.runtime.durableActors -}}
{{- if include "relayfile.actors.dev" . -}}
{{- printf "http://127.0.0.1:%d" ($ta.devRuntime.port | int) -}}
{{- else if $ta.controlPlaneUrl -}}
{{- $ta.controlPlaneUrl -}}
{{- else -}}
{{- printf "http://%s.%s.svc.cluster.local:7100" (include "relayfile.actors.controlPlaneServiceName" .) .Release.Namespace -}}
{{- end -}}
{{- end }}

{{- define "relayfile.actors.validate" -}}
{{- $backend := toString .Values.runtime.backend -}}
{{- if not (has $backend (list "go" "durable-actors")) }}{{ fail "runtime.backend must be go or durable-actors" }}{{ end -}}
{{- if include "relayfile.actors.enabled" . -}}
{{- $ta := .Values.runtime.durableActors -}}
{{- if not $ta.existingSecret }}{{ fail "runtime.durableActors.existingSecret is required when runtime.backend=durable-actors" }}{{ end -}}
{{- if .Values.secrets.existingSecret }}{{ fail "secrets.* configure the Go server; with runtime.backend=durable-actors use runtime.durableActors.existingSecret" }}{{ end -}}
{{- if or .Values.secrets.productionDsn .Values.secrets.internalHmacSecret .Values.secrets.jwtSecret .Values.providers.notion.token }}{{ fail "inline secrets.* and providers.notion.token are Go-server values; runtime.backend=durable-actors reads only runtime.durableActors.existingSecret" }}{{ end -}}
{{- if not (regexMatch "^[A-Za-z0-9._-]{1,64}$" (toString $ta.projectId)) }}{{ fail "runtime.durableActors.projectId must match [A-Za-z0-9._-]{1,64}" }}{{ end -}}
{{- if not (regexMatch "^[A-Za-z0-9._-]{1,64}$" (toString $ta.organizationId)) }}{{ fail "runtime.durableActors.organizationId must match [A-Za-z0-9._-]{1,64}" }}{{ end -}}
{{- if and (not $ta.secretKeys.jwtSecret) (not .Values.auth.jwksUrl) }}{{ fail "runtime.durableActors.secretKeys.jwtSecret or auth.jwksUrl is required: the gateway must verify workspace tokens" }}{{ end -}}
{{- if $ta.controlPlaneUrl }}{{ if not (regexMatch "^https?://[^/?#@]+$" $ta.controlPlaneUrl) }}{{ fail "runtime.durableActors.controlPlaneUrl must be an http(s) origin with no path" }}{{ end }}{{ end -}}
{{- $driver := toString $ta.blobStore.driver -}}
{{- if not (has $driver (list "gcs" "s3" "inline")) }}{{ fail "runtime.durableActors.blobStore.driver must be gcs, s3 or inline" }}{{ end -}}
{{- if and (ne $driver "inline") (not $ta.blobStore.bucket) }}{{ fail (printf "runtime.durableActors.blobStore.bucket is required for driver %s" $driver) }}{{ end -}}
{{- if or (not (include "relayfile.isInt" $ta.blobStore.inlineMaxBytes)) (lt ($ta.blobStore.inlineMaxBytes | int64) 0) }}{{ fail "runtime.durableActors.blobStore.inlineMaxBytes must be a non-negative integer" }}{{ end -}}
{{- $reserved := include "relayfile.actors.reservedEnv" . | fromJsonArray -}}
{{- range .Values.extraEnv }}{{ if has (toString .name) $reserved }}{{ fail (printf "%s is set by the durable-actors gateway and must not appear in extraEnv" .name) }}{{ end }}{{ end -}}
{{- if $ta.devRuntime.enabled -}}
{{- if not $ta.devRuntime.acknowledgeNonProduction }}{{ fail "runtime.durableActors.devRuntime.enabled requires devRuntime.acknowledgeNonProduction=true: the dev runtime is single-process with local state and holds the admin key in the gateway pod" }}{{ end -}}
{{- if .Values.autoscaling.enabled }}{{ fail "runtime.durableActors.devRuntime forces one replica; disable autoscaling" }}{{ end -}}
{{- if not $ta.devRuntime.secretKey }}{{ fail "runtime.durableActors.devRuntime.secretKey is required: the dev runtime must not run unauthenticated" }}{{ end -}}
{{- if $ta.controlPlaneUrl }}{{ fail "runtime.durableActors.controlPlaneUrl must be empty with devRuntime (the sidecar is the control plane)" }}{{ end -}}
{{- else -}}
{{- if eq $driver "inline" }}{{ fail "runtime.durableActors.blobStore.driver=inline is only allowed with devRuntime: file bytes would live in actor SQLite" }}{{ end -}}
{{- if not $ta.secretKeys.brokerToken }}{{ fail "runtime.durableActors.secretKeys.brokerToken is required: the gateway gets actor sessions from the session broker" }}{{ end -}}
{{- if or (not $ta.adminKeySecret.name) (not $ta.adminKeySecret.key) }}{{ fail "runtime.durableActors.adminKeySecret.name and .key are required (the durable-actors api-key, read only by the session broker and the deploy Job)" }}{{ end -}}
{{- if eq $ta.adminKeySecret.name $ta.existingSecret }}{{ fail "runtime.durableActors.adminKeySecret must be a different Secret from runtime.durableActors.existingSecret: the gateway mounts existingSecret and must never be able to read the admin api-key" }}{{ end -}}
{{- if or (not (include "relayfile.isInt" $ta.gateway.replicaCount)) (lt ($ta.gateway.replicaCount | int64) 1) }}{{ fail "runtime.durableActors.gateway.replicaCount must be a positive integer" }}{{ end -}}
{{- if not $ta.image.digest }}{{ fail "runtime.durableActors.image.digest is required (image tags are only allowed with devRuntime)" }}{{ end -}}
{{- if and $ta.deployer.enabled (not $ta.workspaceImage.digest) }}{{ fail "runtime.durableActors.workspaceImage.digest is required for the deploy Job (image tags are only allowed with devRuntime)" }}{{ end -}}
{{- if or (not (include "relayfile.isInt" $ta.deployer.activeDeadlineSeconds)) (lt ($ta.deployer.activeDeadlineSeconds | int64) 1) }}{{ fail "runtime.durableActors.deployer.activeDeadlineSeconds must be a positive integer" }}{{ end -}}
{{- if and $ta.deployer.enabled (not $ta.deployer.artifactBucket) }}{{ fail "runtime.durableActors.deployer.artifactBucket is required when the deployer is enabled (the durable-actors storage.bucket)" }}{{ end -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/* One secretKeyRef env entry. */}}
{{- define "relayfile.actors.secretEnv" -}}
- name: {{ .name }}
  valueFrom:
    secretKeyRef:
      name: {{ .secret | quote }}
      key: {{ .key | quote }}
{{- end }}

{{/*
Gateway env: the single place the relayfile actor-mode env contract is wired.
*/}}
{{- define "relayfile.actors.gatewayEnv" -}}
{{- $ta := .Values.runtime.durableActors -}}
{{- $bs := $ta.blobStore -}}
- name: PORT
  value: {{ .Values.server.port | quote }}
- name: DURABLE_ACTORS_CONTROL_PLANE_URL
  value: {{ include "relayfile.actors.controlPlaneUrl" . | quote }}
- name: DURABLE_ACTORS_PROJECT_ID
  value: {{ $ta.projectId | quote }}
{{- if include "relayfile.actors.dev" . }}
{{ include "relayfile.actors.secretEnv" (dict "name" "DURABLE_ACTORS_SECRET" "secret" $ta.existingSecret "key" $ta.devRuntime.secretKey) }}
- name: RELAYFILE_ACTORS_ALLOW_ADMIN_KEY
  value: "true"
{{- else }}
- name: RELAYFILE_ACTORS_BROKER_URL
  value: {{ printf "http://%s:%d" (include "relayfile.actors.brokerName" .) ($ta.broker.port | int) | quote }}
{{ include "relayfile.actors.secretEnv" (dict "name" "RELAYFILE_ACTORS_BROKER_TOKEN" "secret" $ta.existingSecret "key" $ta.secretKeys.brokerToken) }}
{{- end }}
{{- if $ta.secretKeys.jwtSecret }}
{{ include "relayfile.actors.secretEnv" (dict "name" "RELAYFILE_JWT_SECRET" "secret" $ta.existingSecret "key" $ta.secretKeys.jwtSecret) }}
{{- if .Values.auth.jwksUrl }}
      # auth.jwksUrl verifies tokens; the HS256 secret is then optional.
      optional: true
{{- end }}
{{- end }}
{{- if .Values.auth.jwksUrl }}
- name: RELAYAUTH_JWKS_URL
  value: {{ .Values.auth.jwksUrl | quote }}
{{- end }}
{{- if $ta.secretKeys.internalHmacSecret }}
{{ include "relayfile.actors.secretEnv" (dict "name" "RELAYFILE_INTERNAL_HMAC_SECRET" "secret" $ta.existingSecret "key" $ta.secretKeys.internalHmacSecret) }}
{{- end }}
- name: RELAYFILE_BLOB_STORE
  value: {{ $bs.driver | quote }}
{{- if ne (toString $bs.driver) "inline" }}
- name: RELAYFILE_BLOB_BUCKET
  value: {{ $bs.bucket | quote }}
- name: RELAYFILE_BLOB_PREFIX
  value: {{ $bs.prefix | quote }}
{{- end }}
- name: RELAYFILE_BLOB_INLINE_MAX_BYTES
  value: {{ $bs.inlineMaxBytes | int | quote }}
{{- if eq (toString $bs.driver) "s3" }}
{{- if $bs.s3.endpoint }}
- name: RELAYFILE_S3_ENDPOINT
  value: {{ $bs.s3.endpoint | quote }}
{{- end }}
- name: RELAYFILE_S3_REGION
  value: {{ $bs.s3.region | quote }}
- name: RELAYFILE_S3_FORCE_PATH_STYLE
  value: {{ $bs.s3.forcePathStyle | toString | quote }}
{{- if $bs.s3.existingSecret }}
{{ include "relayfile.actors.secretEnv" (dict "name" "AWS_ACCESS_KEY_ID" "secret" $bs.s3.existingSecret "key" "AWS_ACCESS_KEY_ID") }}
{{ include "relayfile.actors.secretEnv" (dict "name" "AWS_SECRET_ACCESS_KEY" "secret" $bs.s3.existingSecret "key" "AWS_SECRET_ACCESS_KEY") }}
{{- end }}
{{- end }}
{{- with .Values.extraEnv }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/* Admin-key consumers (broker, deploy Job): control plane + admin api-key. */}}
{{- define "relayfile.actors.adminEnv" -}}
{{- $ta := .Values.runtime.durableActors -}}
- name: DURABLE_ACTORS_CONTROL_PLANE_URL
  value: {{ include "relayfile.actors.controlPlaneUrl" . | quote }}
- name: DURABLE_ACTORS_PROJECT_ID
  value: {{ $ta.projectId | quote }}
{{ include "relayfile.actors.secretEnv" (dict "name" "DURABLE_ACTORS_SECRET" "secret" $ta.adminKeySecret.name "key" $ta.adminKeySecret.key) }}
{{- end }}

{{- define "relayfile.actors.brokerSelectorLabels" -}}
{{ include "relayfile.selectorLabels" . }}
app.kubernetes.io/component: session-broker
{{- end }}

{{/* Deployer artifact store: S3 variables only in s3 mode. */}}
{{- define "relayfile.actors.artifactStoreEnv" -}}
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
