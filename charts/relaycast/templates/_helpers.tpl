{{- define "relaycast.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "relaycast.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "relaycast.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "relaycast.labels" -}}
helm.sh/chart: {{ include "relaycast.chart" . }}
{{ include "relaycast.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "relaycast.selectorLabels" -}}
app.kubernetes.io/name: {{ include "relaycast.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "relaycast.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "relaycast.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "relaycast.claimName" -}}
{{- default (printf "%s-data" (include "relaycast.fullname" .)) .Values.persistence.existingClaim }}
{{- end }}

{{- define "relaycast.image" -}}
{{- $image := .Values.image }}
{{- $path := "image" }}
{{- if include "relaycast.postgres.enabled" . }}
{{- $image = .Values.runtime.postgres.image }}
{{- $path = "runtime.postgres.image" }}
{{- end }}
{{- $digest := required (printf "%s.digest is required; Relaycast images must be pinned by sha256 digest" $path) $image.digest }}
{{- if not (regexMatch "^sha256:[a-f0-9]{64}$" $digest) }}
{{- fail (printf "%s.digest must be sha256:<64 lowercase hex characters>" $path) }}
{{- end }}
{{- printf "%s@%s" $image.repository $digest }}
{{- end }}

{{- /* CronJob names are limited to 52 characters; "-backup" is 7. */ -}}
{{- define "relaycast.backupName" -}}
{{- printf "%s-backup" (include "relaycast.fullname" . | trunc 45 | trimSuffix "-") }}
{{- end }}

{{- define "relaycast.backupClaimName" -}}
{{- default (include "relaycast.backupName" .) .Values.backup.existingClaim }}
{{- end }}

{{- /* Shorten before the suffix so it can never collide with the app Service. */ -}}
{{- define "relaycast.denyServiceName" -}}
{{- printf "%s-deny" (include "relaycast.fullname" . | trunc 58 | trimSuffix "-") }}
{{- end }}

{{- define "relaycast.secretMountPath" -}}
/run/secrets/relaycast
{{- end }}

{{- define "relaycast.validate" -}}
{{- if ne (int .Values.replicaCount) 1 }}
{{- fail "replicaCount must be 1: Relaycast self-host stores SQLite and uploaded files on one persistent volume, and the postgres backend keeps realtime, presence and rate limits in-process (runtime.backend=durable-actors scales runtime.durableActors.gateway.replicaCount instead)" }}
{{- end }}
{{- if not (has (toString .Values.runtime.backend) (list "sqlite" "durable-actors" "postgres")) }}
{{- fail "runtime.backend must be sqlite, durable-actors or postgres" }}
{{- end }}
{{- include "relaycast.postgres.validate" . }}
{{- include "relaycast.analytics.validate" . }}
{{- if include "relaycast.actors.enabled" . }}
{{- include "relaycast.actors.validate" . }}
{{- end }}
{{- if not .Values.baseUrl }}
{{- fail "baseUrl is required: the HTTPS origin clients use, or an http:// cluster-internal origin with allowInsecureBaseUrl=true" }}
{{- end }}
{{- if .Values.allowInsecureBaseUrl }}
{{- if not (regexMatch "^https?://[A-Za-z0-9.:\\[\\]-]+$" .Values.baseUrl) }}
{{- fail "baseUrl must be an origin (scheme://host[:port]) with no credentials, path, query, or fragment" }}
{{- end }}
{{- else }}
{{- $originPattern := "^https://([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\\.)+[A-Za-z]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(:[0-9]{1,5})?$" }}
{{- if not (regexMatch $originPattern .Values.baseUrl) }}
{{- fail "baseUrl must be an HTTPS origin with public multi-label DNS and no credentials, path, query, or fragment (set allowInsecureBaseUrl=true for a cluster-internal http origin)" }}
{{- end }}
{{- if regexMatch "(?i)\\.local(:[0-9]{1,5})?$" .Values.baseUrl }}
{{- fail "baseUrl must not use the special-use .local namespace" }}
{{- end }}
{{- if regexMatch "(?i)\\.localhost(:[0-9]{1,5})?$" .Values.baseUrl }}
{{- fail "baseUrl must not use the special-use .localhost namespace" }}
{{- end }}
{{- end }}
{{- $portToken := regexFind ":[0-9]+$" .Values.baseUrl }}
{{- if and $portToken (or (lt (int (trimPrefix ":" $portToken)) 1) (gt (int (trimPrefix ":" $portToken)) 65535)) }}
{{- fail "baseUrl port must be between 1 and 65535" }}
{{- end }}
{{- if not .Values.existingSecret }}
{{- fail "existingSecret is required: create a Secret holding the internal and workspace-bootstrap secrets (see the chart README); the chart never renders secret values" }}
{{- end }}
{{- range $name := list "internalSecret" "bootstrapSecret" }}
{{- if not (index ($.Values.secretKeys | default dict) $name) }}
{{- fail (printf "secretKeys.%s is required" $name) }}
{{- end }}
{{- end }}
{{- range $name, $key := .Values.secretKeys }}
{{- if and $key (not (regexMatch "^[-._a-zA-Z0-9]+$" (toString $key))) }}
{{- fail (printf "secretKeys.%s must be a Kubernetes Secret data key" $name) }}
{{- end }}
{{- end }}
{{- if not (kindIs "bool" .Values.publicWorkspaceCreate) }}
{{- fail "publicWorkspaceCreate must be true or false" }}
{{- end }}
{{- if ne .Values.service.type "ClusterIP" }}
{{- fail "service.type must be ClusterIP: expose Relaycast through ingress, which blocks the admin and workspace-create paths at the edge" }}
{{- end }}
{{- if not (has .Values.persistence.accessMode (list "ReadWriteOnce" "ReadWriteOncePod")) }}
{{- fail "persistence.accessMode must be ReadWriteOnce or ReadWriteOncePod for the single-writer SQLite volume" }}
{{- end }}
{{- if and (not (kindIs "invalid" .Values.retention.messageTtlDays)) (not (regexMatch "^[1-9][0-9]*$" (toString .Values.retention.messageTtlDays))) }}
{{- fail "retention.messageTtlDays must be a positive integer when set" }}
{{- end }}
{{- if and (not (kindIs "invalid" .Values.mailbox.ttlMs)) (not (regexMatch "^[1-9][0-9]*$" (toString .Values.mailbox.ttlMs))) }}
{{- fail "mailbox.ttlMs must be a positive integer when set" }}
{{- end }}
{{- if and (not (kindIs "invalid" .Values.mailbox.depthCap)) (not (regexMatch "^[1-9][0-9]*$" (toString .Values.mailbox.depthCap))) }}
{{- fail "mailbox.depthCap must be a positive integer when set" }}
{{- end }}
{{- $credentials := .Values.credentials | default dict -}}
{{- $credentialFormat := dig "format" "legacy" $credentials -}}
{{- $credentialAuthority := dig "authority" "" $credentials -}}
{{- $relayauthUrl := dig "relayauth" "url" "" $credentials -}}
{{- if not (has $credentialFormat (list "legacy" "ar")) }}
{{- fail "credentials.format must be legacy or ar" }}
{{- end }}
{{- if not (has $credentialAuthority (list "" "self" "relayauth")) }}
{{- fail "credentials.authority must be empty, self, or relayauth" }}
{{- end }}
{{- if and (eq $credentialFormat "ar") (not $credentialAuthority) }}
{{- fail "credentials.authority is required when credentials.format=ar (self or relayauth)" }}
{{- end }}
{{- if eq $credentialAuthority "relayauth" }}
{{- if not $relayauthUrl }}
{{- fail "credentials.relayauth.url is required when credentials.authority=relayauth" }}
{{- end }}
{{- if not .Values.secretKeys.relayauthToken }}
{{- fail "secretKeys.relayauthToken is required when credentials.authority=relayauth" }}
{{- end }}
{{- end }}
{{- if and (eq $credentialAuthority "self") (not .Values.secretKeys.credentialKeyring) }}
{{- fail "secretKeys.credentialKeyring is required when credentials.authority=self" }}
{{- end }}
{{- if and $relayauthUrl (not .Values.secretKeys.relayauthToken) }}
{{- fail "secretKeys.relayauthToken is required when credentials.relayauth.url is set" }}
{{- end }}
{{- if and .Values.secretKeys.relayauthToken (not $relayauthUrl) }}
{{- fail "credentials.relayauth.url is required when secretKeys.relayauthToken is set" }}
{{- end }}
{{- if .Values.ingress.enabled }}
{{- if .Values.publicWorkspaceCreate }}
{{- fail "ingress.enabled requires publicWorkspaceCreate=false: anonymous workspace creation must never be reachable from a public edge" }}
{{- end }}
{{- if .Values.allowInsecureBaseUrl }}
{{- fail "ingress.enabled requires an HTTPS public baseUrl; unset allowInsecureBaseUrl" }}
{{- end }}
{{- if not .Values.ingress.hosts }}
{{- fail "ingress.enabled=true requires at least one host" }}
{{- end }}
{{- $baseHost := regexReplaceAll "^https://([^:/]+)(:[0-9]+)?$" .Values.baseUrl "${1}" }}
{{- if not (has $baseHost .Values.ingress.hosts) }}
{{- fail "ingress.hosts must include the baseUrl host" }}
{{- end }}
{{- if and (not .Values.ingress.tls) (not .Values.ingress.externalTls) }}
{{- fail "ingress.enabled=true requires ingress.tls (or ingress.externalTls=true when a load balancer in front of the controller terminates TLS)" }}
{{- end }}
{{- if and .Values.networkPolicy.enabled (not .Values.networkPolicy.ingressFrom) }}
{{- fail "ingress with networkPolicy requires networkPolicy.ingressFrom (the ingress controller's namespace or pods)" }}
{{- end }}
{{- end }}
{{- if .Values.backup.enabled }}
{{- if ne .Values.persistence.accessMode "ReadWriteOnce" }}
{{- fail "backup.enabled requires persistence.accessMode=ReadWriteOnce: the backup pod mounts the data claim on the same node" }}
{{- end }}
{{- if not (regexMatch "^[1-9][0-9]*$" (toString .Values.backup.keep)) }}
{{- fail "backup.keep must be a positive integer" }}
{{- end }}
{{- end }}
{{- range .Values.extraEnv }}
{{- if or (has .name (list "PORT" "RELAYCAST_DB_PATH" "RELAYCAST_ENV" "RELAYCAST_MESSAGE_TTL_DAYS" "RELAYCAST_MAILBOX_TTL_MS" "RELAYCAST_MAILBOX_DEPTH_CAP" "RELAYCAST_PUBLIC_WORKSPACE_CREATE" "RELAYCAST_WORKSPACE_BOOTSTRAP_PROOF_REQUIRED" "RELAYCAST_ALLOW_INSECURE_BASE_URL" "RELAYCAST_PRIVATE_DNS_SUFFIXES" "RELAYCAST_INSECURE_BASE_URL_HOSTS")) (hasPrefix "RELAYCAST_INTERNAL_SECRET" .name) (hasPrefix "RELAYCAST_WORKSPACE_BOOTSTRAP_SECRET" .name) (hasPrefix "RELAYCAST_RELAYAUTH" .name) (hasPrefix "RELAYCAST_CREDENTIAL" .name) }}
{{- fail (printf "%s is managed by structured chart values and must not appear in extraEnv" .name) }}
{{- end }}
{{- end }}
{{- end }}

{{/*
NODE_OPTIONS for containers that start node directly (command: node), which
skips the image entrypoint's heap sizing (relaycast#668): V8's old space at 75 %
of resources.limits.memory instead of Node's default of about half. Nothing is
emitted without a parseable limit below 1 TiB, or when extraEnv sets
NODE_OPTIONS (the operator's value wins).
*/}}
{{- define "relaycast.nodeHeapEnv" -}}
{{- $mem := toString (dig "limits" "memory" "" (.Values.resources | default dict)) -}}
{{- $mib := 0 -}}
{{- if regexMatch "^[0-9]+Gi$" $mem }}{{ $mib = mul (atoi (trimSuffix "Gi" $mem)) 1024 }}
{{- else if regexMatch "^[0-9]+Mi$" $mem }}{{ $mib = atoi (trimSuffix "Mi" $mem) }}
{{- else if regexMatch "^[0-9]+G$" $mem }}{{ $mib = div (mul (atoi (trimSuffix "G" $mem)) 1000000000) 1048576 }}
{{- else if regexMatch "^[0-9]+M$" $mem }}{{ $mib = div (mul (atoi (trimSuffix "M" $mem)) 1000000) 1048576 }}
{{- else if regexMatch "^[0-9]+$" $mem }}{{ $mib = div (atoi $mem) 1048576 }}
{{- end -}}
{{- $heap := div (mul $mib 3) 4 -}}
{{- $operator := false -}}
{{- range .Values.extraEnv }}{{ if eq (toString .name) "NODE_OPTIONS" }}{{ $operator = true }}{{ end }}{{ end -}}
{{- if and (ge (int64 $heap) 64) (le (int64 $heap) 1048576) (not $operator) }}
- name: NODE_OPTIONS
  value: {{ printf "--max-old-space-size=%d" (int64 $heap) | quote }}
{{- end }}
{{- end }}

{{/*
A probe with the image's split health endpoints (relaycast#667) when
healthProbes is "split": /health/live for startup and liveness, /health/ready
for readiness. "legacy" keeps the probe exactly as configured. A probe without
httpGet is never changed.
*/}}
{{- define "relaycast.probe" -}}
{{- $p := deepCopy .probe -}}
{{- if and (eq (toString .root.Values.healthProbes) "split") (hasKey $p "httpGet") }}
{{- $get := deepCopy $p.httpGet -}}
{{- $_ := set $get "path" .path -}}
{{- $_ := set $p "httpGet" $get -}}
{{- end -}}
{{- toYaml $p -}}
{{- end }}

{{/*
Pod securityContext plus the TCP keepalive sysctls for the PostgreSQL backend,
so a half-open connection to a failed-over primary is detected in about 15 s
(relaycast docs/self-host-postgres.md). Both are namespaced safe sysctls from
Kubernetes 1.29; earlier clusters and other backends get the context as is.
Sysctls already set in podSecurityContext are kept.
*/}}
{{- define "relaycast.podSecurityContext" -}}
{{- $psc := deepCopy (.Values.podSecurityContext | default dict) -}}
{{- $ka := .Values.runtime.postgres.tcpKeepalive | default dict -}}
{{- if and (include "relaycast.postgres.enabled" .) $ka.enabled (semverCompare ">=1.29-0" .Capabilities.KubeVersion.Version) }}
{{- $have := list -}}
{{- range ($psc.sysctls | default list) }}{{ $have = append $have (toString .name) }}{{ end -}}
{{- $add := list -}}
{{- if not (has "net.ipv4.tcp_keepalive_intvl" $have) }}{{ $add = append $add (dict "name" "net.ipv4.tcp_keepalive_intvl" "value" (toString (int $ka.intervalSeconds))) }}{{ end -}}
{{- if not (has "net.ipv4.tcp_keepalive_probes" $have) }}{{ $add = append $add (dict "name" "net.ipv4.tcp_keepalive_probes" "value" (toString (int $ka.probes))) }}{{ end -}}
{{- $_ := set $psc "sysctls" (concat ($psc.sysctls | default list) $add) -}}
{{- end -}}
{{- toYaml $psc -}}
{{- end }}
