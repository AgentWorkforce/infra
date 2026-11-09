{{- define "sessions-pipeline.nativeConsumer.name" -}}
{{- default (printf "%s-native-consumer" .Release.Name) .Values.nativeConsumer.fullnameOverride -}}
{{- end -}}
{{- define "sessions-pipeline.nativeConsumer.contractName" -}}
{{- $name := include "sessions-pipeline.nativeConsumer.name" . -}}
{{- $content := printf "%s\n%s\n%s" $name (.Files.Get "files/native-consumer/preflight.mjs") (.Files.Get "files/native-consumer/probe.mjs") -}}
{{- printf "%s-contract-%s" ($name | trunc 44 | trimSuffix "-") ($content | sha256sum | trunc 8) -}}
{{- end -}}
{{- define "sessions-pipeline.nativeConsumer.ref" -}}
{{- $value := required (printf "%s is required" .name) .value -}}
{{- if or (not (kindIs "string" $value)) (gt (len $value) 253) (not (regexMatch "^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?(\\.[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?)*$" $value)) }}{{ fail (printf "%s must be a Kubernetes DNS subdomain" .name) }}{{ end -}}
{{- $value -}}
{{- end -}}
{{- /* Walk configured runtime references, never Secret contents or the owner Job. */ -}}
{{- define "sessions-pipeline.nativeConsumer.noOwnerRuntimeRefs" -}}
{{- $owner := .owner -}}
{{- $value := .value -}}
{{- if kindIs "map" $value -}}
{{- range $key, $entry := $value -}}
{{- if and (has $key (list "existingSecret" "secretName" "secret")) (kindIs "string" $entry) (eq $entry $owner) }}{{ fail "nativeConsumer owner bootstrap Secret must not be referenced by runtime workloads" }}{{ end -}}
{{- if and (has $key (list "secretKeyRef" "secretRef" "nodePublishSecretRef" "secret")) (kindIs "map" $entry) -}}
{{- if and (kindIs "string" $entry.name) (eq $entry.name $owner) }}{{ fail "nativeConsumer owner bootstrap Secret must not be referenced by runtime workloads" }}{{ end -}}
{{- end -}}
{{- if and (eq $key "imagePullSecrets") (kindIs "slice" $entry) -}}
{{- range $ref := $entry -}}
{{- if and (kindIs "map" $ref) (kindIs "string" $ref.name) (eq $ref.name $owner) }}{{ fail "nativeConsumer owner bootstrap Secret must not be referenced by runtime workloads" }}{{ end -}}
{{- end -}}
{{- end -}}
{{- include "sessions-pipeline.nativeConsumer.noOwnerRuntimeRefs" (dict "owner" $owner "value" $entry) -}}
{{- end -}}
{{- else if kindIs "slice" $value -}}
{{- range $entry := $value }}{{ include "sessions-pipeline.nativeConsumer.noOwnerRuntimeRefs" (dict "owner" $owner "value" $entry) }}{{ end -}}
{{- end -}}
{{- end -}}
{{- define "sessions-pipeline.nativeConsumer.validate" -}}
{{- $c := .Values.nativeConsumer -}}
{{- range $name, $flag := dict "enabled" $c.enabled "migrationDriverVerified" $c.migrationDriverVerified "legacyRuntimesQualified" $c.legacyRuntimesQualified "legacyIndexerDrained" $c.legacyIndexerDrained "allowInClusterHttp" $c.allowInClusterHttp "bootstrap.enabled" $c.bootstrap.enabled -}}
{{- if not (kindIs "bool" $flag) }}{{ fail (printf "nativeConsumer.%s must be a boolean" $name) }}{{ end -}}
{{- end -}}
{{- if $c.enabled -}}
{{- if or (hasKey $c "extraEnv") (hasKey $c "envFrom") (hasKey $c "extraVolumes") (hasKey $c "extraVolumeMounts") (hasKey $c "command") }}{{ fail "nativeConsumer does not accept extraEnv/envFrom/command/extra volumes; use managed configuration and Secret references" }}{{ end -}}
{{- $indexer := index .Values.worker.components "hoopdb-indexer" -}}
{{- if or (not (kindIs "bool" $indexer.enabled)) $indexer.enabled }}{{ fail "nativeConsumer requires worker.components.hoopdb-indexer.enabled=false" }}{{ end -}}
{{- if not $c.legacyIndexerDrained }}{{ fail "nativeConsumer requires legacyIndexerDrained=true after the installed old indexer has been stopped" }}{{ end -}}
{{- if .Values.worker.migrations.enabled }}{{ fail "nativeConsumer requires worker.migrations.enabled=false; run the selected official migration driver separately and verify its no-op rerun first" }}{{ end -}}
{{- if not $c.migrationDriverVerified }}{{ fail "nativeConsumer requires migrationDriverVerified=true after the selected official migration driver and its no-op rerun passed" }}{{ end -}}
{{- $activeWorker := false -}}
{{- range $component, $entry := .Values.worker.components -}}
{{- if or (not (kindIs "bool" $entry.enabled)) (not (regexMatch "^(0|[1-9][0-9]*)$" (toString $entry.replicas))) }}{{ fail "nativeConsumer requires explicit boolean worker component enablement and nonnegative integer replicas" }}{{ end -}}
{{- if and $entry.enabled (gt (int $entry.replicas) 0) }}{{ $activeWorker = true }}{{ end -}}
{{- end -}}
{{- if not (regexMatch "^(0|[1-9][0-9]*)$" (toString .Values.alleyoop.ingest.replicas)) }}{{ fail "nativeConsumer requires nonnegative integer alleyoop.ingest.replicas" }}{{ end -}}
{{- $activeIngest := gt (int .Values.alleyoop.ingest.replicas) 0 -}}
{{- $nativeImage := printf "%s@%s" $c.image.repository $c.image.digest -}}
{{- if and $activeWorker (ne (include "sessions-pipeline-worker.image" .Subcharts.worker) $nativeImage) }}{{ fail "nativeConsumer requires every active legacy worker to resolve to the same qualified immutable image; disable or scale it to zero otherwise" }}{{ end -}}
{{- if and $activeIngest (ne (include "alleyoop.image" .Subcharts.alleyoop) $nativeImage) }}{{ fail "nativeConsumer requires active legacy alleyoop to resolve to the same qualified immutable image; scale it to zero otherwise" }}{{ end -}}
{{- if or $activeWorker $activeIngest -}}
{{- if not $c.legacyRuntimesQualified }}{{ fail "nativeConsumer requires legacyRuntimesQualified=true after active legacy runtimes pass strict URL/TLS/database/role/generation proof" }}{{ end -}}
{{- range $legacyTarget := list (dict "active" $activeWorker "ca" .Values.worker.postgresCa) (dict "active" $activeIngest "ca" .Values.alleyoop.postgresCa) -}}
{{- if $legacyTarget.active -}}
{{- if or (ne $legacyTarget.ca.enabled true) (ne $legacyTarget.ca.configMap $c.postgres.caConfigMap) $legacyTarget.ca.secret (ne $legacyTarget.ca.key $c.postgres.caKey) }}{{ fail "nativeConsumer requires active legacy runtimes to mount the same public CA ConfigMap/key through postgresCa" }}{{ end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- $name := include "sessions-pipeline.nativeConsumer.name" . -}}
{{- if or (gt (len $name) 63) (not (regexMatch "^[a-z]([-a-z0-9]*[a-z0-9])?$" $name)) }}{{ fail "nativeConsumer.fullnameOverride must be a DNS-1035 label of at most 63 characters" }}{{ end -}}
{{- if ne (toString $c.replicas) "1" }}{{ fail "nativeConsumer.replicas must be exactly 1" }}{{ end -}}
{{- $repository := required "nativeConsumer.image.repository is required" $c.image.repository -}}
{{- $repositoryPattern := "^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(:[0-9]{1,5})?/[a-z0-9]+(([._]|__|-+)[a-z0-9]+)*(/[a-z0-9]+(([._]|__|-+)[a-z0-9]+)*)*$" -}}
{{- $registryHost := regexReplaceAll ":[0-9]+$" (first (splitList "/" $repository)) "" -}}
{{- if or (hasKey $c.image "tag") (gt (len $registryHost) 253) (not (regexMatch $repositoryPattern $repository)) }}{{ fail "nativeConsumer.image.repository requires an explicit registry DNS host/path, without scheme, tag or digest; image.tag is not supported" }}{{ end -}}
{{- $registryPort := regexFind ":[0-9]+$" (first (splitList "/" $repository)) -}}
{{- if and $registryPort (or (lt (int (trimPrefix ":" $registryPort)) 1) (gt (int (trimPrefix ":" $registryPort)) 65535)) }}{{ fail "nativeConsumer.image.repository has an invalid registry port" }}{{ end -}}
{{- if not (regexMatch "^sha256:[a-f0-9]{64}$" (required "nativeConsumer.image.digest requires a qualified consumer image" $c.image.digest)) }}{{ fail "nativeConsumer.image.digest must be sha256:<64 lowercase hex characters>" }}{{ end -}}
{{- if not (has $c.image.pullPolicy (list "Always" "IfNotPresent" "Never")) }}{{ fail "nativeConsumer.image.pullPolicy is invalid" }}{{ end -}}
{{- if not (regexMatch "^[A-Za-z0-9._-]{1,128}$" (required "nativeConsumer.backendId is required" $c.backendId)) }}{{ fail "nativeConsumer.backendId has an invalid format" }}{{ end -}}
{{- $floor := required "nativeConsumer.completeSince requires an explicit coverage floor" $c.completeSince -}}
{{- if ne $floor "epoch" -}}
{{- if not (regexMatch "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]{1,3})?Z$" $floor) }}{{ fail "nativeConsumer.completeSince must be a UTC ISO timestamp or explicitly qualified epoch" }}{{ end -}}
{{- $_ := mustToDate "2006-01-02T15:04:05Z07:00" $floor -}}
{{- end -}}
{{- if ne $c.keyPrefix "96bulls" }}{{ fail "nativeConsumer.keyPrefix must be the bare ingest/reader root 96bulls, without an org suffix" }}{{ end -}}
{{- range $field, $n := dict "port" $c.port "reconcileEveryMinutes" $c.reconcileEveryMinutes "reconcileLookbackMinutes" $c.reconcileLookbackMinutes "preflight.timeoutSeconds" $c.preflight.timeoutSeconds "bootstrap.activeDeadlineSeconds" $c.bootstrap.activeDeadlineSeconds "postgres.port" $c.postgres.port -}}
{{- $min := ternary 1024 (ternary 30 1 (eq $field "preflight.timeoutSeconds")) (eq $field "port") -}}
{{- $max := ternary 65535 (ternary 1800 10080 (eq $field "preflight.timeoutSeconds")) (has $field (list "port" "postgres.port")) -}}
{{- if or (not (regexMatch "^[0-9]+$" (toString $n))) (lt (int $n) $min) (gt (int $n) $max) }}{{ fail (printf "nativeConsumer.%s is outside the supported integer range" $field) }}{{ end -}}
{{- end -}}
{{- if le (int $c.reconcileLookbackMinutes) (int $c.reconcileEveryMinutes) }}{{ fail "nativeConsumer.reconcileLookbackMinutes must exceed reconcileEveryMinutes" }}{{ end -}}
{{- if le (int $c.bootstrap.activeDeadlineSeconds) (int $c.preflight.timeoutSeconds) }}{{ fail "nativeConsumer.bootstrap.activeDeadlineSeconds must exceed preflight.timeoutSeconds" }}{{ end -}}
{{- $_ := include "sessions-pipeline.nativeConsumer.ref" (dict "name" "nativeConsumer.config.existingSecret" "value" $c.config.existingSecret) -}}
{{- $_ := include "sessions-pipeline.nativeConsumer.ref" (dict "name" "nativeConsumer.postgres.caConfigMap" "value" $c.postgres.caConfigMap) -}}
{{- if not (regexMatch "^[a-f0-9]{64}$" $c.postgres.caSha256) }}{{ fail "nativeConsumer.postgres.caSha256 must be 64 lowercase hex characters" }}{{ end -}}
{{- if or (gt (len $c.postgres.host) 253) (regexMatch "^[0-9]+(\\.[0-9]+){3}$" $c.postgres.host) (not (regexMatch "^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$" $c.postgres.host)) }}{{ fail "nativeConsumer.postgres.host requires an explicit DNS hostname" }}{{ end -}}
{{- if not (regexMatch "^[A-Za-z_][A-Za-z0-9_-]{0,62}$" $c.postgres.database) }}{{ fail "nativeConsumer.postgres.database requires an explicit database name" }}{{ end -}}
{{- if not (has $c.bootstrap.phase (list "prepare" "serve")) }}{{ fail "nativeConsumer.bootstrap.phase must be prepare or serve" }}{{ end -}}
{{- if $c.bootstrap.enabled -}}
{{- $_ := include "sessions-pipeline.nativeConsumer.ref" (dict "name" "nativeConsumer.bootstrap.existingSecret" "value" $c.bootstrap.existingSecret) -}}
{{- if or (not (regexMatch "^[A-Za-z_][A-Za-z0-9_-]{0,62}$" $c.bootstrap.ownerRole)) (has $c.bootstrap.ownerRole (list "search_consumer_runtime" "bulls96_read_api" "bulls96_session_ingest")) }}{{ fail "nativeConsumer.bootstrap.ownerRole must name a separate schema owner" }}{{ end -}}
{{- end -}}
{{- if not (kindIs "string" $c.bootstrap.existingSecret) }}{{ fail "nativeConsumer.bootstrap.existingSecret must be a string" }}{{ end -}}
{{- if $c.bootstrap.existingSecret -}}
{{- $owner := $c.bootstrap.existingSecret -}}
{{- /* Owner credentials remain Job-only after prepare has disabled the Job. */ -}}
{{- include "sessions-pipeline.nativeConsumer.noOwnerRuntimeRefs" (dict "owner" $owner "value" (omit $c "bootstrap")) -}}
{{- if .Values.readApi.enabled }}{{ include "sessions-pipeline.nativeConsumer.noOwnerRuntimeRefs" (dict "owner" $owner "value" .Values.readApi) }}{{ end -}}
{{- if .Values.ingestEdge.enabled }}{{ include "sessions-pipeline.nativeConsumer.noOwnerRuntimeRefs" (dict "owner" $owner "value" .Values.ingestEdge) }}{{ end -}}
{{- if $activeWorker }}{{ include "sessions-pipeline.nativeConsumer.noOwnerRuntimeRefs" (dict "owner" $owner "value" (omit .Values.worker "migrations")) }}{{ end -}}
{{- if $activeIngest }}{{ include "sessions-pipeline.nativeConsumer.noOwnerRuntimeRefs" (dict "owner" $owner "value" .Values.alleyoop) }}{{ end -}}
{{- end -}}
{{- range $key := list $c.config.key $c.postgres.caKey $c.bootstrap.key $c.locker.accessKeyIdKey $c.locker.secretAccessKeyKey -}}
{{- if or (not $key) (gt (len $key) 253) (not (regexMatch "^[A-Za-z0-9._-]+$" $key)) }}{{ fail "nativeConsumer Secret/CA keys must be nonempty Kubernetes key names" }}{{ end -}}
{{- end -}}
{{- if or (not (kindIs "string" $c.locker.bucket)) (not $c.locker.bucket) (ne (trim $c.locker.bucket) $c.locker.bucket) }}{{ fail "nativeConsumer.locker.bucket must be a nonempty literal without surrounding whitespace" }}{{ end -}}
{{- if not (regexMatch "^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$" $c.locker.region) }}{{ fail "nativeConsumer.locker.region must be a nonempty region label" }}{{ end -}}
{{- if not (has $c.locker.credentials.mode (list "secret" "podIdentity")) }}{{ fail "nativeConsumer.locker.credentials.mode must be secret or podIdentity" }}{{ end -}}
{{- if $c.locker.endpoint }}{{ $_ := include "sessions-pipeline.ingestEdge.endpoint" (dict "name" "nativeConsumer.locker.endpoint" "url" $c.locker.endpoint "allowHttp" $c.allowInClusterHttp) }}{{ end -}}
{{- if eq $c.locker.credentials.mode "secret" -}}
{{- $_ := required "nativeConsumer.locker.endpoint is required for static S3/MinIO credentials" $c.locker.endpoint -}}
{{- $_ := include "sessions-pipeline.nativeConsumer.ref" (dict "name" "nativeConsumer.locker.existingSecret" "value" $c.locker.existingSecret) -}}
{{- else -}}
{{- if $c.locker.existingSecret }}{{ fail "nativeConsumer podIdentity must not also select a static Locker Secret" }}{{ end -}}
{{- $_ := required "nativeConsumer podIdentity requires explicit serviceAccountName" $c.serviceAccountName -}}
{{- end -}}
{{- if $c.serviceAccountName }}{{ $_ := include "sessions-pipeline.nativeConsumer.ref" (dict "name" "nativeConsumer.serviceAccountName" "value" $c.serviceAccountName) }}{{ end -}}
{{- if .Values.ingestEdge.enabled -}}
{{- if or (ne $c.locker.bucket .Values.ingestEdge.locker.bucket) (ne $c.locker.endpoint .Values.ingestEdge.locker.endpoint) (ne $c.locker.region .Values.ingestEdge.locker.region) }}{{ fail "nativeConsumer Locker bucket/endpoint/region must match the enabled ingestEdge" }}{{ end -}}
{{- if or (ne $c.image.repository .Values.ingestEdge.image.repository) (ne $c.image.digest .Values.ingestEdge.image.digest) }}{{ fail "nativeConsumer and enabled ingestEdge require the same qualified composed image" }}{{ end -}}
{{- end -}}
{{- if .Values.readApi.enabled -}}
{{- if or (ne .Values.readApi.search.backend "postgres") (ne $c.completeSince .Values.readApi.completeSince) }}{{ fail "nativeConsumer and enabled readApi require postgres and the same completeSince" }}{{ end -}}
{{- if or (ne $c.image.repository .Values.readApi.image.repository) (ne $c.image.digest .Values.readApi.image.digest) }}{{ fail "nativeConsumer and enabled readApi require the same qualified composed image" }}{{ end -}}
{{- $reader := dict -}}
{{- range $e := .Values.readApi.extraEnv }}{{ $_ := set $reader $e.name $e }}{{ end -}}
{{- range $key, $value := dict "SEARCH_INDEX_POSTGRES_BACKEND_ID" $c.backendId "LOCKER_BUCKET" $c.locker.bucket "LOCKER_ENDPOINT" $c.locker.endpoint "LOCKER_REGION" $c.locker.region "PIPELINE_KEY_PREFIX" $c.keyPrefix "PIPELINE_ORG_FROM_PREFIX" "true" -}}
{{- $entry := index $reader $key | default dict -}}
{{- if or (not (hasKey $entry "value")) (not (kindIs "string" $entry.value)) (ne $entry.value $value) }}{{ fail (printf "nativeConsumer requires matching literal readApi.extraEnv %s" $key) }}{{ end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "sessions-pipeline.nativeConsumer.env" -}}
{{- $c := .root.Values.nativeConsumer -}}
- { name: SERVICE, value: {{ ternary "session-pipeline-consumer-bootstrap" "session-pipeline-consumer" .bootstrap }} }
- { name: RELAYHISTORY_SELFHOST_PIPELINE_CONSUMER, value: "true" }
- name: RELAYHISTORY_PIPELINE_CONSUMER_SECRET
  valueFrom:
    secretKeyRef:
      name: {{ ternary $c.bootstrap.existingSecret $c.config.existingSecret .bootstrap | quote }}
      key: {{ ternary $c.bootstrap.key $c.config.key .bootstrap | quote }}
- { name: HOOPDB_DB_MODE, value: selfhosted }
- { name: SEARCH_INDEX_BACKEND, value: postgres }
- { name: SEARCH_INDEX_POSTGRES_BACKEND_ID, value: {{ $c.backendId | quote }} }
- { name: READ_API_COMPLETE_SINCE, value: {{ $c.completeSince | quote }} }
- { name: PIPELINE_RUNTIME, value: workers }
- { name: PIPELINE_FANOUT, value: "off" }
- { name: PIPELINE_KEY_PREFIX, value: {{ $c.keyPrefix | quote }} }
- { name: PIPELINE_ORG_FROM_PREFIX, value: "true" }
- { name: CONSUMER_RECONCILE_EVERY_MINUTES, value: {{ $c.reconcileEveryMinutes | quote }} }
- { name: PIPELINE_RECONCILE_LOOKBACK_MINUTES, value: {{ $c.reconcileLookbackMinutes | quote }} }
- { name: SESSION_POSTGRES_TLS_PROFILE, value: custom-ca }
- { name: SESSION_POSTGRES_CA_FILE, value: /etc/native-consumer-postgres/ca.crt }
- { name: NATIVE_CONSUMER_CA_SOURCE_FILE, value: /var/run/native-consumer-ca-source/ca.crt }
- { name: SESSION_POSTGRES_CA_SHA256, value: {{ $c.postgres.caSha256 | quote }} }
- { name: ALLOW_IN_CLUSTER_HTTP, value: {{ $c.allowInClusterHttp | quote }} }
- { name: NATIVE_CONSUMER_PREFLIGHT_MODE, value: {{ ternary "bootstrap" "runtime" .bootstrap }} }
- { name: NATIVE_CONSUMER_EXPECTED_ROLE, value: {{ ternary $c.bootstrap.ownerRole "search_consumer_runtime" .bootstrap | quote }} }
- { name: NATIVE_CONSUMER_EXPECTED_DATABASE, value: {{ $c.postgres.database | quote }} }
- { name: NATIVE_CONSUMER_EXPECTED_HOST, value: {{ $c.postgres.host | quote }} }
- { name: NATIVE_CONSUMER_EXPECTED_PORT, value: {{ $c.postgres.port | quote }} }
- { name: NATIVE_CONSUMER_PREFLIGHT_TIMEOUT_SECONDS, value: {{ $c.preflight.timeoutSeconds | quote }} }
{{- if not .bootstrap }}
- { name: WORKER_HEALTH_PORT, value: {{ $c.port | quote }} }
- { name: CONSUMER_UNHEALTHY_FILE, value: /tmp/session-pipeline-consumer.unhealthy }
- { name: LOCKER_PROVIDER, value: s3 }
- { name: LOCKER_BUCKET, value: {{ $c.locker.bucket | quote }} }
{{- if $c.locker.endpoint }}
- { name: LOCKER_ENDPOINT, value: {{ $c.locker.endpoint | quote }} }
{{- end }}
- { name: LOCKER_REGION, value: {{ $c.locker.region | quote }} }
{{- if eq $c.locker.credentials.mode "secret" }}
- name: LOCKER_ACCESS_KEY_ID
  valueFrom:
    secretKeyRef: { name: {{ $c.locker.existingSecret | quote }}, key: {{ $c.locker.accessKeyIdKey | quote }} }
- name: LOCKER_SECRET_ACCESS_KEY
  valueFrom:
    secretKeyRef: { name: {{ $c.locker.existingSecret | quote }}, key: {{ $c.locker.secretAccessKeyKey | quote }} }
{{- end }}
{{- end }}
{{- end -}}

{{- define "sessions-pipeline.nativeConsumer.pod" -}}
{{- $c := .root.Values.nativeConsumer -}}
automountServiceAccountToken: false
terminationGracePeriodSeconds: 90
securityContext:
  runAsNonRoot: true
  runAsUser: 1000
  runAsGroup: 1000
  fsGroup: 1000
  seccompProfile: { type: RuntimeDefault }
{{- with $c.serviceAccountName }}
serviceAccountName: {{ . | quote }}
{{- end }}
{{- with $c.imagePullSecrets }}
imagePullSecrets: {{ toYaml . | nindent 2 }}
{{- end }}
{{- with $c.nodeSelector }}
nodeSelector: {{ toYaml . | nindent 2 }}
{{- end }}
{{- with $c.tolerations }}
tolerations: {{ toYaml . | nindent 2 }}
{{- end }}
{{- with $c.affinity }}
affinity: {{ toYaml . | nindent 2 }}
{{- end }}
initContainers:
  - name: native-consumer-contract
    image: {{ printf "%s@%s" $c.image.repository $c.image.digest | quote }}
    imagePullPolicy: {{ $c.image.pullPolicy }}
    command: [bun, /etc/native-consumer-contract/preflight.mjs]
    securityContext: &security
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities: { drop: [ALL] }
    env: &env
      {{- include "sessions-pipeline.nativeConsumer.env" . | nindent 6 }}
    resources: {{ toYaml $c.resources | nindent 6 }}
    volumeMounts:
      - { name: tmp, mountPath: /tmp }
      - { name: postgres-ca-source, mountPath: /var/run/native-consumer-ca-source, readOnly: true }
      - { name: postgres-ca, mountPath: /etc/native-consumer-postgres }
      - { name: contract, mountPath: /etc/native-consumer-contract, readOnly: true }
containers:
  - name: {{ ternary "bootstrap" "consumer" .bootstrap }}
    image: {{ printf "%s@%s" $c.image.repository $c.image.digest | quote }}
    imagePullPolicy: {{ $c.image.pullPolicy }}
    securityContext: *security
    env: *env
    {{- if not .bootstrap }}
    ports: [{ name: health, containerPort: {{ $c.port }}, protocol: TCP }]
    startupProbe:
      exec: { command: [bun, /etc/native-consumer-contract/probe.mjs, ready] }
      periodSeconds: 5
      timeoutSeconds: 3
      failureThreshold: 120
    readinessProbe:
      exec: { command: [bun, /etc/native-consumer-contract/probe.mjs, ready] }
      periodSeconds: 5
      timeoutSeconds: 3
    livenessProbe:
      exec: { command: [bun, /etc/native-consumer-contract/probe.mjs, live] }
      periodSeconds: 10
      timeoutSeconds: 3
    {{- end }}
    resources: {{ toYaml $c.resources | nindent 6 }}
    volumeMounts:
      - { name: tmp, mountPath: /tmp }
      - { name: postgres-ca, mountPath: /etc/native-consumer-postgres, readOnly: true }
      - { name: contract, mountPath: /etc/native-consumer-contract, readOnly: true }
volumes:
  - name: tmp
    emptyDir: { sizeLimit: 128Mi }
  - name: postgres-ca
    emptyDir: { medium: Memory, sizeLimit: 256Ki }
  - name: postgres-ca-source
    configMap:
      name: {{ $c.postgres.caConfigMap | quote }}
      defaultMode: 0444
      items: [{ key: {{ $c.postgres.caKey | quote }}, path: ca.crt }]
  - name: contract
    configMap:
      name: {{ include "sessions-pipeline.nativeConsumer.contractName" .root | quote }}
      defaultMode: 0444
{{- end -}}
