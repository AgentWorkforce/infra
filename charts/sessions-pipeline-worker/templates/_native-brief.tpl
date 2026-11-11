{{- define "sessions-pipeline-worker.validateNativeBrief" -}}
{{- $n := .Values.nativeBrief -}}
{{- $c := index .Values.components "session-brief" -}}
{{- include "sessions-pipeline-worker.validateBriefAnalytics" . -}}
{{- include "sessions-pipeline-worker.refuseUnmanagedBrief" (.Values.extraEnv | default list) -}}
{{- range $component, $settings := .Values.components -}}
{{- include "sessions-pipeline-worker.refuseUnmanagedBrief" ($settings.env | default list) -}}
{{- end -}}
{{- if not (kindIs "bool" $n.enabled) }}{{ fail "nativeBrief.enabled must be a boolean" }}{{ end -}}
{{- if and (not (kindIs "invalid" $n.readerMaxRuleset)) (not (has (toString $n.readerMaxRuleset) (list "8" "9" "10"))) }}{{ fail "nativeBrief.readerMaxRuleset must be one of 8, 9, or 10" }}{{ end -}}
{{- if not (kindIs "bool" $c.enabled) }}{{ fail "components.session-brief.enabled must be a boolean" }}{{ end -}}
{{- if and $c.enabled (not $n.enabled) }}{{ fail "components.session-brief.enabled requires nativeBrief.enabled; unmanaged native worker selection is refused" }}{{ end -}}
{{- if not (kindIs "bool" $n.openaiEgress.enabled) }}{{ fail "nativeBrief.openaiEgress.enabled must be a boolean" }}{{ end -}}
{{- if and $n.openaiEgress.enabled (not $n.enabled) }}{{ fail "nativeBrief.openaiEgress requires nativeBrief.enabled" }}{{ end -}}
{{- if and (not $n.openaiEgress.enabled) (not (empty $n.openaiEgress.to)) }}{{ fail "nativeBrief.openaiEgress.to requires enabled=true" }}{{ end -}}
{{- if not (or (kindIs "invalid" $n.baseUrl) (kindIs "string" $n.baseUrl)) }}{{ fail "nativeBrief.baseUrl must be a string" }}{{ end -}}
{{- if not (kindIs "bool" $n.allowInClusterHttp) }}{{ fail "nativeBrief.allowInClusterHttp must be a boolean" }}{{ end -}}
{{- if and $n.baseUrl (not $n.enabled) }}{{ fail "nativeBrief.baseUrl requires nativeBrief.enabled" }}{{ end -}}
{{- if and $n.allowInClusterHttp (not $n.enabled) }}{{ fail "nativeBrief.allowInClusterHttp requires nativeBrief.enabled" }}{{ end -}}
{{- if $n.baseUrl -}}
{{- /* The worker's destination rule (src/shared/destination-url.ts), checked here so a bad value fails the render and not the pod. Messages name the rule, never the value. */ -}}
{{- $port := "(:(6553[0-5]|655[0-2][0-9]|65[0-4][0-9]{2}|6[0-4][0-9]{3}|[1-5][0-9]{4}|[1-9][0-9]{0,3}))?" -}}
{{- $path := "(/[A-Za-z0-9._~%!$&'()*+,;=:@/-]*)?" -}}
{{- $publicHost := "([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*|\\[[0-9A-Fa-f:.]+\\])" -}}
{{- $label := "[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?" -}}
{{- $serviceHost := printf "%s\\.%s\\.svc(\\.cluster\\.local)?" $label $label -}}
{{- $inClusterHttp := or (eq (toString .Values.allowInClusterHttp) "true") $n.allowInClusterHttp -}}
{{- if not (regexMatch "^https?://" $n.baseUrl) }}{{ fail "nativeBrief.baseUrl must be an absolute https URL, or http to a Kubernetes Service name" }}{{ end -}}
{{- if hasPrefix "https://" $n.baseUrl -}}
{{- if not (regexMatch (printf "^https://%s%s%s$" $publicHost $port $path) $n.baseUrl) }}{{ fail "nativeBrief.baseUrl must be a valid URL without credentials, query or fragment" }}{{ end -}}
{{- else -}}
{{- if not $inClusterHttp }}{{ fail "nativeBrief.baseUrl must use https; http needs nativeBrief.allowInClusterHttp=true and a <svc>.<ns>.svc[.cluster.local] host" }}{{ end -}}
{{- if not (regexMatch (printf "^http://%s%s%s$" $serviceHost $port $path) $n.baseUrl) }}{{ fail "nativeBrief.baseUrl http is limited to a <svc>.<ns>.svc[.cluster.local] host without credentials, query or fragment" }}{{ end -}}
{{- end -}}
{{- end -}}
{{- if $n.enabled -}}
{{- range $label := list "app.kubernetes.io/name" "app.kubernetes.io/instance" "app.kubernetes.io/component" -}}
{{- if hasKey $.Values.podLabels $label }}{{ fail "nativeBrief podLabels must not override managed NetworkPolicy selector labels" }}{{ end -}}
{{- end -}}
{{- if or (not (kindIs "bool" $c.enabled)) (not $c.enabled) }}{{ fail "nativeBrief requires components.session-brief.enabled=true" }}{{ end -}}
{{- if ne (toString $c.replicas) "1" }}{{ fail "nativeBrief requires components.session-brief.replicas=1" }}{{ end -}}
{{- if not (regexMatch "^sha256:[a-f0-9]{64}$" ($n.image.digest | default "")) }}{{ fail "nativeBrief requires an explicit immutable nativeBrief.image.digest" }}{{ end -}}
{{- if or (not (kindIs "string" $n.image.repository)) (not $n.image.repository) (contains "@" $n.image.repository) (contains ":" (last (splitList "/" $n.image.repository))) }}{{ fail "nativeBrief.image.repository must name an explicit untagged repository" }}{{ end -}}
{{- if and .Values.migrations.enabled (or (ne .Values.image.repository $n.image.repository) (ne .Values.image.digest $n.image.digest)) }}{{ fail "nativeBrief requires the migration Job image to match nativeBrief.image, or migrations.enabled=false" }}{{ end -}}
{{- range $name, $sibling := .Values.components -}}
{{- if and (ne $name "session-brief") $sibling.enabled (gt (int $sibling.replicas) 0) -}}
{{- if or (ne $.Values.image.repository $n.image.repository) (ne $.Values.image.digest $n.image.digest) }}{{ fail "nativeBrief requires active sibling workers to use the same qualified image/generation, or be disabled" }}{{ end -}}
{{- end -}}
{{- end -}}
{{- if not (and (kindIs "slice" $n.workspaceIds) (gt (len $n.workspaceIds) 0) (le (len $n.workspaceIds) 100)) }}{{ fail "nativeBrief.workspaceIds must be a bounded explicit nonempty list" }}{{ end -}}
{{- $seen := dict -}}
{{- range $id := $n.workspaceIds -}}
{{- if or (not (kindIs "string" $id)) (not (regexMatch "^[A-Za-z0-9][A-Za-z0-9._:-]{0,254}$" (toString $id))) (hasKey $seen (toString $id)) }}{{ fail "nativeBrief.workspaceIds must contain distinct explicit workspace IDs (no wildcard)" }}{{ end -}}
{{- $_ := set $seen (toString $id) true -}}
{{- end -}}
{{- if not (regexMatch "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$" ($n.keyPrefix | default "")) }}{{ fail "nativeBrief.keyPrefix must be a bare writer root, not an org-suffixed path" }}{{ end -}}
{{- if not (regexMatch "^[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}$" ($n.model | default "")) }}{{ fail "nativeBrief.model is invalid" }}{{ end -}}
{{- if or (not (regexMatch "^[0-9]+$" (toString $n.sweepSeconds))) (lt (int $n.sweepSeconds) 1) (gt (int $n.sweepSeconds) 86400) }}{{ fail "nativeBrief.sweepSeconds must be an integer 1..86400" }}{{ end -}}
{{- range $field, $max := dict "batch" 100 "globalDailyCap" 10000000 "sessionDailyCap" 10000 -}}
{{- $value := index $n $field -}}
{{- if or (not (regexMatch "^[0-9]+$" (toString $value))) (lt (int $value) 1) (gt (int $value) (int $max)) }}{{ fail (printf "nativeBrief.%s must be an integer 1..%d" $field (int $max)) }}{{ end -}}
{{- end -}}
{{- range $field := list "name" "key" -}}
{{- $value := index $n.openaiSecret $field | default "" -}}
{{- if or (not (kindIs "string" $value)) (not (regexMatch "^[A-Za-z0-9][A-Za-z0-9._-]{0,252}$" (toString $value))) }}{{ fail "nativeBrief.openaiSecret must name an existing Secret and key" }}{{ end -}}
{{- end -}}
{{- if or (gt (len $n.openaiSecret.name) 253) (not (regexMatch "^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?(\\.[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?)*$" $n.openaiSecret.name)) }}{{ fail "nativeBrief.openaiSecret.name must be a Kubernetes Secret name" }}{{ end -}}
{{- $ca := .Values.postgresCa -}}
{{- if or (not $ca.enabled) (not $ca.configMap) $ca.secret }}{{ fail "nativeBrief requires postgresCa.enabled and an existing public CA ConfigMap (not a Secret)" }}{{ end -}}
{{- if not (regexMatch "^[a-f0-9]{64}$" ($ca.sha256 | default "")) }}{{ fail "nativeBrief requires postgresCa.sha256 (64 lowercase hex)" }}{{ end -}}
{{- if not .Values.workerHealth.enabled }}{{ fail "nativeBrief requires workerHealth.enabled" }}{{ end -}}
{{- $reserved := list "SERVICE" "READER_MAX_RULESET" "OTEL_SERVICE_NAME" "HOOPDB_URL" "LOCKER_ENDPOINT" "LOCKER_BUCKET" "LOCKER_REGION" "LOCKER_ACCESS_KEY_ID" "LOCKER_SECRET_ACCESS_KEY" "NODE_EXTRA_CA_CERTS" "SSL_CERT_FILE" "SSL_CERT_DIR" "NODE_OPTIONS" "PGOPTIONS" "PGSSLCERT" "PGSSLKEY" "WORKER_HEALTH_PORT" "WORKER_UNHEALTHY_AFTER_FAILURES" "WORKER_MAX_TICK_AGE_MS" "SESSION_BRIEF_ENABLED" "SESSION_BRIEF_CANONICAL_INPUT" "SESSION_BRIEF_WORKSPACE_IDS" "SESSION_BRIEF_MODEL" "SESSION_BRIEF_SWEEP_SECONDS" "SESSION_BRIEF_BATCH" "SESSION_BRIEF_GLOBAL_DAILY_CAP" "SESSION_BRIEF_SESSION_DAILY_CAP" "PIPELINE_ORG_FROM_PREFIX" "PIPELINE_KEY_PREFIX" "OPENAI_API_KEY" "OPENAI_BASE_URL" "NATIVE_BRIEF_CA_FILE" "NATIVE_BRIEF_CA_SOURCE" "NATIVE_BRIEF_CA_SHA256" "PGSSLMODE" "PGSSLROOTCERT" "NODE_TLS_REJECT_UNAUTHORIZED" -}}
{{- range $entry := concat (.Values.extraEnv | default list) ($c.env | default list) -}}
{{- if has ($entry.name | default "") $reserved }}{{ fail (printf "nativeBrief manages %s; remove it from extraEnv/components.session-brief.env" $entry.name) }}{{ end -}}
{{- end -}}
{{- if and .Values.networkPolicy.enabled (not $n.openaiEgress.enabled) }}{{ fail "nativeBrief requires explicit openaiEgress when networkPolicy.enabled=true" }}{{ end -}}
{{- end -}}
{{- if $n.openaiEgress.enabled -}}
{{- if not .Values.networkPolicy.enabled }}{{ fail "nativeBrief.openaiEgress requires networkPolicy.enabled for DNS/database/Locker rules" }}{{ end -}}
{{- if not (and (kindIs "slice" $n.openaiEgress.to) (gt (len $n.openaiEgress.to) 0) (le (len $n.openaiEgress.to) 32)) }}{{ fail "nativeBrief.openaiEgress.to must list 1..32 explicit destinations" }}{{ end -}}
{{- range $peer := $n.openaiEgress.to -}}
{{- if not (kindIs "map" $peer) }}{{ fail "nativeBrief.openaiEgress peers must be NetworkPolicyPeer objects" }}{{ end -}}
{{- if not (or (not (empty (get $peer "ipBlock"))) (not (empty (get $peer "podSelector"))) (not (empty (get $peer "namespaceSelector")))) }}{{ fail "nativeBrief.openaiEgress refuses empty unrestricted peers" }}{{ end -}}
{{- range $key, $value := $peer }}{{ if not (has $key (list "ipBlock" "podSelector" "namespaceSelector")) }}{{ fail "nativeBrief.openaiEgress supports only NetworkPolicyPeer destination fields" }}{{ end }}{{ end -}}
{{- range $kind := list "podSelector" "namespaceSelector" -}}
{{- if hasKey $peer $kind -}}
{{- $selector := get $peer $kind -}}
{{- if not (kindIs "map" $selector) }}{{ fail "nativeBrief.openaiEgress selectors must be explicit label selectors" }}{{ end -}}
{{- if not (or (not (empty (get $selector "matchLabels"))) (not (empty (get $selector "matchExpressions")))) }}{{ fail "nativeBrief.openaiEgress refuses effectively empty wildcard selectors" }}{{ end -}}
{{- end -}}
{{- end -}}
{{- if and (hasKey $peer "ipBlock") (ne (len $peer) 1) }}{{ fail "nativeBrief.openaiEgress cannot mix ipBlock and selectors" }}{{ end -}}
{{- if hasKey $peer "ipBlock" }}{{ if not ((get $peer "ipBlock").cidr | default "") }}{{ fail "nativeBrief.openaiEgress ipBlock requires cidr" }}{{ end }}{{ end -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "sessions-pipeline-worker.refuseUnmanagedBrief" -}}
{{- range $entry := . -}}
{{- if eq ($entry.name | default "") "SESSION_BRIEF_CANONICAL_INPUT" }}{{ fail "use nativeBrief.enabled instead of unmanaged SESSION_BRIEF_CANONICAL_INPUT" }}{{ end -}}
{{- if and (eq ($entry.name | default "") "SERVICE") (or (hasKey $entry "valueFrom") (eq (trim (toString ($entry.value | default ""))) "session-brief")) }}{{ fail "SERVICE must not select session-brief or a dynamic service outside managed nativeBrief admission" }}{{ end -}}
{{- end -}}
{{- end -}}

{{- define "sessions-pipeline-worker.nativeBriefEnv" -}}
- { name: SESSION_BRIEF_ENABLED, value: "true" }
- { name: SESSION_BRIEF_CANONICAL_INPUT, value: "true" }
- { name: SESSION_BRIEF_WORKSPACE_IDS, value: {{ join "," .Values.nativeBrief.workspaceIds | quote }} }
- { name: SESSION_BRIEF_MODEL, value: {{ .Values.nativeBrief.model | quote }} }
- { name: SESSION_BRIEF_SWEEP_SECONDS, value: {{ .Values.nativeBrief.sweepSeconds | quote }} }
- { name: SESSION_BRIEF_BATCH, value: {{ .Values.nativeBrief.batch | quote }} }
- { name: SESSION_BRIEF_GLOBAL_DAILY_CAP, value: {{ .Values.nativeBrief.globalDailyCap | quote }} }
- { name: SESSION_BRIEF_SESSION_DAILY_CAP, value: {{ .Values.nativeBrief.sessionDailyCap | quote }} }
- { name: PIPELINE_ORG_FROM_PREFIX, value: "true" }
- { name: PIPELINE_KEY_PREFIX, value: {{ .Values.nativeBrief.keyPrefix | quote }} }
- { name: NATIVE_BRIEF_CA_FILE, value: /etc/postgres-ca/ca.crt }
- { name: NATIVE_BRIEF_CA_SOURCE, value: /etc/postgres-ca/ca.crt }
- { name: NATIVE_BRIEF_CA_SHA256, value: {{ .Values.postgresCa.sha256 | quote }} }
{{- with .Values.nativeBrief.baseUrl }}
- { name: OPENAI_BASE_URL, value: {{ . | quote }} }
{{- end }}
- name: OPENAI_API_KEY
  valueFrom:
    secretKeyRef:
      name: {{ .Values.nativeBrief.openaiSecret.name | quote }}
      key: {{ .Values.nativeBrief.openaiSecret.key | quote }}
{{- include "sessions-pipeline-worker.briefAnalyticsEnv" . }}
{{- end -}}

{{- define "sessions-pipeline-worker.nativeBriefPreflight" -}}
try {
 const fs=require('node:fs'),crypto=require('node:crypto');
 const file=process.env.NATIVE_BRIEF_CA_FILE,bytes=fs.readFileSync(process.env.NATIVE_BRIEF_CA_SOURCE),pem=bytes.toString('ascii');
 if(!Buffer.from(pem,'ascii').equals(bytes))throw Error();
 if(crypto.createHash('sha256').update(bytes).digest('hex')!==process.env.NATIVE_BRIEF_CA_SHA256)throw Error();
 if(!/^(?:\s*-----BEGIN CERTIFICATE-----[A-Za-z0-9+/=\r\n]+-----END CERTIFICATE-----\s*)+$/.test(pem))throw Error();
 for(const block of pem.matchAll(/-----BEGIN CERTIFICATE-----([A-Za-z0-9+/=\r\n]+)-----END CERTIFICATE-----/g)) {
  const body=block[1].replace(/\s/g,''),der=Buffer.from(body,'base64'),cert=new crypto.X509Certificate(der);
  if(der.toString('base64')!==body||!cert.raw.equals(der)||!cert.ca||Date.now()<Date.parse(cert.validFrom)||Date.now()>Date.parse(cert.validTo))throw Error();
 }
 const u=new URL(process.env.HOOPDB_URL);
 if(!['postgres:','postgresql:'].includes(u.protocol)||!u.hostname)throw Error();
 const q=u.searchParams;
 if(q.getAll('sslmode').length!==1||q.get('sslmode')!=='verify-full'||q.getAll('sslrootcert').length!==1||q.get('sslrootcert')!==file)throw Error();
 for(const name of ['ssl','uselibpqcompat','sslcert','sslkey'])if(q.has(name))throw Error();
 let fd;
 try {
  fd=fs.openSync(file,fs.constants.O_RDONLY|fs.constants.O_NOFOLLOW);
  if(!fs.fstatSync(fd).isFile()||!fs.readFileSync(fd).equals(bytes))throw Error();
 }catch(error){
  if(error?.code!=='ENOENT')throw error;
  fs.writeFileSync(file,bytes,{mode:0o440,flag:'wx'});
 }finally{if(fd!==undefined)fs.closeSync(fd);}
 console.log('native brief PostgreSQL CA and URL contract verified');
}catch{console.error('native brief PostgreSQL CA or URL contract refused');process.exit(1);}
{{- end -}}

{{- define "sessions-pipeline-worker.nativeBriefStart" -}}
bun -e '{{ include "sessions-pipeline-worker.nativeBriefPreflight" . | replace "'" "'\"'\"'" }}'
exec "$@"
{{- end -}}

{{- define "sessions-pipeline-worker.nativeBriefImage" -}}
{{- include "sessions-pipeline-worker.image" (dict "Values" (dict "global" .Values.global "image" .Values.nativeBrief.image) "Chart" .Chart) -}}
{{- end -}}
