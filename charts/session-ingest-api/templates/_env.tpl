{{/*
Tenant org id: tenant.orgId, else global.tenant.orgId (set once by an umbrella).
*/}}
{{- define "alleyoop.orgId" -}}
{{- .Values.tenant.orgId | default (dig "tenant" "orgId" "" (.Values.global | default dict)) -}}
{{- end }}

{{/*
Fail early on missing required values (render time, not crash-loop time).
*/}}
{{- define "alleyoop.validate" -}}
{{- if not (kindIs "map" .Values.deployment) }}{{ fail "deployment must be an object with boolean deployment.enabled" }}{{ end -}}
{{- if not (kindIs "bool" .Values.deployment.enabled) }}{{ fail "deployment.enabled must be a boolean" }}{{ end -}}
{{- $credentialsMode := .Values.locker.credentials.mode | default "secret" -}}
{{- if not (or (eq $credentialsMode "secret") (eq $credentialsMode "podIdentity")) }}{{ fail "alleyoop: locker.credentials.mode must be secret or podIdentity" }}{{ end -}}
{{- if and (eq $credentialsMode "secret") (not .Values.existingSecret) }}{{ fail "alleyoop: existingSecret is required when locker.credentials.mode=secret" }}{{ end -}}
{{- if and (not .Values.hoopdb.existingSecret) (not .Values.existingSecret) }}{{ fail "alleyoop: hoopdb.existingSecret or existingSecret is required for HOOPDB_URL" }}{{ end -}}
{{- if and (eq $credentialsMode "secret") (not .Values.locker.endpoint) }}{{ fail "alleyoop: locker.endpoint is required when locker.credentials.mode=secret" }}{{ end -}}
{{- if not (include "alleyoop.orgId" .) }}{{ fail "alleyoop: tenant.orgId (or global.tenant.orgId) is required" }}{{ end -}}
{{- if and .Values.auth.jwksUrl .Values.auth.localJwks }}{{ fail "alleyoop: set auth.jwksUrl OR auth.localJwks, not both" }}{{ end -}}
{{- if not (or .Values.auth.jwksUrl .Values.auth.localJwks) }}{{ fail "alleyoop: set auth.jwksUrl (RelayAuth JWKS) or auth.localJwks=true (JWKS JSON from existingSecret, local/kind only)" }}{{ end -}}
{{- if and .Values.auth.localJwks (not .Values.existingSecret) }}{{ fail "alleyoop: existingSecret is required when auth.localJwks=true" }}{{ end -}}
{{- if not (kindIs "bool" .Values.auth.allowInterimRelayAuthBearer) }}{{ fail "alleyoop: auth.allowInterimRelayAuthBearer must be a boolean" }}{{ end -}}
{{- if and .Values.auth.allowInterimRelayAuthBearer (ne .Values.environment "local") }}{{ fail "alleyoop: auth.allowInterimRelayAuthBearer=true is allowed only when environment=local" }}{{ end -}}
{{- if and (not (kindIs "invalid" .Values.readerMaxRuleset)) (not (has (toString .Values.readerMaxRuleset) (list "8" "9" "10"))) }}{{ fail "alleyoop: readerMaxRuleset must be one of 8, 9, or 10" }}{{ end -}}
{{- range $entry := .Values.extraEnv }}
{{- if eq ($entry.name | default "") "ALLOW_INTERIM_RELAYAUTH_BEARER" }}{{ fail "alleyoop: configure auth.allowInterimRelayAuthBearer instead of extraEnv" }}{{ end -}}
{{- if eq ($entry.name | default "") "READER_MAX_RULESET" }}{{ fail "alleyoop: configure readerMaxRuleset instead of extraEnv" }}{{ end -}}
{{- if has ($entry.name | default "") (list "SCRUB_ENGINE" "SCRUB_ENGINE_REQUIRED") }}{{ fail (printf "alleyoop: configure global.scrubEngine instead of extraEnv %s" $entry.name) }}{{ end -}}
{{- end -}}
{{- range $entry := .Values.ingest.env }}
{{- if eq ($entry.name | default "") "ALLOW_INTERIM_RELAYAUTH_BEARER" }}{{ fail "alleyoop: configure auth.allowInterimRelayAuthBearer instead of ingest.env" }}{{ end -}}
{{- if eq ($entry.name | default "") "READER_MAX_RULESET" }}{{ fail "alleyoop: configure readerMaxRuleset instead of ingest.env" }}{{ end -}}
{{- if has ($entry.name | default "") (list "SCRUB_ENGINE" "SCRUB_ENGINE_REQUIRED") }}{{ fail (printf "alleyoop: configure global.scrubEngine instead of ingest.env %s" $entry.name) }}{{ end -}}
{{- end -}}
{{- if not (has (toString .Values.allowInClusterHttp) (list "true" "false")) }}{{ fail "alleyoop: allowInClusterHttp must be true or false" }}{{ end -}}
{{- with .Values.auth.historyOrigin }}
{{- $origin := toString . -}}
{{- $originError := "alleyoop: auth.historyOrigin must be a bare origin http(s)://host[:port]: a DNS hostname of RFC 1123 labels, an optional port 1-65535, and no path, query, fragment or credentials" -}}
{{- if not (regexMatch "^https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?$" $origin) }}{{ fail $originError }}{{ end -}}
{{- $originHost := (urlParse $origin).hostname -}}
{{- if or (gt (len $originHost) 253) (not (regexMatch "^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$" $originHost)) }}{{ fail $originError }}{{ end -}}
{{- $originPort := regexFind ":[0-9]+$" $origin -}}
{{- if and $originPort (or (lt (int (trimPrefix ":" $originPort)) 1) (gt (int (trimPrefix ":" $originPort)) 65535)) }}{{ fail $originError }}{{ end -}}
{{- end -}}
{{- include "alleyoop.validatePostgresCa" . -}}
{{- $ingestEnvNames := list -}}
{{- range concat (.Values.extraEnv | default list) (.Values.ingest.env | default list) }}{{ $ingestEnvNames = append $ingestEnvNames (.name | default "") }}{{ end -}}
{{- if has "ALLOW_IN_CLUSTER_HTTP" $ingestEnvNames }}{{ fail "alleyoop: extraEnv/ingest.env must not set ALLOW_IN_CLUSTER_HTTP: use allowInClusterHttp" }}{{ end -}}
{{- if and .Values.auth.historyOrigin (has "RELAYHISTORY_ORIGIN" $ingestEnvNames) }}{{ fail "alleyoop: set RELAYHISTORY_ORIGIN through auth.historyOrigin or extraEnv/ingest.env, not both" }}{{ end -}}
{{- include "alleyoop.validateLocker" . }}
{{- end }}

{{/*
Locker provider validation; runs last so the other value checks report first.
*/}}
{{- define "alleyoop.validateLocker" -}}
{{- $credentialsMode := .Values.locker.credentials.mode | default "secret" -}}
{{- /* Locker provider. The services image selects S3 (unset LOCKER_PROVIDER) or
native GCS (LOCKER_PROVIDER=gcs, Workload Identity through the GKE metadata
server). It refuses HMAC keys on GCS and refuses the S3 client against a
Google Cloud Storage endpoint, so both shapes fail here at render time. */ -}}
{{- $provider := .Values.locker.provider | default "s3" -}}
{{- if not (has $provider (list "s3" "gcs")) }}{{ fail "alleyoop: locker.provider must be s3 or gcs" }}{{ end -}}
{{- $gcs := eq $provider "gcs" -}}
{{- $extraEnvNames := list -}}
{{- range .Values.extraEnv }}{{ $extraEnvNames = append $extraEnvNames (.name | default "") }}{{ end -}}
{{- $endpointHost := "" -}}
{{- if .Values.locker.endpoint }}{{ $endpointHost = (urlParse .Values.locker.endpoint).hostname | lower }}{{ end -}}
{{- if and (not $gcs) (or (eq $endpointHost "storage.googleapis.com") (hasSuffix ".storage.googleapis.com" $endpointHost) (eq $endpointHost "storage.google.com")) }}{{ fail "alleyoop: locker.endpoint is a Google Cloud Storage endpoint: set locker.provider=gcs (the services refuse GCS through the S3 client and HMAC keys)" }}{{ end -}}
{{- if $gcs }}
{{- if ne $credentialsMode "podIdentity" }}{{ fail "alleyoop: locker.provider=gcs requires locker.credentials.mode=podIdentity (GKE Workload Identity; the services refuse HMAC keys on GCS)" }}{{ end -}}
{{- if not (has (.Values.locker.endpoint | default "") (list "" "https://storage.googleapis.com" "https://storage.googleapis.com/")) }}{{ fail "alleyoop: locker.provider=gcs requires locker.endpoint to be empty or https://storage.googleapis.com" }}{{ end -}}
{{- if not .Values.locker.bucket }}{{ fail "alleyoop: locker.bucket is required with locker.provider=gcs" }}{{ end -}}
{{- range $name := list "CLOUD_SQL_CONNECTION_NAME" "REDIS_HOST" "REDIS_PORT" "REDIS_AUTH_ENABLED" "REDIS_TRANSIT_ENCRYPTION" "REDIS_TLS_CA_PEM" "PUBSUB_TOPIC" "PUBSUB_SUBSCRIPTION" }}
{{- if not (has $name $extraEnvNames) }}{{ fail (printf "alleyoop: locker.provider=gcs arms the services' GCS data-path readiness check, which needs %s in extraEnv (Cloud SQL connection name, Memorystore TLS and Pub/Sub settings); pods never become Ready without it" $name) }}{{ end -}}
{{- end }}
{{- end }}
{{- range $name := list "LOCKER_PROVIDER" "PIPELINE_RAW_PROVIDER" }}{{ if has $name $extraEnvNames }}{{ fail (printf "alleyoop: extraEnv must not set %s: use locker.provider" $name) }}{{ end }}{{ end -}}
{{- end }}

{{/*
Render Kubernetes EnvVar entries without letting YAML reinterpret a string such
as "6378" as a number. valueFrom is kept as structured YAML.
*/}}
{{- define "alleyoop.renderEnv" -}}
{{- range $entry := . }}
- name: {{ $entry.name | quote }}
{{- if hasKey $entry "value" }}
{{- if kindIs "invalid" $entry.value }}
  value: ""
{{- else }}
  value: {{ $entry.value | toString | quote }}
{{- end }}
{{- end }}
{{- with $entry.valueFrom }}
  valueFrom:
    {{- toYaml . | nindent 4 }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Shared environment: the services' env contract (names must not change).
Usage: include "alleyoop.env" (dict "context" . "service" "referee")
*/}}
{{- define "alleyoop.env" -}}
{{- $v := .context.Values -}}
- name: SERVICE
  value: {{ .service | quote }}
- name: OTEL_SERVICE_NAME
  value: {{ .service | quote }}
{{- include "alleyoop.scrubEngine" (dict "root" .context "localReader" $v.readerMaxRuleset "localName" "readerMaxRuleset") }}
- name: HOOPDB_URL
  valueFrom:
    secretKeyRef:
      name: {{ $v.hoopdb.existingSecret | default $v.existingSecret }}
      key: {{ $v.hoopdb.key | default $v.secretKeys.hoopdbUrl }}
- name: LOCKER_ENDPOINT
  value: {{ $v.locker.endpoint | quote }}
- name: LOCKER_BUCKET
  value: {{ $v.locker.bucket | quote }}
- name: LOCKER_REGION
  value: {{ $v.locker.region | quote }}
{{- if eq ($v.locker.provider | default "s3") "gcs" }}
- name: LOCKER_PROVIDER
  value: "gcs"
- name: PIPELINE_RAW_PROVIDER
  value: "gcs"
{{- end }}
{{- if eq ($v.locker.credentials.mode | default "secret") "secret" }}
- name: LOCKER_ACCESS_KEY_ID
  valueFrom:
    secretKeyRef:
      name: {{ $v.existingSecret }}
      key: {{ $v.secretKeys.lockerAccessKeyId }}
- name: LOCKER_SECRET_ACCESS_KEY
  valueFrom:
    secretKeyRef:
      name: {{ $v.existingSecret }}
      key: {{ $v.secretKeys.lockerSecretAccessKey }}
{{- end }}
- name: TENANT_ORG_ID
  value: {{ include "alleyoop.orgId" .context | quote }}
- name: WORKSPACE_ID
  value: {{ $v.tenant.workspaceId | quote }}
- name: DEPLOYMENT
  value: {{ $v.deployment.name | quote }}
- name: DEPLOYMENT_ID
  value: {{ $v.deployment.id | default (printf "%s/%s" .context.Release.Namespace .context.Release.Name) | quote }}
- name: ENVIRONMENT
  value: {{ $v.environment | quote }}
{{- if $v.global.otel.endpoint }}
- name: OTEL_EXPORTER_OTLP_ENDPOINT
  value: {{ $v.global.otel.endpoint | quote }}
{{- else }}
# The image bakes a local-stack collector address; blank it so the SDK does
# not export anywhere unless an endpoint is configured.
- name: OTEL_EXPORTER_OTLP_ENDPOINT
  value: ""
{{- end }}
- name: TMPDIR
  value: /tmp
{{- with $v.extraEnv }}
{{ include "alleyoop.renderEnv" . }}
{{- end }}
{{- end }}

{{/*
Pod-level boilerplate shared by every workload and Job.
*/}}
{{- define "alleyoop.podSpecCommon" -}}
{{- include "alleyoop.pullSecrets" . }}
serviceAccountName: {{ include "alleyoop.serviceAccountName" . }}
automountServiceAccountToken: {{ .Values.automountServiceAccountToken }}
{{- with .Values.podSecurityContext }}
securityContext:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .Values.nodeSelector }}
nodeSelector:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .Values.tolerations }}
tolerations:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .Values.affinity }}
affinity:
  {{- toYaml . | nindent 2 }}
{{- end }}
volumes:
  - name: tmp
    emptyDir: {}
{{- if (.Values.postgresCa | default dict).enabled }}
{{ include "alleyoop.postgresCaVolume" . | indent 2 }}
{{- end }}
{{- end }}

{{- /* Optional Postgres server CA bundle (postgresCa.*). NODE_EXTRA_CA_CERTS adds the
mounted PEM to the roots node-pg verifies against for sslmode=verify-full. */ -}}
{{- define "alleyoop.postgresCaVolume" -}}
{{- $ca := .Values.postgresCa -}}
- name: postgres-ca
{{- if $ca.configMap }}
  configMap:
    name: {{ $ca.configMap | quote }}
    items: [{ key: {{ $ca.key | quote }}, path: ca.crt }]
{{- else }}
  secret:
    secretName: {{ $ca.secret | quote }}
    # Public certificates, readable whatever the Pod's fsGroup is.
    defaultMode: 0444
    items: [{ key: {{ $ca.key | quote }}, path: ca.crt }]
{{- end }}
{{- end -}}

{{- /* Fail closed on a half-configured bundle: a name without enabled=true would
leave the certificate unverified while looking configured. */ -}}
{{- define "alleyoop.validatePostgresCa" -}}
{{- $ca := .Values.postgresCa | default dict -}}
{{- $enabled := dig "enabled" false $ca -}}
{{- if not (kindIs "bool" $enabled) }}{{ fail "alleyoop: postgresCa.enabled must be a boolean" }}{{ end -}}
{{- $configMap := get $ca "configMap" | default "" | toString -}}
{{- $secret := get $ca "secret" | default "" | toString -}}
{{- if not $enabled -}}
{{- if or $configMap $secret }}{{ fail "alleyoop: postgresCa.configMap and postgresCa.secret require postgresCa.enabled=true; a CA name while disabled would leave the certificate unverified" }}{{ end -}}
{{- else -}}
{{- if eq (empty $configMap) (empty $secret) }}{{ fail "alleyoop: postgresCa.enabled=true requires exactly one of postgresCa.configMap or postgresCa.secret" }}{{ end -}}
{{- $ref := default $secret $configMap -}}
{{- if or (gt (len $ref) 253) (not (regexMatch "^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?(\\.[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?)*$" $ref)) }}{{ fail "alleyoop: postgresCa.configMap and postgresCa.secret must be a Kubernetes object name" }}{{ end -}}
{{- if not (regexMatch "^[A-Za-z0-9._-]+$" (get $ca "key" | default "" | toString)) }}{{ fail "alleyoop: postgresCa.key must be a Kubernetes data key" }}{{ end -}}
{{- range concat (.Values.extraEnv | default list) (.Values.ingest.env | default list) }}{{ if eq (.name | default "") "NODE_EXTRA_CA_CERTS" }}{{ fail "alleyoop: extraEnv and ingest.env must not set NODE_EXTRA_CA_CERTS: postgresCa manages it" }}{{ end }}{{ end -}}
{{- end -}}
{{- end -}}
