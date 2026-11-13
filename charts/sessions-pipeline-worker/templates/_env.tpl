{{/*
Tenant org id: tenant.orgId, else global.tenant.orgId (set once by an umbrella).
*/}}
{{- define "sessions-pipeline-worker.orgId" -}}
{{- .Values.tenant.orgId | default (dig "tenant" "orgId" "" (.Values.global | default dict)) -}}
{{- end }}

{{/*
Fail early on missing required values (render time, not crash-loop time).
*/}}
{{- define "sessions-pipeline-worker.validate" -}}
{{- $credentialsMode := .Values.locker.credentials.mode | default "secret" -}}
{{- if not (has (toString .Values.allowInClusterHttp) (list "true" "false")) }}{{ fail "sessions-pipeline-worker: allowInClusterHttp must be true or false" }}{{ end -}}
{{- range .Values.extraEnv }}{{ if eq (.name | default "") "ALLOW_IN_CLUSTER_HTTP" }}{{ fail "sessions-pipeline-worker: extraEnv must not set ALLOW_IN_CLUSTER_HTTP: use allowInClusterHttp" }}{{ end }}{{ end -}}
{{- range $n, $c := .Values.components }}{{ range ($c.env | default list) }}{{ if eq (.name | default "") "ALLOW_IN_CLUSTER_HTTP" }}{{ fail (printf "sessions-pipeline-worker: components.%s.env must not set ALLOW_IN_CLUSTER_HTTP: use allowInClusterHttp" $n) }}{{ end }}{{ end }}{{ end -}}
{{- $scrubReserved := list "SCRUB_ENGINE" "SCRUB_ENGINE_REQUIRED" "READER_MAX_RULESET" -}}
{{- range .Values.extraEnv }}{{ if has (.name | default "") $scrubReserved }}{{ fail (printf "sessions-pipeline-worker: extraEnv must not set %s: use global.scrubEngine" .name) }}{{ end }}{{ end -}}
{{- range $n, $c := .Values.components }}{{ range ($c.env | default list) }}{{ if has (.name | default "") $scrubReserved }}{{ fail (printf "sessions-pipeline-worker: components.%s.env must not set %s: use global.scrubEngine" $n .name) }}{{ end }}{{ end }}{{ end -}}
{{- $migrations := .Values.migrations | default dict -}}
{{- $migrationHoopdb := get $migrations "hoopdb" | default dict -}}
{{- if not (or (eq $credentialsMode "secret") (eq $credentialsMode "podIdentity")) }}{{ fail "sessions-pipeline-worker: locker.credentials.mode must be secret or podIdentity" }}{{ end -}}
{{- if and (eq $credentialsMode "secret") (not .Values.existingSecret) }}{{ fail "sessions-pipeline-worker: existingSecret is required when locker.credentials.mode=secret" }}{{ end -}}
{{- if and (not .Values.hoopdb.existingSecret) (not .Values.existingSecret) }}{{ fail "sessions-pipeline-worker: hoopdb.existingSecret or existingSecret is required for HOOPDB_URL" }}{{ end -}}
{{- if ne (empty (get $migrationHoopdb "existingSecret")) (empty (get $migrationHoopdb "key")) }}{{ fail "sessions-pipeline-worker: migrations.hoopdb.existingSecret and key must be set together" }}{{ end -}}
{{- if and (eq $credentialsMode "secret") (not .Values.locker.endpoint) }}{{ fail "sessions-pipeline-worker: locker.endpoint is required when locker.credentials.mode=secret" }}{{ end -}}
{{- if not (include "sessions-pipeline-worker.orgId" .) }}{{ fail "sessions-pipeline-worker: tenant.orgId (or global.tenant.orgId) is required" }}{{ end -}}
{{- $idx := index .Values.components "hoopdb-indexer" -}}
{{- if and $idx.enabled (gt (int $idx.replicas) 1) }}{{ fail "sessions-pipeline-worker: components.hoopdb-indexer.replicas must be 1 (manifest reconcile is not leader-elected)" }}{{ end -}}
{{- /* Phase 2 role verify must run in migrate: with it off, readiness never passes
unless a separate mark_pass step runs, which this chart does not have. */ -}}
{{- $reserved := list "HOOPDB_ROLE_VERIFY" "HOOPDB_ROLE_BOOTSTRAP" "HOOPDB_DB_MODE" "HOOPDB_SUPABASE_SHIM" "HOOPDB_RUNTIME_ROLE" "HOOPDB_RUNTIME_ROLE_LOGIN" "HOOPDB_RUNTIME_WORKLOAD_ROLE" "HOOPDB_FUNCTION_BOUNDARY_MODE" "HOOPDB_FUNCTION_BOUNDARY_APPROVED" "HOOPDB_ALLOW_BLOCKING_INDEX_BUILD" -}}
{{- range .Values.extraEnv }}{{ if has (.name | default "") $reserved }}{{ fail (printf "sessions-pipeline-worker: extraEnv must not set %s: it is a migrations.* value, rendered into migrate only" .name) }}{{ end }}{{ end -}}
{{- range $n, $c := .Values.components }}{{ range ($c.env | default list) }}{{ if has (.name | default "") $reserved }}{{ fail (printf "sessions-pipeline-worker: components.%s.env must not set %s: it is a migrations.* value, rendered into migrate only" $n .name) }}{{ end }}{{ end }}{{ end -}}
{{- if .Values.migrations.enabled }}{{ include "sessions-pipeline-worker.validateProfile" . }}{{ end -}}
{{- $bob := index .Values.components "bob-costas" -}}
{{- if and $bob.enabled (not (.Values.summaryEncryption.existingSecret | default .Values.existingSecret)) }}{{ fail "sessions-pipeline-worker: summaryEncryption.existingSecret or existingSecret is required when bob-costas is enabled" }}{{ end -}}
{{- if and $bob.enabled (not .Values.summaryEncryption.key) }}{{ fail "sessions-pipeline-worker: summaryEncryption.key is required when bob-costas is enabled" }}{{ end -}}
{{- if and $bob.enabled (not .Values.summaryEncryption.mountPath) }}{{ fail "sessions-pipeline-worker: summaryEncryption.mountPath is required when bob-costas is enabled" }}{{ end -}}
{{- if and $bob.enabled (not .Values.summaryEncryption.fileName) }}{{ fail "sessions-pipeline-worker: summaryEncryption.fileName is required when bob-costas is enabled" }}{{ end -}}
{{- range $entry := $bob.env }}
{{- if or (eq ($entry.name | default "") "SUMMARY_MASTER_KEYS") (eq ($entry.name | default "") "SUMMARY_MASTER_KEYS_FILE") }}{{ fail "sessions-pipeline-worker: configure summaryEncryption instead of components.bob-costas.env SUMMARY_MASTER_KEYS/SUMMARY_MASTER_KEYS_FILE" }}{{ end -}}
{{- end }}
{{- include "sessions-pipeline-worker.validateNativeBrief" . }}
{{- include "sessions-pipeline-worker.validateLocker" . }}
{{- include "sessions-pipeline-worker.validatePostgresCa" . }}
{{- end }}

{{/*
Locker provider validation; runs last so the other value checks report first.
*/}}
{{- define "sessions-pipeline-worker.validateLocker" -}}
{{- $credentialsMode := .Values.locker.credentials.mode | default "secret" -}}
{{- /* Locker provider. The services image selects S3 (unset LOCKER_PROVIDER) or
native GCS (LOCKER_PROVIDER=gcs, Workload Identity through the GKE metadata
server). It refuses HMAC keys on GCS and refuses the S3 client against a
Google Cloud Storage endpoint, so both shapes fail here at render time. */ -}}
{{- $provider := .Values.locker.provider | default "s3" -}}
{{- if not (has $provider (list "s3" "gcs")) }}{{ fail "sessions-pipeline-worker: locker.provider must be s3 or gcs" }}{{ end -}}
{{- $gcs := eq $provider "gcs" -}}
{{- $extraEnvNames := list -}}
{{- range .Values.extraEnv }}{{ $extraEnvNames = append $extraEnvNames (.name | default "") }}{{ end -}}
{{- $endpointHost := "" -}}
{{- if .Values.locker.endpoint }}{{ $endpointHost = (urlParse .Values.locker.endpoint).hostname | lower }}{{ end -}}
{{- if and (not $gcs) (or (eq $endpointHost "storage.googleapis.com") (hasSuffix ".storage.googleapis.com" $endpointHost) (eq $endpointHost "storage.google.com")) }}{{ fail "sessions-pipeline-worker: locker.endpoint is a Google Cloud Storage endpoint: set locker.provider=gcs (the services refuse GCS through the S3 client and HMAC keys)" }}{{ end -}}
{{- if $gcs }}
{{- if ne $credentialsMode "podIdentity" }}{{ fail "sessions-pipeline-worker: locker.provider=gcs requires locker.credentials.mode=podIdentity (GKE Workload Identity; the services refuse HMAC keys on GCS)" }}{{ end -}}
{{- if not (has (.Values.locker.endpoint | default "") (list "" "https://storage.googleapis.com" "https://storage.googleapis.com/")) }}{{ fail "sessions-pipeline-worker: locker.provider=gcs requires locker.endpoint to be empty or https://storage.googleapis.com" }}{{ end -}}
{{- if not .Values.locker.bucket }}{{ fail "sessions-pipeline-worker: locker.bucket is required with locker.provider=gcs" }}{{ end -}}
{{- if .Values.lockerInit.enabled }}{{ fail "sessions-pipeline-worker: lockerInit.enabled must be false with locker.provider=gcs: provision the GCS bucket outside the chart" }}{{ end -}}
{{- range $name := list "CLOUD_SQL_CONNECTION_NAME" "REDIS_HOST" "REDIS_PORT" "REDIS_AUTH_ENABLED" "REDIS_TRANSIT_ENCRYPTION" "REDIS_TLS_CA_PEM" "PUBSUB_TOPIC" "PUBSUB_SUBSCRIPTION" }}
{{- if not (has $name $extraEnvNames) }}{{ fail (printf "sessions-pipeline-worker: locker.provider=gcs arms the services' GCS data-path readiness check, which needs %s in extraEnv (Cloud SQL connection name, Memorystore TLS and Pub/Sub settings); pods never become Ready without it" $name) }}{{ end -}}
{{- end }}
{{- end }}
{{- range $name := list "LOCKER_PROVIDER" "PIPELINE_RAW_PROVIDER" }}{{ if has $name $extraEnvNames }}{{ fail (printf "sessions-pipeline-worker: extraEnv must not set %s: use locker.provider" $name) }}{{ end }}{{ end -}}
{{- end }}

{{/*
Render Kubernetes EnvVar entries without letting YAML reinterpret a string such
as "6378" as a number. valueFrom is kept as structured YAML.
*/}}
{{- define "sessions-pipeline-worker.renderEnv" -}}
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
Usage: include "sessions-pipeline-worker.env" (dict "context" . "service" "referee")
*/}}
{{- define "sessions-pipeline-worker.env" -}}
{{- $v := .context.Values -}}
- name: SERVICE
  value: {{ .service | quote }}
- name: OTEL_SERVICE_NAME
  value: {{ .service | quote }}
{{- $scrub := dict "root" .context "localName" "readerMaxRuleset" -}}
{{- if eq .service "session-brief" }}{{ $_ := set $scrub "localReader" $v.nativeBrief.readerMaxRuleset }}{{ $_ := set $scrub "localName" "nativeBrief.readerMaxRuleset" }}{{ end -}}
{{- include "sessions-pipeline-worker.scrubEngine" $scrub }}
{{ include "sessions-pipeline-worker.hoopdbUrlEnv" (dict "root" .context "migrate" (eq .service "hoopdb-migrate")) }}
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
  value: {{ include "sessions-pipeline-worker.orgId" .context | quote }}
- name: WORKSPACE_ID
  value: {{ $v.tenant.workspaceId | quote }}
- name: DEPLOYMENT
  value: {{ $v.deployment.name | quote }}
- name: DEPLOYMENT_ID
  value: {{ $v.deployment.id | default (printf "%s/%s" .context.Release.Namespace .context.Release.Name) | quote }}
- name: ENVIRONMENT
  value: {{ $v.environment | quote }}
- name: ALLOW_IN_CLUSTER_HTTP
  value: {{ ternary "true" "false" (or (eq (toString $v.allowInClusterHttp) "true") (and (eq .service "session-brief") $v.nativeBrief.enabled $v.nativeBrief.allowInClusterHttp)) | quote }}
{{- if eq .service "bob-costas" }}
# The Secret is projected as a file into Bob Costas only; the key material is
# never copied into the Pod spec's environment values.
- name: SUMMARY_MASTER_KEYS_FILE
  value: {{ printf "%s/%s" $v.summaryEncryption.mountPath $v.summaryEncryption.fileName | quote }}
{{- end }}
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
{{ include "sessions-pipeline-worker.renderEnv" . }}
{{- end }}
{{- end }}

{{/*
Pod-level boilerplate shared by every workload and Job.
*/}}
{{- define "sessions-pipeline-worker.podSpecCommon" -}}
{{- $ctx := .context -}}
{{- include "sessions-pipeline-worker.pullSecrets" $ctx }}
serviceAccountName: {{ include "sessions-pipeline-worker.serviceAccountName" $ctx }}
automountServiceAccountToken: {{ $ctx.Values.automountServiceAccountToken }}
{{- with $ctx.Values.podSecurityContext }}
securityContext:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with $ctx.Values.nodeSelector }}
nodeSelector:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with $ctx.Values.tolerations }}
tolerations:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with $ctx.Values.affinity }}
affinity:
  {{- toYaml . | nindent 2 }}
{{- end }}
volumes:
  - name: tmp
    emptyDir: {}
{{- if and (eq .component "session-brief") $ctx.Values.nativeBrief.enabled }}
  - name: native-brief-verified-ca
    emptyDir: { medium: Memory, sizeLimit: 1Mi }
{{- $analytics := $ctx.Values.nativeBrief.analytics }}
{{- if and $analytics.enabled $analytics.caConfigMap }}
  - name: brief-analytics-ca
    configMap:
      name: {{ $analytics.caConfigMap | quote }}
      defaultMode: 0444
      items: [{ key: {{ $analytics.caKey | quote }}, path: ca.crt }]
{{- end }}
{{- end }}
{{- if eq .component "bob-costas" }}
  - name: summary-master-keys
    secret:
      secretName: {{ $ctx.Values.summaryEncryption.existingSecret | default $ctx.Values.existingSecret | quote }}
      # Kubernetes projects this for the Pod's fsGroup: Bob can read it, but
      # it is not world-readable inside the Pod.
      defaultMode: 0440
      items:
        - key: {{ $ctx.Values.summaryEncryption.key | quote }}
          path: {{ $ctx.Values.summaryEncryption.fileName | quote }}
{{- end }}
{{- if and ($ctx.Values.postgresCa | default dict).enabled (ne .component "locker-init") }}
{{ include "sessions-pipeline-worker.postgresCaVolume" $ctx | indent 2 }}
{{- end }}
{{- end }}

{{/*
HOOPDB_URL from the HoopDb Secret (context: the chart root).
*/}}
{{- define "sessions-pipeline-worker.hoopdbUrlEnv" -}}
{{- $v := .root.Values -}}
{{- $secret := $v.hoopdb.existingSecret | default $v.existingSecret -}}
{{- $key := $v.hoopdb.key | default $v.secretKeys.hoopdbUrl -}}
{{- if .migrate -}}
{{- /* migrate and its wait-for-role: the migration-owner URL when set
(migrations.hoopdb). wait-for-role checks current_user's function default, so
it must connect as the same owner as the migrator. */ -}}
{{- $migrations := $v.migrations | default dict -}}
{{- $migrationHoopdb := get $migrations "hoopdb" | default dict -}}
{{- $secret = get $migrationHoopdb "existingSecret" | default $secret -}}
{{- $key = get $migrationHoopdb "key" | default $key -}}
{{- end -}}
- name: HOOPDB_URL
  valueFrom:
    secretKeyRef:
      name: {{ $secret | quote }}
      key: {{ $key | quote }}
{{- end }}

{{/*
The migrator's database profile: the same refusals as sessions-pipeline
migrationProfile() (#99), at render time, plus the chart's own: wait-for-role
is refused in supabase mode (no shim, no bootstrap, no in-cluster role steps).
Role names follow the migrator's pattern exactly.
*/}}
{{- define "sessions-pipeline-worker.validateProfile" -}}
{{- $m := .Values.migrations -}}
{{- $ident := "^[A-Za-z_][A-Za-z0-9_$-]{0,62}$" -}}
{{- if not (has $m.databaseMode (list "local" "selfhosted" "cloudsql" "supabase" "rds")) }}{{ fail "sessions-pipeline-worker: migrations.databaseMode must be local, selfhosted, cloudsql, supabase or rds (HOOPDB_DB_MODE has no default)" }}{{ end -}}
{{- if not (or (kindIs "invalid" $m.roleBootstrap) (kindIs "bool" $m.roleBootstrap)) }}{{ fail "sessions-pipeline-worker: migrations.roleBootstrap must be true or false" }}{{ end -}}
{{- if not (or (kindIs "invalid" $m.supabaseShim) (kindIs "bool" $m.supabaseShim)) }}{{ fail "sessions-pipeline-worker: migrations.supabaseShim must be true or false" }}{{ end -}}
{{- if not (or (kindIs "invalid" $m.runtimeRoleLogin) (kindIs "bool" $m.runtimeRoleLogin)) }}{{ fail "sessions-pipeline-worker: migrations.runtimeRoleLogin must be true or false" }}{{ end -}}
{{- if not (or (kindIs "invalid" $m.allowBlockingIndexBuild) (kindIs "bool" $m.allowBlockingIndexBuild)) }}{{ fail "sessions-pipeline-worker: migrations.allowBlockingIndexBuild must be true or false" }}{{ end -}}
{{- if eq $m.databaseMode "supabase" }}
{{- if eq $m.supabaseShim true }}{{ fail "sessions-pipeline-worker: migrations.supabaseShim must not be true in supabase mode (the plain-Postgres role shim never runs there)" }}{{ end -}}
{{- if $m.waitForRole.enabled }}{{ fail "sessions-pipeline-worker: migrations.waitForRole must be disabled in supabase mode (the roles are operator steps; the migrator verifies them)" }}{{ end -}}
{{- if eq $m.roleBootstrap true }}{{ fail "sessions-pipeline-worker: migrations.roleBootstrap must not be true in supabase mode (the privileged role bootstrap never runs from the migrator there)" }}{{ end -}}
{{- else if eq $m.databaseMode "rds" }}
{{- if eq $m.supabaseShim true }}{{ fail "sessions-pipeline-worker: migrations.supabaseShim must not be true in rds mode (supabase/bootstrap/rds_migration_roles.sql replaces it)" }}{{ end -}}
{{- if eq $m.roleBootstrap true }}{{ fail "sessions-pipeline-worker: migrations.roleBootstrap must not be true in rds mode (the operator runs the rds_*.sql bootstrap as the master)" }}{{ end -}}
{{- if $m.waitForRole.enabled }}{{ fail "sessions-pipeline-worker: migrations.waitForRole must be disabled in rds mode (psql and the migrator cannot share a TLS URL there; the migrator verifies the roles)" }}{{ end -}}
{{- if $m.runtimeWorkloadRole }}{{ fail "sessions-pipeline-worker: migrations.runtimeWorkloadRole is not supported in rds mode; the runtime role must log in itself" }}{{ end -}}
{{- if and (kindIs "bool" $m.runtimeRoleLogin) (not $m.runtimeRoleLogin) }}{{ fail "sessions-pipeline-worker: migrations.runtimeRoleLogin must be true in rds mode" }}{{ end -}}
{{- else if kindIs "invalid" $m.supabaseShim }}{{ fail (printf "sessions-pipeline-worker: migrations.supabaseShim must be set (true or false) in %s mode" $m.databaseMode) }}{{ end -}}
{{- if not (regexMatch $ident ($m.runtimeRole | default "")) }}{{ fail "sessions-pipeline-worker: migrations.runtimeRole is required: the role the services connect as (HOOPDB_RUNTIME_ROLE)" }}{{ end -}}
{{- if eq $m.runtimeRole "session_directory_search_worker" }}{{ fail "sessions-pipeline-worker: migrations.runtimeRole must not be the search Worker role" }}{{ end -}}
{{- if and (ne $m.databaseMode "local") (kindIs "invalid" $m.runtimeRoleLogin) }}{{ fail (printf "sessions-pipeline-worker: migrations.runtimeRoleLogin must be set (true or false) in %s mode" $m.databaseMode) }}{{ end -}}
{{- if and $m.runtimeWorkloadRole (not (regexMatch $ident $m.runtimeWorkloadRole)) }}{{ fail "sessions-pipeline-worker: migrations.runtimeWorkloadRole must be a role name" }}{{ end -}}
{{- if hasKey $m "functionBoundaryApproved" }}{{ fail "sessions-pipeline-worker: migrations.functionBoundaryApproved was renamed functionBoundaryMode (HOOPDB_FUNCTION_BOUNDARY_MODE); remove it" }}{{ end -}}
{{- if and (eq ($m.functionBoundaryMode | default "") "event-trigger") (ne $m.databaseMode "supabase") }}{{ fail (printf "sessions-pipeline-worker: migrations.functionBoundaryMode=event-trigger is supported only in supabase mode, not %s (selfhosted, cloudsql and rds use global-default-revoke)" $m.databaseMode) }}{{ end -}}
{{- if and $m.functionBoundaryMode (not (has $m.functionBoundaryMode (list "global-default-revoke" "event-trigger"))) }}{{ fail "sessions-pipeline-worker: migrations.functionBoundaryMode must be global-default-revoke or (supabase only) event-trigger" }}{{ end -}}
{{- if and (has $m.databaseMode (list "selfhosted" "cloudsql" "rds")) (not $m.functionBoundaryMode) }}{{ fail (printf "sessions-pipeline-worker: migrations.functionBoundaryMode is required in %s mode (global-default-revoke; the migrator's function-boundary gate refuses without it)" $m.databaseMode) }}{{ end -}}
{{- if and $m.waitForRole.functionDefault (not $m.waitForRole.enabled) }}{{ fail "sessions-pipeline-worker: migrations.waitForRole.functionDefault needs migrations.waitForRole.enabled" }}{{ end -}}
{{- if and $m.waitForRole.functionDefault (ne ($m.functionBoundaryMode | default "") "global-default-revoke") }}{{ fail "sessions-pipeline-worker: migrations.waitForRole.functionDefault needs functionBoundaryMode global-default-revoke" }}{{ end -}}
{{- end }}

{{/*
The migrate container's profile env, each name exactly once (context: migrations).
*/}}
{{- define "sessions-pipeline-worker.profileEnv" -}}
- name: HOOPDB_DB_MODE
  value: {{ .databaseMode | quote }}
- name: HOOPDB_SUPABASE_SHIM
  value: {{ ternary "true" "false" (eq .supabaseShim true) | quote }}
- name: HOOPDB_RUNTIME_ROLE
  value: {{ .runtimeRole | quote }}
{{- if not (kindIs "invalid" .runtimeRoleLogin) }}
- name: HOOPDB_RUNTIME_ROLE_LOGIN
  value: {{ ternary "true" "false" .runtimeRoleLogin | quote }}
{{- end }}
{{- with .runtimeWorkloadRole }}
- name: HOOPDB_RUNTIME_WORKLOAD_ROLE
  value: {{ . | quote }}
{{- end }}
{{- if not (kindIs "invalid" .roleBootstrap) }}
- name: HOOPDB_ROLE_BOOTSTRAP
  value: {{ ternary "true" "false" .roleBootstrap | quote }}
{{- end }}
{{- with .functionBoundaryMode }}
- name: HOOPDB_FUNCTION_BOUNDARY_MODE
  value: {{ . | quote }}
{{- end }}
{{- if eq .allowBlockingIndexBuild true }}
- name: HOOPDB_ALLOW_BLOCKING_INDEX_BUILD
  value: "true"
{{- end }}
{{- end }}

{{- /* Optional Postgres server CA bundle (postgresCa.*). NODE_EXTRA_CA_CERTS adds the
mounted PEM to the roots node-pg verifies against for sslmode=verify-full. */ -}}
{{- define "sessions-pipeline-worker.postgresCaVolume" -}}
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
{{- define "sessions-pipeline-worker.validatePostgresCa" -}}
{{- $ca := .Values.postgresCa | default dict -}}
{{- $enabled := dig "enabled" false $ca -}}
{{- if not (kindIs "bool" $enabled) }}{{ fail "sessions-pipeline-worker: postgresCa.enabled must be a boolean" }}{{ end -}}
{{- $configMap := get $ca "configMap" | default "" | toString -}}
{{- $secret := get $ca "secret" | default "" | toString -}}
{{- if not $enabled -}}
{{- if or $configMap $secret }}{{ fail "sessions-pipeline-worker: postgresCa.configMap and postgresCa.secret require postgresCa.enabled=true; a CA name while disabled would leave the certificate unverified" }}{{ end -}}
{{- else -}}
{{- if eq (empty $configMap) (empty $secret) }}{{ fail "sessions-pipeline-worker: postgresCa.enabled=true requires exactly one of postgresCa.configMap or postgresCa.secret" }}{{ end -}}
{{- $ref := default $secret $configMap -}}
{{- if or (gt (len $ref) 253) (not (regexMatch "^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?(\\.[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?)*$" $ref)) }}{{ fail "sessions-pipeline-worker: postgresCa.configMap and postgresCa.secret must be a Kubernetes object name" }}{{ end -}}
{{- if not (regexMatch "^[A-Za-z0-9._-]+$" (get $ca "key" | default "" | toString)) }}{{ fail "sessions-pipeline-worker: postgresCa.key must be a Kubernetes data key" }}{{ end -}}
{{- range .Values.extraEnv }}{{ if eq (.name | default "") "NODE_EXTRA_CA_CERTS" }}{{ fail "sessions-pipeline-worker: extraEnv must not set NODE_EXTRA_CA_CERTS: postgresCa manages it" }}{{ end }}{{ end -}}
{{- range $n, $c := .Values.components }}{{ range ($c.env | default list) }}{{ if eq (.name | default "") "NODE_EXTRA_CA_CERTS" }}{{ fail (printf "sessions-pipeline-worker: components.%s.env must not set NODE_EXTRA_CA_CERTS: postgresCa manages it" $n) }}{{ end }}{{ end }}{{ end -}}
{{- end -}}
{{- end -}}
