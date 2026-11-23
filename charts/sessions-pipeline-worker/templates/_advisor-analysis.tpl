{{/* coordination-advisor and session-analysis: validation and env. */}}

{{- define "sessions-pipeline-worker.validateAdvisor" -}}
{{- $comp := index .Values.components "coordination-advisor" | default dict -}}
{{- $a := .Values.coordinationAdvisor | default dict -}}
{{- if $comp.enabled -}}
{{- if ne (int $comp.replicas) 1 }}{{ fail "sessions-pipeline-worker: components.coordination-advisor.replicas must be 1 (its cooldown and hourly cap are not shared across replicas)" }}{{ end -}}
{{- if not (kindIs "bool" $a.run) }}{{ fail "sessions-pipeline-worker: coordinationAdvisor.run must be true or false" }}{{ end -}}
{{- if not (kindIs "slice" $a.workspaces) }}{{ fail "sessions-pipeline-worker: coordinationAdvisor.workspaces must be a list" }}{{ end -}}
{{- if not (has $a.factsBackend (list "clickhouse" "postgres")) }}{{ fail "sessions-pipeline-worker: coordinationAdvisor.factsBackend must be clickhouse or postgres" }}{{ end -}}
{{- if and $a.run (eq $a.factsBackend "clickhouse") (not $a.clickhouseSecret.name) }}{{ fail "sessions-pipeline-worker: coordinationAdvisor.clickhouseSecret.name is required with factsBackend=clickhouse and run=true" }}{{ end -}}
{{- range $k := list "intervalSeconds" "pairCooldownSeconds" "sessionHourlyCap" }}
{{- $n := get $a $k -}}
{{- if not (or (kindIs "invalid" $n) (eq (toString $n) "")) }}{{ if not (and (or (kindIs "int" $n) (kindIs "int64" $n) (kindIs "float64" $n)) (eq (float64 $n) (float64 (int64 $n))) (gt (int64 $n) 0)) }}{{ fail (printf "sessions-pipeline-worker: coordinationAdvisor.%s must be a positive integer or null" $k) }}{{ end }}{{ end -}}
{{- end }}
{{- $dm := $a.relayDm | default dict -}}
{{- if not (kindIs "bool" $dm.enabled) }}{{ fail "sessions-pipeline-worker: coordinationAdvisor.relayDm.enabled must be true or false" }}{{ end -}}
{{- if $dm.enabled -}}
{{- $u := $dm.url | default "" -}}
{{- if not (or (regexMatch "^https://[^/?#@]+(/[^?#]*)?$" $u) (regexMatch "^http://(localhost|127\\.0\\.0\\.1|\\[::1\\])(:[0-9]+)?(/[^?#]*)?$" $u)) }}{{ fail "sessions-pipeline-worker: coordinationAdvisor.relayDm.url must be https (http only on loopback) with no credentials, query or fragment" }}{{ end -}}
{{- if not $dm.tokenSecret.name }}{{ fail "sessions-pipeline-worker: coordinationAdvisor.relayDm.tokenSecret.name is required with relayDm.enabled=true" }}{{ end -}}
{{- end -}}
{{- if and $a.egress.enabled (empty $a.egress.to) }}{{ fail "sessions-pipeline-worker: coordinationAdvisor.egress.to must list destinations when egress.enabled=true (an empty to would allow every destination)" }}{{ end -}}
{{- if and $a.egress.enabled (not .Values.networkPolicy.enabled) }}{{ fail "sessions-pipeline-worker: coordinationAdvisor.egress requires networkPolicy.enabled (alone it would isolate the pod from DNS and the database)" }}{{ end -}}
{{- if and .Values.networkPolicy.enabled $a.run (or (eq $a.factsBackend "clickhouse") $dm.enabled) (not $a.egress.enabled) }}{{ fail "sessions-pipeline-worker: with networkPolicy.enabled, coordinationAdvisor.run=true needs coordinationAdvisor.egress for ClickHouse or the Relay URL" }}{{ end -}}
{{- end -}}
{{- /* Chart-managed and forbidden advisor names, refused in both env lists (extraEnv reaches every worker) whether or not the advisor is enabled. */ -}}
{{- $reserved := list "COORDINATION_ADVISOR_ENABLED" "READ_API_DIRECTORY_WORKSPACES" "COORDINATION_ADVISOR_FACTS_BACKEND" "COORDINATION_ADVISOR_INTERVAL_SECONDS" "COORDINATION_ADVISOR_PAIR_COOLDOWN_SECONDS" "COORDINATION_ADVISOR_SESSION_HOURLY_CAP" "COORDINATION_ADVISOR_RELAY_DM_ENABLED" "COORDINATION_ADVISOR_RELAY_URL" "COORDINATION_ADVISOR_RELAY_TOKEN" "COORDINATION_ADVISOR_INCARNATION_ENABLED" "SESSION_PIPELINE_SECRET_JSON" -}}
{{- range (.Values.extraEnv | default list) }}{{ if has (.name | default "") $reserved }}{{ fail (printf "sessions-pipeline-worker: extraEnv must not set %s: use coordinationAdvisor.* (COORDINATION_ADVISOR_INCARNATION_ENABLED is never set)" .name) }}{{ end }}{{ end -}}
{{- range ($comp.env | default list) }}{{ if has (.name | default "") $reserved }}{{ fail (printf "sessions-pipeline-worker: components.coordination-advisor.env must not set %s: use coordinationAdvisor.* (COORDINATION_ADVISOR_INCARNATION_ENABLED is never set)" .name) }}{{ end }}{{ end -}}
{{- end }}

{{- define "sessions-pipeline-worker.advisorEnv" -}}
{{- $a := .Values.coordinationAdvisor -}}
- { name: COORDINATION_ADVISOR_ENABLED, value: {{ ternary "true" "false" $a.run | quote }} }
- { name: READ_API_DIRECTORY_WORKSPACES, value: {{ join "," $a.workspaces | quote }} }
- { name: COORDINATION_ADVISOR_FACTS_BACKEND, value: {{ $a.factsBackend | quote }} }
{{- with $a.intervalSeconds }}
- { name: COORDINATION_ADVISOR_INTERVAL_SECONDS, value: {{ int64 . | toString | quote }} }
{{- end }}
{{- with $a.pairCooldownSeconds }}
- { name: COORDINATION_ADVISOR_PAIR_COOLDOWN_SECONDS, value: {{ int64 . | toString | quote }} }
{{- end }}
{{- with $a.sessionHourlyCap }}
- { name: COORDINATION_ADVISOR_SESSION_HOURLY_CAP, value: {{ int64 . | toString | quote }} }
{{- end }}
{{- if and (eq $a.factsBackend "clickhouse") $a.clickhouseSecret.name }}
- name: SESSION_PIPELINE_SECRET_JSON
  valueFrom: { secretKeyRef: { name: {{ $a.clickhouseSecret.name | quote }}, key: {{ $a.clickhouseSecret.key | quote }} } }
{{- end }}
- { name: COORDINATION_ADVISOR_RELAY_DM_ENABLED, value: {{ ternary "true" "false" $a.relayDm.enabled | quote }} }
{{- if $a.relayDm.enabled }}
- { name: COORDINATION_ADVISOR_RELAY_URL, value: {{ $a.relayDm.url | quote }} }
- name: COORDINATION_ADVISOR_RELAY_TOKEN
  valueFrom: { secretKeyRef: { name: {{ $a.relayDm.tokenSecret.name | quote }}, key: {{ $a.relayDm.tokenSecret.key | quote }} } }
{{- end }}
{{- end }}

{{- define "sessions-pipeline-worker.validateAnalysis" -}}
{{- $s := .Values.sessionAnalysis | default dict -}}
{{- if $s.enabled -}}
{{- if not (kindIs "bool" $s.run) }}{{ fail "sessions-pipeline-worker: sessionAnalysis.run must be true or false" }}{{ end -}}
{{- if ne (int $s.replicas) 1 }}{{ fail "sessions-pipeline-worker: sessionAnalysis.replicas must be 1" }}{{ end -}}
{{- $image := $s.image | default dict -}}
{{- if and (hasKey $image "tag") (not (kindIs "string" $image.tag)) }}{{ fail "sessions-pipeline-worker: sessionAnalysis.image.tag must be a string (quote numeric tags or use --set-string)" }}{{ end -}}
{{- if and $image.repository (not (or $image.tag $image.digest)) }}{{ fail "sessions-pipeline-worker: sessionAnalysis.image.repository needs image.tag or image.digest (pin the dedicated runner image)" }}{{ end -}}
{{- if and (not $image.repository) (or $image.tag $image.digest) }}{{ fail "sessions-pipeline-worker: sessionAnalysis.image.tag or image.digest needs image.repository" }}{{ end -}}
{{- if and $image.pullPolicy (not (has $image.pullPolicy (list "Always" "IfNotPresent" "Never"))) }}{{ fail "sessions-pipeline-worker: sessionAnalysis.image.pullPolicy must be Always, IfNotPresent, Never or empty" }}{{ end -}}
{{- range $k := list "bucket" "bucketRegion" "keyPrefix" }}{{ if not (get $s $k) }}{{ fail (printf "sessions-pipeline-worker: sessionAnalysis.%s is required when sessionAnalysis.enabled=true" $k) }}{{ end }}{{ end -}}
{{- if not $s.modelKeySecret.name }}{{ fail "sessions-pipeline-worker: sessionAnalysis.modelKeySecret.name is required when sessionAnalysis.enabled=true" }}{{ end -}}
{{- if not $s.databaseSecret.name }}{{ fail "sessions-pipeline-worker: sessionAnalysis.databaseSecret.name is required when sessionAnalysis.enabled=true (the runtime role's own login)" }}{{ end -}}
{{- $creds := $s.s3Credentials | default "podIdentity" -}}
{{- if not (has $creds (list "podIdentity" "static")) }}{{ fail "sessions-pipeline-worker: sessionAnalysis.s3Credentials must be podIdentity or static (IRSA is not supported; role is for local tests only)" }}{{ end -}}
{{- $keys := $s.s3KeysSecret | default dict -}}
{{- if eq $creds "static" -}}
{{- if not (regexMatch "^[a-z0-9]([-a-z0-9.]{0,251}[a-z0-9])?$" ($keys.name | default "")) }}{{ fail "sessions-pipeline-worker: sessionAnalysis.s3Credentials=static needs sessionAnalysis.s3KeysSecret.name, the name of an existing Secret holding the access key id and secret key" }}{{ end -}}
{{- range $k := list "accessKeyIdKey" "secretAccessKeyKey" }}{{ if not (regexMatch "^[-._a-zA-Z0-9]{1,253}$" ((get $keys $k) | default "")) }}{{ fail (printf "sessions-pipeline-worker: sessionAnalysis.s3KeysSecret.%s must be a Secret data key ([-._a-zA-Z0-9]) with s3Credentials=static" $k) }}{{ end }}{{ end -}}
{{- if eq $keys.accessKeyIdKey $keys.secretAccessKeyKey }}{{ fail "sessions-pipeline-worker: sessionAnalysis.s3KeysSecret.accessKeyIdKey and secretAccessKeyKey must be different keys" }}{{ end -}}
{{- else if $keys.name -}}
{{- fail "sessions-pipeline-worker: sessionAnalysis.s3KeysSecret is used only with s3Credentials=static (the runner refuses static keys with podIdentity)" -}}
{{- end -}}
{{- $endpoint := $s.s3Endpoint | default "" -}}
{{- if not (kindIs "string" $endpoint) }}{{ fail "sessions-pipeline-worker: sessionAnalysis.s3Endpoint must be a string" }}{{ end -}}
{{- $allowHttp := $s.allowInClusterHttp | default false -}}
{{- if not (kindIs "bool" $allowHttp) }}{{ fail "sessions-pipeline-worker: sessionAnalysis.allowInClusterHttp must be true or false" }}{{ end -}}
{{- if $endpoint -}}
{{- $label := "[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?" -}}
{{- $port := "(:[0-9]{1,5})?/?" -}}
{{- /* https: any well-formed lowercase host, as the runner allows (TLS is the boundary; IP literals and single labels included). */ -}}
{{- $https := regexMatch (printf "^https://%s(\\.%s)*%s$" $label $label $port) $endpoint -}}
{{- $loopback := regexMatch (printf "^http://(localhost|127\\.0\\.0\\.1|\\[::1\\])%s$" $port) $endpoint -}}
{{- $service := regexMatch (printf "^http://%s\\.%s\\.svc(\\.cluster\\.local)?%s$" $label $label $port) $endpoint -}}
{{- if not (or $https $loopback $service) }}{{ fail "sessions-pipeline-worker: sessionAnalysis.s3Endpoint must be a bare lowercase origin: https://<host>[:port], or plain http only to loopback or a Kubernetes Service name <svc>.<ns>.svc[.cluster.local] (no credentials, path, query or fragment)" }}{{ end -}}
{{- $explicitPort := regexFind ":[0-9]+/?$" $endpoint | trimPrefix ":" | trimSuffix "/" -}}
{{- if and $explicitPort (or (lt (atoi $explicitPort) 1) (gt (atoi $explicitPort) 65535)) }}{{ fail "sessions-pipeline-worker: sessionAnalysis.s3Endpoint port must be from 1 to 65535" }}{{ end -}}
{{- if and $service (not $allowHttp) }}{{ fail "sessions-pipeline-worker: a plain-http in-cluster sessionAnalysis.s3Endpoint needs sessionAnalysis.allowInClusterHttp=true (the runner refuses it otherwise)" }}{{ end -}}
{{- if regexMatch "^https?://(storage\\.googleapis\\.com|.+\\.storage\\.googleapis\\.com|storage\\.google\\.com)\\.?(:[0-9]+)?/?$" $endpoint }}{{ fail "sessions-pipeline-worker: sessionAnalysis.s3Endpoint must not be the GCS API host (the runner refuses GCS as provider_unsupported)" }}{{ end -}}
{{- else if $allowHttp -}}
{{- fail "sessions-pipeline-worker: sessionAnalysis.allowInClusterHttp=true needs sessionAnalysis.s3Endpoint (the runner reads it only with an endpoint)" -}}
{{- end -}}
{{- $check := $s.s3VersioningCheck -}}
{{- if not (or (kindIs "invalid" $check) (eq (toString $check) "") (eq (toString $check) "true")) }}{{ fail "sessions-pipeline-worker: sessionAnalysis.s3VersioningCheck must be \"\" (the runner decides: on with s3Endpoint or static keys) or \"true\"; the check cannot be turned off" }}{{ end -}}
{{- if ne (.Values.locker.provider | default "s3") "s3" }}{{ fail "sessions-pipeline-worker: sessionAnalysis reads canonical evidence from S3 only; it requires locker.provider=s3" }}{{ end -}}
{{- $t := $s.postgresTls | default dict -}}
{{- if not (has ($t.profile | default "") (list "" "supabase" "custom-ca")) }}{{ fail "sessions-pipeline-worker: sessionAnalysis.postgresTls.profile must be empty, supabase or custom-ca" }}{{ end -}}
{{- if and (eq $t.profile "custom-ca") (or (not $t.caConfigMap) (not (regexMatch "^[a-f0-9]{64}$" ($t.sha256 | default "")))) }}{{ fail "sessions-pipeline-worker: sessionAnalysis.postgresTls.profile=custom-ca needs caConfigMap and a 64-hex sha256" }}{{ end -}}
{{- $bounds := dict "tickMs" (list 1000 600000) "batch" (list 1 20) "pgPoolMax" (list 1 16) -}}
{{- range $k, $b := $bounds }}
{{- $n := get $s $k -}}
{{- if not (or (kindIs "invalid" $n) (eq (toString $n) "")) }}{{ if not (and (or (kindIs "int" $n) (kindIs "int64" $n) (kindIs "float64" $n)) (eq (float64 $n) (float64 (int64 $n))) (ge (int64 $n) (int64 (index $b 0))) (le (int64 $n) (int64 (index $b 1)))) }}{{ fail (printf "sessions-pipeline-worker: sessionAnalysis.%s must be an integer from %v to %v, or null" $k (index $b 0) (index $b 1)) }}{{ end }}{{ end -}}
{{- end }}
{{- if not (has ($s.decisionRecords | default "") (list "" "true" "false")) }}{{ fail "sessions-pipeline-worker: sessionAnalysis.decisionRecords must be empty, \"true\" or \"false\"" }}{{ end -}}
{{- if and $s.modelEgress.enabled (empty $s.modelEgress.to) }}{{ fail "sessions-pipeline-worker: sessionAnalysis.modelEgress.to must list destinations when modelEgress.enabled=true (an empty to would allow every destination)" }}{{ end -}}
{{- if and $s.modelEgress.enabled (not .Values.networkPolicy.enabled) }}{{ fail "sessions-pipeline-worker: sessionAnalysis.modelEgress requires networkPolicy.enabled (alone it would isolate the pod from DNS, the database, object storage and, with podIdentity, the Pod Identity agent)" }}{{ end -}}
{{- if and .Values.networkPolicy.enabled $s.run (not $s.modelEgress.enabled) }}{{ fail "sessions-pipeline-worker: with networkPolicy.enabled, sessionAnalysis.run=true needs sessionAnalysis.modelEgress for the model API" }}{{ end -}}
{{- if and .Values.networkPolicy.enabled (eq $creds "podIdentity") (empty (dig "workloadIdentity" "to" (list) .Values.networkPolicy)) }}{{ fail "sessions-pipeline-worker: sessionAnalysis with s3Credentials=podIdentity uses EKS Pod Identity; with networkPolicy.enabled, networkPolicy.workloadIdentity.to must list the Pod Identity agent" }}{{ end -}}
{{- end -}}
{{- end }}

{{- define "sessions-pipeline-worker.analysisServiceAccountName" -}}
{{- .Values.sessionAnalysis.serviceAccount.name | default (include "sessions-pipeline-worker.componentName" (dict "context" . "component" "session-analysis")) -}}
{{- end }}
