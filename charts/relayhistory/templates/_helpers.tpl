{{- define "relayhistory.name" -}}{{ default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}{{- end -}}
{{- define "relayhistory.fullname" -}}{{ if .Values.fullnameOverride }}{{ .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}{{ else }}{{ printf "%s-%s" .Release.Name (include "relayhistory.name" .) | trunc 63 | trimSuffix "-" }}{{ end }}{{- end -}}
{{- define "relayhistory.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{ include "relayhistory.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: agent-relay
{{- end -}}
{{- /* Job metadata labels: the runtime component label is replaced by
migration so `kubectl wait job -l app.kubernetes.io/component=migration`
(NOTES.txt) finds the Job. */ -}}
{{- define "relayhistory.migrationLabels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
app.kubernetes.io/name: {{ include "relayhistory.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: migration
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: agent-relay
{{- end -}}
{{- define "relayhistory.selectorLabels" -}}
app.kubernetes.io/name: {{ include "relayhistory.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: history
{{- end -}}
{{- define "relayhistory.serviceAccountName" -}}{{ if .Values.serviceAccount.create }}{{ default (include "relayhistory.fullname" .) .Values.serviceAccount.name }}{{ else }}{{ default "default" .Values.serviceAccount.name }}{{ end }}{{- end -}}
{{- define "relayhistory.image" -}}
{{- $digest := required "image.digest is required; relayhistory images must be pinned by sha256 digest" .Values.image.digest -}}
{{- if not (regexMatch "^sha256:[a-f0-9]{64}$" $digest) }}{{ fail "image.digest must be sha256:<64 lowercase hex characters>" }}{{ end -}}
{{- printf "%s@%s" .Values.image.repository $digest -}}
{{- end -}}
{{- define "relayhistory.validate" -}}
{{- $image := include "relayhistory.image" . -}}
{{- if ne (int .Values.replicaCount) 1 }}{{ fail "replicaCount must be 1: the GCP proof runs one History replica and the chart makes no HA claim (to drain it for a write-hold migration, set migrations.drainForWriteHold=true instead)" }}{{ end -}}
{{- if and .Values.migrations.drainForWriteHold (not .Values.migrations.allowWriteHold) }}{{ fail "migrations.drainForWriteHold requires migrations.allowWriteHold=true: draining History only serves a write-hold migration" }}{{ end -}}
{{- if and .Values.migrations.drainForWriteHold (not .Values.migrations.enabled) }}{{ fail "migrations.drainForWriteHold requires migrations.enabled=true" }}{{ end -}}
{{- if and .Values.migrations.drainForWriteHold .Values.networkPolicy.enabled (not .Values.networkPolicy.allowAllEgress) (empty .Values.migrations.drainWaitApiServerEgress) }}{{ fail "migrations.drainForWriteHold with restricted egress requires migrations.drainWaitApiServerEgress (the Kubernetes API server address): the migrate Job polls the API until History has drained" }}{{ end -}}
{{- $drainWait := .Values.migrations.drainWaitSeconds -}}
{{- if not (and (or (kindIs "int" $drainWait) (kindIs "int64" $drainWait) (kindIs "float64" $drainWait)) (ge (float64 $drainWait) 1.0) (eq (float64 $drainWait) (float64 (int64 $drainWait)))) }}{{ fail "migrations.drainWaitSeconds must be a positive integer" }}{{ end -}}
{{- if and .Values.migrations.drainForWriteHold (ge (int64 $drainWait) (int64 .Values.migrations.activeDeadlineSeconds)) }}{{ fail "migrations.drainWaitSeconds must be below migrations.activeDeadlineSeconds: the Job deadline covers the drain wait and the migration" }}{{ end -}}
{{- $apiPort := .Values.migrations.drainWaitApiServerPort -}}
{{- if not (and (or (kindIs "int" $apiPort) (kindIs "int64" $apiPort) (kindIs "float64" $apiPort)) (ge (float64 $apiPort) 1.0) (le (float64 $apiPort) 65535.0) (eq (float64 $apiPort) (float64 (int64 $apiPort)))) }}{{ fail "migrations.drainWaitApiServerPort must be a port number" }}{{ end -}}
{{- if and .Values.migrations.drainForWriteHold (not .Values.serviceAccount.create) (not .Values.serviceAccount.name) }}{{ fail "migrations.drainForWriteHold with serviceAccount.create=false requires serviceAccount.name: the drain-wait Role must not be bound to the namespace default ServiceAccount" }}{{ end -}}
{{- if not .Values.database.existingSecret }}{{ fail "database.existingSecret is required; the chart never creates database credentials" }}{{ end -}}
{{- range $name, $key := .Values.database.keys }}{{ if not (regexMatch "^[A-Za-z0-9._-]+$" (toString $key)) }}{{ fail (printf "database.keys.%s must be a Kubernetes Secret data key" $name) }}{{ end }}{{ end -}}
{{- if and .Values.database.runtimeRole (not (regexMatch "^[A-Za-z_][A-Za-z0-9_$]{0,62}$" .Values.database.runtimeRole)) }}{{ fail "database.runtimeRole must be a valid PostgreSQL role name" }}{{ end -}}
{{- if not (regexMatch "^https://[^/?#]+$" .Values.relayauth.historyOrigin) }}{{ fail "relayauth.historyOrigin must be an HTTPS origin with no path" }}{{ end -}}
{{- if not (regexMatch "^https?://[^?#]+$" .Values.relayauth.jwksUrl) }}{{ fail "relayauth.jwksUrl is required" }}{{ end -}}
{{- if not (regexMatch "^https?://[^/?#]+$" .Values.relayauth.issuer) }}{{ fail "relayauth.issuer must be an HTTP(S) origin" }}{{ end -}}
{{- if not (regexMatch "^https?://[^?#]+$" .Values.agentRelayCloud.apiUrl) }}{{ fail "agentRelayCloud.apiUrl is required" }}{{ end -}}
{{- if and .Values.networkPolicy.enabled (not .Values.networkPolicy.allowAllEgress) (empty .Values.networkPolicy.additionalEgress) }}{{ fail "networkPolicy.enabled with allowAllEgress=false requires networkPolicy.additionalEgress: restricted egress allows only same-namespace pods and DNS, which blocks the external PostgreSQL database and the RelayAuth JWKS / control API URLs when they are outside the namespace" }}{{ end -}}
{{- range .Values.networkPolicy.additionalEgress }}{{ if empty .to }}{{ fail "every networkPolicy.additionalEgress rule needs a non-empty to (an empty to matches every destination; use ipBlock 0.0.0.0/0 to allow any destination explicitly)" }}{{ end }}{{ end -}}
{{- range $key, $_ := include "relayhistory.selectorLabels" . | fromYaml }}{{ if hasKey ($.Values.podLabels | default dict) $key }}{{ fail (printf "podLabels must not set selector label %s: the Deployment selector would no longer match its pods" $key) }}{{ end }}{{ end -}}
{{- if ne .Values.service.type "ClusterIP" }}{{ fail "service.type must be ClusterIP" }}{{ end -}}
{{- if and .Values.telemetry.enabled (not .Values.telemetry.host) }}{{ fail "telemetry.host is required when telemetry.enabled=true" }}{{ end -}}
{{- range $name, $feature := dict "embeddings" .Values.embeddings "sessionAnalysis" .Values.sessionAnalysis "telemetry" .Values.telemetry }}{{ if and $feature.enabled (not (regexMatch "^[A-Za-z0-9._-]+$" (toString $feature.key))) }}{{ fail (printf "%s.key must name a Secret data key when %s.enabled=true" $name $name) }}{{ end }}{{ end -}}
{{- if and .Values.migrations.enabled (lt (int .Values.migrations.activeDeadlineSeconds) (add (int .Values.migrations.rolloutBudgetSeconds) 2700 | int)) }}{{ fail "migrations.activeDeadlineSeconds must be >= rolloutBudgetSeconds + 2700" }}{{ end -}}
{{- if .Values.ingress.enabled }}{{ if empty .Values.ingress.hosts }}{{ fail "ingress.enabled=true requires at least one host" }}{{ end }}{{ if and (not .Values.ingress.externalTls) (empty .Values.ingress.tls) }}{{ fail "ingress.enabled=true requires ingress.tls unless externalTls=true" }}{{ end }}{{ if and .Values.networkPolicy.enabled (empty .Values.networkPolicy.ingressFrom) }}{{ fail "ingress with networkPolicy requires networkPolicy.ingressFrom" }}{{ end }}{{ end -}}
{{- $reservedEnv := list "PORT" "ENVIRONMENT" "MAX_BODY_BYTES" "MAX_INFLIGHT_BODY_BYTES" "SHUTDOWN_GRACE_MS" "SHUTDOWN_DRAIN_DELAY_MS" "PG_POOL_MAX" "CRON_ENABLED" "RELAYAUTH_JWKS_URL" "RELAYAUTH_ISSUER" "RELAYAUTH_AUDIENCE" "RELAYHISTORY_ORIGIN" "AGENT_RELAY_CLOUD_API_URL" "SESSION_EVENTS_ENABLED" "POSTHOG_HOST" "DATABASE_URL" "DATABASE_MIGRATIONS_URL" "DATABASE_RUNTIME_ROLE" "EMBEDDING_API_KEY" "OPENAI_API_KEY" "POSTHOG_API_KEY" "ALLOW_WRITE_HOLD" "ROLLOUT_BUDGET_SECONDS" -}}
{{- if (.Values.postgresCa | default dict).enabled }}{{ $reservedEnv = append $reservedEnv "NODE_EXTRA_CA_CERTS" }}{{ end -}}
{{- range .Values.extraEnv }}{{ if has .name $reservedEnv }}{{ fail (printf "%s is managed by structured chart values and must not appear in extraEnv" .name) }}{{ end }}{{ end -}}
{{- /* extraEnvFrom entries (EnvFromSource) carry no variable names to check;
the Deployment lists them before the chart ConfigMap so managed keys win. */ -}}
{{- range $key, $_ := .Values.extraConfig }}{{ if has $key $reservedEnv }}{{ fail (printf "%s is managed by structured chart values and must not appear in extraConfig" $key) }}{{ end }}{{ end -}}
{{- include "relayhistory.validatePostgresCa" . -}}
{{- end -}}
{{- define "relayhistory.secretEnv" -}}
- name: DATABASE_URL
  valueFrom:
    secretKeyRef:
      name: {{ .Values.database.existingSecret }}
      key: {{ .Values.database.keys.url | quote }}
{{- if .Values.embeddings.enabled }}
- name: EMBEDDING_API_KEY
  valueFrom:
    secretKeyRef:
      name: {{ default .Values.database.existingSecret .Values.embeddings.existingSecret }}
      key: {{ .Values.embeddings.key | quote }}
{{- end }}
{{- if .Values.sessionAnalysis.enabled }}
- name: OPENAI_API_KEY
  valueFrom:
    secretKeyRef:
      name: {{ default .Values.database.existingSecret .Values.sessionAnalysis.existingSecret }}
      key: {{ .Values.sessionAnalysis.key | quote }}
{{- end }}
{{- if .Values.telemetry.enabled }}
- name: POSTHOG_API_KEY
  valueFrom:
    secretKeyRef:
      name: {{ default .Values.database.existingSecret .Values.telemetry.existingSecret }}
      key: {{ .Values.telemetry.key | quote }}
{{- end }}
{{- end -}}
{{- define "relayhistory.migrationPodTemplate" -}}
metadata:
  labels:
    app.kubernetes.io/name: {{ include "relayhistory.name" . }}
    app.kubernetes.io/instance: {{ .Release.Name }}
    app.kubernetes.io/component: migration
spec:
  restartPolicy: Never
  serviceAccountName: {{ include "relayhistory.serviceAccountName" . }}
  automountServiceAccountToken: false
  securityContext: {{ toYaml .Values.podSecurityContext | nindent 4 }}
  {{- with .Values.imagePullSecrets }}
  imagePullSecrets: {{ toYaml . | nindent 4 }}
  {{- end }}
  {{- if .Values.migrations.drainForWriteHold }}
  # drainForWriteHold: scaling History to 0 is asynchronous, so the migration
  # starts only once no History pod of this release exists (terminating pods
  # included). Only this init container gets an API token (pods list in this
  # namespace, templates/drain-wait-rbac.yaml); the migrate container has none.
  initContainers:
    - name: wait-for-history-drain
      image: {{ include "relayhistory.image" . | quote }}
      imagePullPolicy: {{ .Values.image.pullPolicy }}
      args:
        - -e
        - |
            const fs = require('fs'), https = require('https');
            const d = '/var/run/drain-wait/';
            const ns = fs.readFileSync(d + 'namespace', 'utf8').trim();
            const deadline = Date.now() + Number(process.env.DRAIN_WAIT_SECONDS) * 1000;
            const path = '/api/v1/namespaces/' + ns + '/pods?labelSelector=' + encodeURIComponent(process.env.HISTORY_SELECTOR);
            // Each request is bounded by the remaining budget (at most 10 s), so
            // an API server that stops answering cannot outlast DRAIN_WAIT_SECONDS.
            const count = () => new Promise((resolve, reject) => {
              const timeout = Math.max(1000, Math.min(10000, deadline - Date.now()));
              const req = https.get({ host: process.env.KUBERNETES_SERVICE_HOST, port: process.env.KUBERNETES_SERVICE_PORT, path, ca: fs.readFileSync(d + 'ca.crt'), timeout,
                headers: { Authorization: 'Bearer ' + fs.readFileSync(d + 'token', 'utf8').trim() } }, (res) => {
                let body = '';
                res.on('data', (c) => { body += c; });
                res.on('end', () => res.statusCode === 200 ? resolve(JSON.parse(body).items.length) : reject(new Error('HTTP ' + res.statusCode)));
                res.on('error', reject);
              });
              req.on('timeout', () => req.destroy(new Error('request timed out after ' + timeout + 'ms')));
              req.on('error', reject);
            });
            (async () => {
              for (;;) {
                let n = -1;
                try { n = await count(); } catch (e) { console.error('listing History pods failed: ' + e.message); }
                if (n === 0) { console.log('no History pods remain; starting the write-hold migration'); return; }
                if (Date.now() >= deadline) { console.error('History pods still exist after ' + process.env.DRAIN_WAIT_SECONDS + 's; not migrating'); process.exit(1); }
                if (n > 0) console.log(n + ' History pod(s) still exist (including terminating); waiting');
                await new Promise((r) => setTimeout(r, 2000));
              }
            })();
      securityContext: {{ toYaml .Values.containerSecurityContext | nindent 8 }}
      env:
        - name: HISTORY_SELECTOR
          value: {{ printf "app.kubernetes.io/name=%s,app.kubernetes.io/instance=%s,app.kubernetes.io/component=history" (include "relayhistory.name" .) .Release.Name | quote }}
        - name: DRAIN_WAIT_SECONDS
          value: {{ .Values.migrations.drainWaitSeconds | int64 | toString | quote }}
      resources: {{ toYaml .Values.resources | nindent 8 }}
      volumeMounts:
        - { name: drain-wait-token, mountPath: /var/run/drain-wait, readOnly: true }
  {{- end }}
  containers:
    - name: migrate
      image: {{ include "relayhistory.image" . | quote }}
      imagePullPolicy: {{ .Values.image.pullPolicy }}
      args: [migrate.mjs]
      securityContext: {{ toYaml .Values.containerSecurityContext | nindent 8 }}
      env:
        - name: DATABASE_MIGRATIONS_URL
          valueFrom:
            secretKeyRef:
              name: {{ .Values.database.existingSecret }}
              key: {{ .Values.database.keys.migrationsUrl | quote }}
        - name: DATABASE_URL
          valueFrom:
            secretKeyRef:
              name: {{ .Values.database.existingSecret }}
              key: {{ .Values.database.keys.url | quote }}
        {{- with .Values.database.runtimeRole }}
        - { name: DATABASE_RUNTIME_ROLE, value: {{ . | quote }} }
        {{- end }}
        - { name: ALLOW_WRITE_HOLD, value: {{ ternary "yes" "no" .Values.migrations.allowWriteHold | quote }} }
        - { name: ROLLOUT_BUDGET_SECONDS, value: {{ .Values.migrations.rolloutBudgetSeconds | quote }} }
        {{- if (.Values.postgresCa | default dict).enabled }}
        - { name: NODE_EXTRA_CA_CERTS, value: /etc/postgres-ca/ca.crt }
        {{- end }}
      resources: {{ toYaml .Values.resources | nindent 8 }}
      volumeMounts:
        - { name: tmp, mountPath: /tmp }
        {{- if (.Values.postgresCa | default dict).enabled }}
        - { name: postgres-ca, mountPath: /etc/postgres-ca, readOnly: true }
        {{- end }}
  volumes:
    - name: tmp
      emptyDir: { sizeLimit: 64Mi }
    {{- if (.Values.postgresCa | default dict).enabled }}
    {{- include "relayhistory.postgresCaVolume" . | nindent 4 }}
    {{- end }}
    {{- if .Values.migrations.drainForWriteHold }}
    - name: drain-wait-token
      projected:
        sources:
          - serviceAccountToken: { path: token, expirationSeconds: 3607 }
          - configMap: { name: kube-root-ca.crt, items: [{ key: ca.crt, path: ca.crt }] }
          - downwardAPI: { items: [{ path: namespace, fieldRef: { fieldPath: metadata.namespace } }] }
    {{- end }}
{{- end -}}

{{- /* Optional Postgres server CA bundle (postgresCa.*). NODE_EXTRA_CA_CERTS adds the
mounted PEM to the roots node-pg verifies against for sslmode=verify-full. */ -}}
{{- define "relayhistory.postgresCaVolume" -}}
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
{{- define "relayhistory.validatePostgresCa" -}}
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
{{- end -}}
