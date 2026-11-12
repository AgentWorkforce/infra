{{/* Default-off, fail-closed operator session erase composition. */}}
{{- define "sessions-pipeline.operatorSessionErase.ref" -}}
{{- $value := required (printf "%s is required" .name) .value -}}
{{- if or (not (kindIs "string" $value)) (gt (len $value) 253) (not (regexMatch "^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?(\\.[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?)*$" $value)) }}{{ fail (printf "%s must be a Kubernetes Secret name" .name) }}{{ end -}}
{{- $value -}}
{{- end -}}

{{- define "sessions-pipeline.operatorSessionErase.key" -}}
{{- $value := required (printf "%s is required" .name) .value -}}
{{- if or (not (kindIs "string" $value)) (gt (len $value) 253) (not (regexMatch "^[A-Za-z0-9._-]+$" $value)) }}{{ fail (printf "%s must be a Kubernetes Secret data key" .name) }}{{ end -}}
{{- $value -}}
{{- end -}}

{{- define "sessions-pipeline.operatorSessionErase.validate" -}}
{{- $global := .Values.global.operatorSessionErase | default dict -}}
{{- if not (kindIs "map" $global) }}{{ fail "global.operatorSessionErase must be an object" }}{{ end -}}
{{- if not (kindIs "bool" $global.fenceEnforced) }}{{ fail "global.operatorSessionErase.fenceEnforced must be a boolean" }}{{ end -}}
{{- $erase := .Values.operatorSessionErase -}}
{{- if not (kindIs "map" $erase) }}{{ fail "operatorSessionErase must be an object" }}{{ end -}}
{{- if not (kindIs "map" $erase.api) }}{{ fail "operatorSessionErase.api must be an object" }}{{ end -}}
{{- if not (kindIs "map" $erase.bytes) }}{{ fail "operatorSessionErase.bytes must be an object" }}{{ end -}}
{{- range $name, $flag := dict "api.enabled" $erase.api.enabled "bytes.enabled" $erase.bytes.enabled -}}
{{- if not (kindIs "bool" $flag) }}{{ fail (printf "operatorSessionErase.%s must be a boolean" $name) }}{{ end -}}
{{- end -}}
{{- $selected := or $erase.api.enabled $erase.bytes.enabled -}}
{{- if and $selected (not $global.fenceEnforced) }}{{ fail "operatorSessionErase API or bytes requires global.operatorSessionErase.fenceEnforced=true" }}{{ end -}}

{{- if $global.fenceEnforced -}}
{{- if not .Values.ingestEdge.enabled }}{{ fail "global.operatorSessionErase.fenceEnforced=true requires ingestEdge.enabled=true" }}{{ end -}}
{{- if ne .Values.ingestEdge.admission.mode "sync" }}{{ fail "operator session erase requires ingestEdge.admission.mode=sync; async and drain have no writer-drain protocol" }}{{ end -}}
{{- if ne .Values.ingestEdge.uploadDirect.mode "off" }}{{ fail "operator session erase requires ingestEdge.uploadDirect.mode=off (HISTORY_UPLOAD_DIRECT must remain off)" }}{{ end -}}
{{- if not .Values.sessionReadApi.enabled }}{{ fail "operator session erase requires sessionReadApi.enabled=true so every read replica enforces the permanent fence" }}{{ end -}}
{{- $native := .Values.nativeConsumer.enabled -}}
{{- $indexer := .Values.searchIndexer.enabled -}}
{{- if eq $native $indexer }}{{ fail "operator session erase requires exactly one enabled consumer: nativeConsumer or searchIndexer" }}{{ end -}}
{{- if and $native .Values.nativeConsumer.bootstrap.enabled (eq .Values.nativeConsumer.bootstrap.phase "prepare") }}{{ fail "operator session erase requires the nativeConsumer runtime Deployment; bootstrap.phase=prepare renders only the owner Job" }}{{ end -}}

{{- $consumer := ternary .Values.nativeConsumer .Values.searchIndexer $native -}}
{{- $backend := ternary "postgres" .Values.searchIndexer.search.backend $native -}}
{{- $backendId := ternary .Values.nativeConsumer.backendId .Values.searchIndexer.search.backendId $native -}}
{{- $completeSince := ternary .Values.nativeConsumer.completeSince .Values.searchIndexer.completeSince $native -}}
{{- $keyRoot := ternary .Values.nativeConsumer.keyPrefix .Values.searchIndexer.keyPrefix $native -}}
{{- if ne .Values.sessionReadApi.search.backend $backend }}{{ fail "operator session erase requires the read API and active consumer to use the same search backend" }}{{ end -}}
{{- if ne .Values.sessionReadApi.search.backendId $backendId }}{{ fail "operator session erase requires the read API and active consumer to use the same search backendId" }}{{ end -}}
{{- if ne .Values.sessionReadApi.completeSince $completeSince }}{{ fail "operator session erase requires the read API and active consumer to use the same completeSince" }}{{ end -}}
{{- if ne .Values.ingestEdge.keyRoot $keyRoot }}{{ fail "operator session erase requires the ingest and active consumer key roots to match" }}{{ end -}}
{{- if or (ne .Values.ingestEdge.locker.bucket $consumer.locker.bucket) (ne .Values.ingestEdge.locker.endpoint $consumer.locker.endpoint) (ne .Values.ingestEdge.locker.region $consumer.locker.region) }}{{ fail "operator session erase requires the ingest and active consumer Locker bucket/endpoint/region to match" }}{{ end -}}
{{- if eq $backend "opensearch" -}}
{{- if or (ne .Values.sessionReadApi.search.opensearch.url .Values.searchIndexer.search.opensearch.url) (ne .Values.sessionReadApi.search.opensearch.region .Values.searchIndexer.search.opensearch.region) (ne .Values.sessionReadApi.search.opensearch.indexPrefix .Values.searchIndexer.search.opensearch.indexPrefix) }}{{ fail "operator session erase requires the read API and searchIndexer OpenSearch target to match" }}{{ end -}}
{{- end -}}

{{- $reader := dict -}}
{{- range $entry := .Values.sessionReadApi.extraEnv }}{{ $_ := set $reader $entry.name $entry }}{{ end -}}
{{- range $name, $value := dict "LOCKER_BUCKET" .Values.ingestEdge.locker.bucket "LOCKER_REGION" .Values.ingestEdge.locker.region "PIPELINE_KEY_PREFIX" .Values.ingestEdge.keyRoot "PIPELINE_ORG_FROM_PREFIX" "true" -}}
{{- $entry := index $reader $name | default dict -}}
{{- if or (not (hasKey $entry "value")) (not (kindIs "string" $entry.value)) (ne $entry.value $value) }}{{ fail (printf "operator session erase requires literal sessionReadApi.extraEnv %s matching ingestEdge" $name) }}{{ end -}}
{{- end -}}
{{- if .Values.ingestEdge.locker.endpoint -}}
{{- $entry := index $reader "LOCKER_ENDPOINT" | default dict -}}
{{- if or (not (hasKey $entry "value")) (not (kindIs "string" $entry.value)) (ne $entry.value .Values.ingestEdge.locker.endpoint) }}{{ fail "operator session erase requires literal sessionReadApi.extraEnv LOCKER_ENDPOINT matching ingestEdge" }}{{ end -}}
{{- end -}}
{{- end -}}

{{- if $erase.api.enabled -}}
{{- $apiSecret := include "sessions-pipeline.operatorSessionErase.ref" (dict "name" "operatorSessionErase.api.existingSecret" "value" $erase.api.existingSecret) -}}
{{- $apiKey := include "sessions-pipeline.operatorSessionErase.key" (dict "name" "operatorSessionErase.api.secretKey" "value" $erase.api.secretKey) -}}
{{- if or (eq $apiSecret .Values.ingestEdge.config.existingSecret) (eq $apiSecret .Values.ingestEdge.locker.existingSecret) }}{{ fail "operatorSessionErase.api requires a dedicated Secret, separate from ingest runtime and Locker credentials" }}{{ end -}}
{{- if $erase.api.previousSecretKey -}}
{{- $previous := include "sessions-pipeline.operatorSessionErase.key" (dict "name" "operatorSessionErase.api.previousSecretKey" "value" $erase.api.previousSecretKey) -}}
{{- if eq $previous $apiKey }}{{ fail "operatorSessionErase.api.previousSecretKey must differ from secretKey" }}{{ end -}}
{{- end -}}
{{- end -}}

{{- if $erase.bytes.enabled -}}
{{- if ne .Values.ingestEdge.locker.provider "s3" }}{{ fail "operatorSessionErase.bytes requires ingestEdge.locker.provider=s3" }}{{ end -}}
{{- if lt (int .Values.ingestEdge.postgres.poolMax) 2 }}{{ fail "operatorSessionErase.bytes requires ingestEdge.postgres.poolMax at least 2" }}{{ end -}}
{{- $s3 := $erase.bytes.s3Credentials -}}
{{- if not (kindIs "map" $s3) }}{{ fail "operatorSessionErase.bytes.s3Credentials must be an object" }}{{ end -}}
{{- $s3Secret := include "sessions-pipeline.operatorSessionErase.ref" (dict "name" "operatorSessionErase.bytes.s3Credentials.existingSecret" "value" $s3.existingSecret) -}}
{{- $s3Access := include "sessions-pipeline.operatorSessionErase.key" (dict "name" "operatorSessionErase.bytes.s3Credentials.accessKeyIdKey" "value" $s3.accessKeyIdKey) -}}
{{- $s3Key := include "sessions-pipeline.operatorSessionErase.key" (dict "name" "operatorSessionErase.bytes.s3Credentials.secretAccessKeyKey" "value" $s3.secretAccessKeyKey) -}}
{{- if eq $s3Access $s3Key }}{{ fail "operatorSessionErase.bytes.s3Credentials requires distinct access and secret keys" }}{{ end -}}
{{- if or (eq $s3Secret .Values.ingestEdge.config.existingSecret) (eq $s3Secret .Values.ingestEdge.locker.existingSecret) }}{{ fail "operatorSessionErase.bytes.s3Credentials requires a dedicated eraser Secret, never ingest writer credentials" }}{{ end -}}
{{- if and $erase.api.enabled (eq $s3Secret $erase.api.existingSecret) }}{{ fail "operatorSessionErase API and S3 eraser credentials require separate Secrets" }}{{ end -}}
{{- $backend := ternary "postgres" .Values.searchIndexer.search.backend .Values.nativeConsumer.enabled -}}
{{- if eq $backend "postgres" -}}
{{- $search := $erase.bytes.postgresSearch -}}
{{- if not (kindIs "map" $search) }}{{ fail "operatorSessionErase.bytes.postgresSearch must be an object" }}{{ end -}}
{{- $searchSecret := include "sessions-pipeline.operatorSessionErase.ref" (dict "name" "operatorSessionErase.bytes.postgresSearch.existingSecret" "value" $search.existingSecret) -}}
{{- $_ := include "sessions-pipeline.operatorSessionErase.key" (dict "name" "operatorSessionErase.bytes.postgresSearch.urlKey" "value" $search.urlKey) -}}
{{- if eq $searchSecret $s3Secret }}{{ fail "operatorSessionErase Postgres search and S3 eraser credentials require separate Secrets" }}{{ end -}}
{{- if $erase.bytes.opensearch.existingSecret }}{{ fail "operatorSessionErase.bytes.opensearch must stay empty with the postgres search backend" }}{{ end -}}
{{- else if eq $backend "opensearch" -}}
{{- $search := $erase.bytes.opensearch -}}
{{- if not (kindIs "map" $search) }}{{ fail "operatorSessionErase.bytes.opensearch must be an object" }}{{ end -}}
{{- $searchSecret := include "sessions-pipeline.operatorSessionErase.ref" (dict "name" "operatorSessionErase.bytes.opensearch.existingSecret" "value" $search.existingSecret) -}}
{{- $username := include "sessions-pipeline.operatorSessionErase.key" (dict "name" "operatorSessionErase.bytes.opensearch.usernameKey" "value" $search.usernameKey) -}}
{{- $password := include "sessions-pipeline.operatorSessionErase.key" (dict "name" "operatorSessionErase.bytes.opensearch.passwordKey" "value" $search.passwordKey) -}}
{{- if eq $username $password }}{{ fail "operatorSessionErase.bytes.opensearch requires distinct username and password keys" }}{{ end -}}
{{- if eq $searchSecret $s3Secret }}{{ fail "operatorSessionErase OpenSearch and S3 eraser credentials require separate Secrets" }}{{ end -}}
{{- if $erase.bytes.postgresSearch.existingSecret }}{{ fail "operatorSessionErase.bytes.postgresSearch must stay empty with the opensearch backend" }}{{ end -}}
{{- else -}}
{{- fail "operatorSessionErase.bytes requires postgres or opensearch search" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "sessions-pipeline.operatorSessionErase.fenceEnv" -}}
{{- if .Values.global.operatorSessionErase.fenceEnforced }}
- { name: SESSION_ERASE_FENCE_ENFORCED, value: "1" }
{{- end }}
{{- end -}}

{{- define "sessions-pipeline.operatorSessionErase.ingestEnv" -}}
{{- include "sessions-pipeline.operatorSessionErase.fenceEnv" . }}
{{- $erase := .Values.operatorSessionErase -}}
{{- if $erase.api.enabled }}
- { name: SESSION_ERASE_API_ENABLED, value: "1" }
- name: SESSION_ERASE_API_SECRET
  valueFrom:
    secretKeyRef: { name: {{ $erase.api.existingSecret | quote }}, key: {{ $erase.api.secretKey | quote }} }
{{- with $erase.api.previousSecretKey }}
- name: SESSION_ERASE_API_SECRET_PREVIOUS
  valueFrom:
    secretKeyRef: { name: {{ $erase.api.existingSecret | quote }}, key: {{ . | quote }} }
{{- end }}
{{- end }}
{{- if $erase.bytes.enabled }}
- { name: SESSION_ERASE_BYTES_ENABLED, value: "1" }
- { name: SESSION_ERASE_S3_BUCKET, value: {{ .Values.ingestEdge.locker.bucket | quote }} }
- { name: SESSION_ERASE_S3_REGION, value: {{ .Values.ingestEdge.locker.region | quote }} }
{{- with .Values.ingestEdge.locker.endpoint }}
- { name: SESSION_ERASE_S3_ENDPOINT, value: {{ . | quote }} }
{{- end }}
- { name: SESSION_ERASE_KEY_ROOT, value: {{ .Values.ingestEdge.keyRoot | quote }} }
- name: SESSION_ERASE_S3_ACCESS_KEY_ID
  valueFrom:
    secretKeyRef: { name: {{ $erase.bytes.s3Credentials.existingSecret | quote }}, key: {{ $erase.bytes.s3Credentials.accessKeyIdKey | quote }} }
- name: SESSION_ERASE_S3_SECRET_ACCESS_KEY
  valueFrom:
    secretKeyRef: { name: {{ $erase.bytes.s3Credentials.existingSecret | quote }}, key: {{ $erase.bytes.s3Credentials.secretAccessKeyKey | quote }} }
{{- $backend := ternary "postgres" .Values.searchIndexer.search.backend .Values.nativeConsumer.enabled }}
- { name: SEARCH_INDEX_BACKEND, value: {{ $backend | quote }} }
{{- if eq $backend "postgres" }}
- name: SESSION_ERASE_SEARCH_POSTGRES_URL
  valueFrom:
    secretKeyRef: { name: {{ $erase.bytes.postgresSearch.existingSecret | quote }}, key: {{ $erase.bytes.postgresSearch.urlKey | quote }} }
{{- else }}
- { name: SEARCH_INDEX_OPENSEARCH_URL, value: {{ .Values.searchIndexer.search.opensearch.url | quote }} }
{{- with .Values.searchIndexer.search.opensearch.indexPrefix }}
- { name: SEARCH_INDEX_OPENSEARCH_INDEX_PREFIX, value: {{ . | quote }} }
{{- end }}
- name: SESSION_ERASE_OPENSEARCH_USERNAME
  valueFrom:
    secretKeyRef: { name: {{ $erase.bytes.opensearch.existingSecret | quote }}, key: {{ $erase.bytes.opensearch.usernameKey | quote }} }
- name: SESSION_ERASE_OPENSEARCH_PASSWORD
  valueFrom:
    secretKeyRef: { name: {{ $erase.bytes.opensearch.existingSecret | quote }}, key: {{ $erase.bytes.opensearch.passwordKey | quote }} }
{{- end }}
{{- end }}
{{- end -}}
