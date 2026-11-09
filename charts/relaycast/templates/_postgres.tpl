{{/*
Relaycast on PostgreSQL (runtime.backend=postgres). Contract: docs/self-host-postgres.md
in AgentWorkforce/relaycast. Every RELAYCAST_DATABASE_* name is wired in this
file; schema and role variables stay at the image's defaults.
*/}}

{{- define "relaycast.postgres.enabled" -}}
{{- if eq (toString .Values.runtime.backend) "postgres" }}true{{ end -}}
{{- end }}

{{- define "relaycast.postgres.migrateName" -}}
{{- printf "%s-migrate" (include "relaycast.fullname" . | trunc 45 | trimSuffix "-") -}}
{{- end }}

{{- /* The migration Job has its own identity: the server's ServiceAccount (and any
workload identity on it) stays with the server. */ -}}
{{- define "relaycast.postgres.migrateServiceAccount" -}}
{{- if .Values.serviceAccount.create }}{{ include "relaycast.postgres.migrateName" . }}{{ else }}{{ include "relaycast.serviceAccountName" . }}{{ end -}}
{{- end }}

{{- /* root, file: the Secret projection the URL is read from. */ -}}
{{- define "relaycast.postgres.databaseEnv" -}}
- name: RELAYCAST_DATABASE_URL_FILE
  value: {{ include "relaycast.secretMountPath" .root }}/{{ .file }}
- name: NODE_EXTRA_CA_CERTS
  value: /etc/postgres-ca/ca.crt
{{- end }}

{{- define "relaycast.postgres.caVolume" -}}
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
{{- end }}

{{- /* Holds the server until the Job for this image has migrated the database:
verify-db (runtime identity, read-only) exits 0 only once no bundled migration is
pending. Exit 1 is "not migrated yet or unreachable", so it is retried; 64 and 65
need an operator fix and fail the init container at once. */ -}}
{{- define "relaycast.postgres.waitContainer" -}}
- name: wait-for-migrations
  image: {{ include "relaycast.image" . | quote }}
  imagePullPolicy: {{ .Values.image.pullPolicy }}
  command: [node]
  args:
    - -e
    - |
        const { spawnSync } = require('child_process');
        const deadline = Date.now() + Number(process.env.MIGRATION_WAIT_SECONDS) * 1000;
        for (;;) {
          const { status } = spawnSync(process.execPath, ['/opt/relaycast/entrypoint.mjs', 'verify-db'], { stdio: 'inherit' });
          if (status === 0) process.exit(0);
          if (status !== 1) process.exit(status === null ? 1 : status);
          if (Date.now() >= deadline) { console.error('database is not migrated for this image yet'); process.exit(1); }
          Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 5000);
        }
  securityContext:
    {{- toYaml .Values.containerSecurityContext | nindent 4 }}
  env:
    {{- include "relaycast.postgres.databaseEnv" (dict "root" . "file" "database-runtime-url") | nindent 4 }}
    - name: MIGRATION_WAIT_SECONDS
      value: {{ .Values.runtime.postgres.migrations.activeDeadlineSeconds | int64 | toString | quote }}
    {{- with .Values.extraEnv }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
  resources:
    {{- toYaml .Values.resources | nindent 4 }}
  volumeMounts:
    - name: tmp
      mountPath: /tmp
    - name: secrets
      mountPath: {{ include "relaycast.secretMountPath" . }}
      readOnly: true
    - name: postgres-ca
      mountPath: /etc/postgres-ca
      readOnly: true
{{- end }}

{{- define "relaycast.postgres.migrationPodTemplate" -}}
metadata:
  labels:
    app.kubernetes.io/name: {{ include "relaycast.name" . }}-migrate
    app.kubernetes.io/instance: {{ .Release.Name }}
    app.kubernetes.io/component: migration
spec:
  restartPolicy: Never
  serviceAccountName: {{ include "relaycast.postgres.migrateServiceAccount" . }}
  automountServiceAccountToken: false
  {{- with .Values.imagePullSecrets }}
  imagePullSecrets:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  securityContext:
    {{- toYaml .Values.podSecurityContext | nindent 4 }}
  containers:
    - name: migrate
      image: {{ include "relaycast.image" . | quote }}
      imagePullPolicy: {{ .Values.image.pullPolicy }}
      args: [migrate]
      securityContext:
        {{- toYaml .Values.containerSecurityContext | nindent 8 }}
      env:
        {{- include "relaycast.postgres.databaseEnv" (dict "root" . "file" "database-owner-url") | nindent 8 }}
        {{- with .Values.extraEnv }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
      resources:
        {{- toYaml .Values.resources | nindent 8 }}
      volumeMounts:
        - name: tmp
          mountPath: /tmp
        - name: secrets
          mountPath: {{ include "relaycast.secretMountPath" . }}
          readOnly: true
        - name: postgres-ca
          mountPath: /etc/postgres-ca
          readOnly: true
  volumes:
    - name: tmp
      emptyDir:
        sizeLimit: 64Mi
    # Only the owner URL: the Job never sees the runtime or application secrets.
    - name: secrets
      secret:
        secretName: {{ .Values.existingSecret | quote }}
        defaultMode: 0440
        items:
          - key: {{ .Values.secretKeys.databaseOwnerUrl | quote }}
            path: database-owner-url
    {{- include "relaycast.postgres.caVolume" . | nindent 4 }}
  {{- with .Values.nodeSelector }}
  nodeSelector:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .Values.affinity }}
  affinity:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .Values.tolerations }}
  tolerations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
{{- end }}

{{- /* Fail closed on a half-configured backend: the image exits 64 without a URL or
CA, so an incomplete release would only fail after it is applied. */ -}}
{{- define "relaycast.postgres.validate" -}}
{{- $ca := .Values.postgresCa | default dict -}}
{{- $enabled := dig "enabled" false $ca -}}
{{- if not (kindIs "bool" $enabled) }}{{ fail "postgresCa.enabled must be a boolean" }}{{ end -}}
{{- $configMap := get $ca "configMap" | default "" | toString -}}
{{- $secret := get $ca "secret" | default "" | toString -}}
{{- if not $enabled -}}
{{- if or $configMap $secret }}{{ fail "postgresCa.configMap and postgresCa.secret require postgresCa.enabled=true; a CA name while disabled would leave the certificate unverified" }}{{ end -}}
{{- else -}}
{{- if eq (empty $configMap) (empty $secret) }}{{ fail "postgresCa.enabled=true requires exactly one of postgresCa.configMap or postgresCa.secret" }}{{ end -}}
{{- $ref := default $secret $configMap -}}
{{- if or (gt (len $ref) 253) (not (regexMatch "^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?(\\.[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?)*$" $ref)) }}{{ fail "postgresCa.configMap and postgresCa.secret must be a Kubernetes object name" }}{{ end -}}
{{- if not (regexMatch "^[A-Za-z0-9._-]+$" (get $ca "key" | default "" | toString)) }}{{ fail "postgresCa.key must be a Kubernetes data key" }}{{ end -}}
{{- end -}}
{{- if include "relaycast.postgres.enabled" . -}}
{{- if not $enabled }}{{ fail "runtime.backend=postgres requires postgresCa.enabled=true: the image refuses to connect without a CA bundle" }}{{ end -}}
{{- $keys := .Values.secretKeys | default dict -}}
{{- range $name := list "databaseOwnerUrl" "databaseRuntimeUrl" -}}
{{- if not (get $keys $name) }}{{ fail (printf "runtime.backend=postgres requires secretKeys.%s" $name) }}{{ end -}}
{{- end -}}
{{- if eq (toString $keys.databaseOwnerUrl) (toString $keys.databaseRuntimeUrl) }}{{ fail "secretKeys.databaseOwnerUrl and secretKeys.databaseRuntimeUrl must be different keys: the server must never receive the owner credential" }}{{ end -}}
{{- range $name, $key := $keys -}}
{{- if and $key (ne $name "databaseOwnerUrl") (ne $name "databaseRuntimeUrl") (has (toString $key) (list (toString $keys.databaseOwnerUrl) (toString $keys.databaseRuntimeUrl))) }}{{ fail (printf "secretKeys.%s must not reuse a database URL key" $name) }}{{ end -}}
{{- end -}}
{{- if .Values.backup.enabled }}{{ fail "backup.enabled is the SQLite backup and is refused with runtime.backend=postgres: back up the database with its own tooling" }}{{ end -}}
{{- if not (kindIs "invalid" .Values.retention.messageTtlDays) }}{{ fail "retention.messageTtlDays is not supported with runtime.backend=postgres" }}{{ end -}}
{{- $migrations := .Values.runtime.postgres.migrations -}}
{{- if not (regexMatch "^[0-9]+$" (toString $migrations.backoffLimit)) }}{{ fail "runtime.postgres.migrations.backoffLimit must be a non-negative integer" }}{{ end -}}
{{- if not (regexMatch "^[1-9][0-9]*$" (toString $migrations.activeDeadlineSeconds)) }}{{ fail "runtime.postgres.migrations.activeDeadlineSeconds must be a positive integer" }}{{ end -}}
{{- /* Would make the image exit 64, or override what the chart wires. */ -}}
{{- $reserved := list "NODE_EXTRA_CA_CERTS" "RELAYCAST_DATABASE_URL" "RELAYCAST_DATABASE_URL_FILE" "RELAYCAST_DATABASE_CA_FILE" "RELAYCAST_DATABASE_SCHEMA" "RELAYCAST_DATABASE_OWNER_ROLE" "RELAYCAST_DATABASE_RUNTIME_ROLE" "PGREPLICATION" "PGBINARY" "PGCLIENT_ENCODING" "PGSSLNEGOTIATION" -}}
{{- range .Values.extraEnv -}}
{{- if has (toString .name) $reserved }}{{ fail (printf "%s is managed by structured chart values and must not appear in extraEnv" .name) }}{{ end -}}
{{- end -}}
{{- else -}}
{{- if $enabled }}{{ fail "postgresCa.enabled requires runtime.backend=postgres" }}{{ end -}}
{{- range .Values.extraEnv -}}
{{- if hasPrefix "RELAYCAST_DATABASE_" (toString .name) }}{{ fail (printf "%s selects the PostgreSQL backend; set runtime.backend=postgres instead of extraEnv" .name) }}{{ end -}}
{{- end -}}
{{- end -}}
{{- end }}
