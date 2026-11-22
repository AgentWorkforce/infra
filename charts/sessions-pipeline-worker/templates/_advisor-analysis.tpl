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
{{- if not (kindIs "invalid" $n) }}{{ if not (and (or (kindIs "int" $n) (kindIs "int64" $n) (kindIs "float64" $n)) (eq (float64 $n) (float64 (int64 $n))) (gt (int64 $n) 0)) }}{{ fail (printf "sessions-pipeline-worker: coordinationAdvisor.%s must be a positive integer or null" $k) }}{{ end }}{{ end -}}
{{- end }}
{{- $dm := $a.relayDm | default dict -}}
{{- if not (kindIs "bool" $dm.enabled) }}{{ fail "sessions-pipeline-worker: coordinationAdvisor.relayDm.enabled must be true or false" }}{{ end -}}
{{- if $dm.enabled -}}
{{- $u := $dm.url | default "" -}}
{{- if not (or (regexMatch "^https://[^/?#@]+(/[^?#]*)?$" $u) (regexMatch "^http://(localhost|127\\.0\\.0\\.1|\\[::1\\])(:[0-9]+)?(/[^?#]*)?$" $u)) }}{{ fail "sessions-pipeline-worker: coordinationAdvisor.relayDm.url must be https (http only on loopback) with no credentials, query or fragment" }}{{ end -}}
{{- if not $dm.tokenSecret.name }}{{ fail "sessions-pipeline-worker: coordinationAdvisor.relayDm.tokenSecret.name is required with relayDm.enabled=true" }}{{ end -}}
{{- end -}}
{{- if and $a.egress.enabled (empty $a.egress.to) }}{{ fail "sessions-pipeline-worker: coordinationAdvisor.egress.to must list destinations when egress.enabled=true (an empty to would allow every destination)" }}{{ end -}}
{{- $reserved := list "COORDINATION_ADVISOR_ENABLED" "READ_API_DIRECTORY_WORKSPACES" "COORDINATION_ADVISOR_FACTS_BACKEND" "COORDINATION_ADVISOR_RELAY_DM_ENABLED" "COORDINATION_ADVISOR_RELAY_URL" "COORDINATION_ADVISOR_RELAY_TOKEN" "SESSION_PIPELINE_SECRET_JSON" -}}
{{- range ($comp.env | default list) }}{{ if has (.name | default "") $reserved }}{{ fail (printf "sessions-pipeline-worker: components.coordination-advisor.env must not set %s: use coordinationAdvisor.*" .name) }}{{ end }}{{ end -}}
{{- end -}}
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
{{- if $a.relayDm.enabled }}
- { name: COORDINATION_ADVISOR_RELAY_DM_ENABLED, value: "true" }
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
{{- range $k := list "bucket" "bucketRegion" "keyPrefix" }}{{ if not (get $s $k) }}{{ fail (printf "sessions-pipeline-worker: sessionAnalysis.%s is required when sessionAnalysis.enabled=true" $k) }}{{ end }}{{ end -}}
{{- if not $s.modelKeySecret.name }}{{ fail "sessions-pipeline-worker: sessionAnalysis.modelKeySecret.name is required when sessionAnalysis.enabled=true" }}{{ end -}}
{{- if not $s.databaseSecret.name }}{{ fail "sessions-pipeline-worker: sessionAnalysis.databaseSecret.name is required when sessionAnalysis.enabled=true (the runtime role's own login)" }}{{ end -}}
{{- if ne ($s.s3Credentials | default "podIdentity") "podIdentity" }}{{ fail "sessions-pipeline-worker: sessionAnalysis.s3Credentials must be podIdentity (IRSA and static keys are not supported in a pod)" }}{{ end -}}
{{- if eq (.Values.locker.provider | default "s3") "gcs" }}{{ fail "sessions-pipeline-worker: sessionAnalysis reads canonical evidence from S3 only; it is not supported with locker.provider=gcs" }}{{ end -}}
{{- $t := $s.postgresTls | default dict -}}
{{- if not (has ($t.profile | default "") (list "" "supabase" "custom-ca")) }}{{ fail "sessions-pipeline-worker: sessionAnalysis.postgresTls.profile must be empty, supabase or custom-ca" }}{{ end -}}
{{- if and (eq $t.profile "custom-ca") (or (not $t.caConfigMap) (not (regexMatch "^[a-f0-9]{64}$" ($t.sha256 | default "")))) }}{{ fail "sessions-pipeline-worker: sessionAnalysis.postgresTls.profile=custom-ca needs caConfigMap and a 64-hex sha256" }}{{ end -}}
{{- $bounds := dict "tickMs" (list 1000 600000) "batch" (list 1 20) "pgPoolMax" (list 1 16) -}}
{{- range $k, $b := $bounds }}
{{- $n := get $s $k -}}
{{- if not (kindIs "invalid" $n) }}{{ if not (and (or (kindIs "int" $n) (kindIs "int64" $n) (kindIs "float64" $n)) (eq (float64 $n) (float64 (int64 $n))) (ge (int64 $n) (int64 (index $b 0))) (le (int64 $n) (int64 (index $b 1)))) }}{{ fail (printf "sessions-pipeline-worker: sessionAnalysis.%s must be an integer from %v to %v, or null" $k (index $b 0) (index $b 1)) }}{{ end }}{{ end -}}
{{- end }}
{{- if not (has ($s.decisionRecords | default "") (list "" "true" "false")) }}{{ fail "sessions-pipeline-worker: sessionAnalysis.decisionRecords must be empty, \"true\" or \"false\"" }}{{ end -}}
{{- if and $s.modelEgress.enabled (empty $s.modelEgress.to) }}{{ fail "sessions-pipeline-worker: sessionAnalysis.modelEgress.to must list destinations when modelEgress.enabled=true (an empty to would allow every destination)" }}{{ end -}}
{{- end -}}
{{- end }}

{{- define "sessions-pipeline-worker.analysisServiceAccountName" -}}
{{- .Values.sessionAnalysis.serviceAccount.name | default (include "sessions-pipeline-worker.componentName" (dict "context" . "component" "session-analysis")) -}}
{{- end }}
