{{- define "session-read-api.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- /* The default keeps the Service name the sessions-pipeline readApi block used. */ -}}
{{- define "session-read-api.fullname" -}}
{{- $name := default (printf "%s-read-api" .Release.Name) .Values.fullnameOverride -}}
{{- if or (gt (len $name) 63) (not (regexMatch "^[a-z]([-a-z0-9]*[a-z0-9])?$" $name)) }}{{ fail "session-read-api: fullnameOverride must be a DNS-1035 label of at most 63 characters" }}{{ end -}}
{{- $name -}}
{{- end }}

{{- define "session-read-api.selectorLabels" -}}
app.kubernetes.io/name: session-read-api
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: read-api
{{- end }}

{{- define "session-read-api.labels" -}}
{{ include "session-read-api.selectorLabels" . }}
helm.sh/chart: {{ include "session-read-api.chart" . | quote }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: sessions-pipeline
{{- end }}

{{- /* Everything that must refuse to render, in one place. Emits nothing. */ -}}
{{- define "session-read-api.validate" -}}
{{- include "session-read-api.analytics.validate" .Values.analytics -}}
{{- $c := .Values -}}
{{- $repository := required "session-read-api: image.repository is required" $c.image.repository -}}
{{- $repositoryPattern := "^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(:[0-9]{1,5})?/[a-z0-9]+(([._]|__|-+)[a-z0-9]+)*(/[a-z0-9]+(([._]|__|-+)[a-z0-9]+)*)*$" -}}
{{- $registryHost := regexReplaceAll ":[0-9]+$" (first (splitList "/" $repository)) "" -}}
{{- if or (gt (len $registryHost) 253) (not (regexMatch $repositoryPattern $repository)) }}{{ fail "session-read-api: image.repository must include an explicit registry DNS host and image path, without a scheme, tag or digest" }}{{ end -}}
{{- $registryPort := regexFind ":[0-9]+$" (first (splitList "/" $repository)) -}}
{{- if and $registryPort (or (lt (int (trimPrefix ":" $registryPort)) 1) (gt (int (trimPrefix ":" $registryPort)) 65535)) }}{{ fail "session-read-api: image.repository has an invalid registry port" }}{{ end -}}
{{- $digest := required "session-read-api: image.digest requires an owner-approved compatible image" $c.image.digest -}}
{{- if not (regexMatch "^sha256:[a-f0-9]{64}$" $digest) }}{{ fail "session-read-api: image.digest must be sha256:<64 lowercase hex characters>" }}{{ end -}}
{{- $origin := required "session-read-api: origin is required" $c.origin -}}
{{- if and (not (kindIs "invalid" $c.readerMaxRuleset)) (not (has (toString $c.readerMaxRuleset) (list "8" "9" "10"))) }}{{ fail "session-read-api: readerMaxRuleset must be one of 8, 9, or 10" }}{{ end -}}
{{- $publicOriginPattern := "^https://([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\\.)+[A-Za-z]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(:[0-9]{1,5})?$" -}}
{{- if or (not (regexMatch $publicOriginPattern $origin)) (regexMatch "(?i)\\.(localhost|local|internal|lan|invalid|test|example|home\\.arpa|onion)(:[0-9]{1,5})?$" $origin) (regexMatch "(?i)\\.example\\.(com|net|org)(:[0-9]{1,5})?$" $origin) }}{{ fail "session-read-api: origin must be a public HTTPS origin with multi-label DNS and no credentials, path, query, or fragment" }}{{ end -}}
{{- $portToken := regexFind ":[0-9]+$" $origin -}}
{{- if and $portToken (or (lt (int (trimPrefix ":" $portToken)) 1) (gt (int (trimPrefix ":" $portToken)) 65535)) }}{{ fail "session-read-api: origin port must be between 1 and 65535" }}{{ end -}}
{{- $_ := required "session-read-api: completeSince requires an explicit coverage floor" $c.completeSince -}}
{{- if not (kindIs "string" $c.directoryWorkspaces) }}{{ fail "session-read-api: directoryWorkspaces must be a string" }}{{ end -}}
{{- $workspaces := required "session-read-api: directoryWorkspaces requires an explicit workspace allowlist" (trim $c.directoryWorkspaces) -}}
{{- /* Exactly "*" is the single-tenant self-host value (every workspace; the
token still binds each read to one workspace), only in self_issued mode: a new
workspace is not on a static list, and its reads would answer 501. */ -}}
{{- if and (contains "*" $workspaces) (not (and (eq $workspaces "*") (eq (toString $c.auth.mode) "self_issued"))) }}{{ fail "session-read-api: directoryWorkspaces must be an explicit allowlist string without '*' (exactly '*' is allowed only with auth.mode=self_issued)" }}{{ end -}}
{{- if or (not (regexMatch "^[0-9]+$" (toString $c.port))) (lt (int $c.port) 1024) (gt (int $c.port) 65535) }}{{ fail "session-read-api: port must be an integer from 1024 to 65535" }}{{ end -}}
{{- if not (has $c.probeRuntime (list "bun" "node")) }}{{ fail "session-read-api: probeRuntime must be bun or node" }}{{ end -}}
{{- if not (kindIs "bool" $c.allowInClusterHttp) }}{{ fail "session-read-api: allowInClusterHttp must be a boolean" }}{{ end -}}
{{- if not (kindIs "bool" $c.login.advertisesSync) }}{{ fail "session-read-api: login.advertisesSync must be a boolean" }}{{ end -}}
{{- /* Search and its Secret. */ -}}
{{- $backend := required "session-read-api: search.backend requires an explicit registered adapter" (trim $c.search.backend) -}}
{{- $clickhouse := $c.search.clickhouse -}}
{{- if not (kindIs "bool" $clickhouse.enabled) }}{{ fail "session-read-api: search.clickhouse.enabled must be a boolean" }}{{ end -}}
{{- if $clickhouse.enabled -}}
{{- $_ := required "session-read-api: search.clickhouse.existingSecret is required when ClickHouse search is enabled" $clickhouse.existingSecret -}}
{{- $_ := required "session-read-api: search.clickhouse.key is required when ClickHouse search is enabled" $clickhouse.key -}}
{{- if not (has $backend (list "postgres" "clickhouse")) }}{{ fail "session-read-api: search.clickhouse.enabled selects clickhouse and conflicts with search.backend" }}{{ end -}}
{{- else -}}
{{- $_ := required "session-read-api: config.existingSecret is required" $c.config.existingSecret -}}
{{- $_ := required "session-read-api: config.key is required" $c.config.key -}}
{{- end -}}
{{- $effective := ternary "clickhouse" $backend $clickhouse.enabled -}}
{{- if not (has $effective (list "postgres" "clickhouse" "opensearch")) }}{{ fail "session-read-api: search.backend must be postgres, clickhouse or opensearch" }}{{ end -}}
{{- if has $effective (list "postgres" "opensearch") -}}
{{- if not (regexMatch "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$" (toString $c.search.backendId)) }}{{ fail "session-read-api: search.backendId is required for postgres and opensearch and must match the indexer" }}{{ end -}}
{{- end -}}
{{- if eq $effective "opensearch" -}}
{{- if not (regexMatch "^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?$" (toString $c.search.opensearch.url)) }}{{ fail "session-read-api: search.opensearch.url must be a base https origin" }}{{ end -}}
{{- if not (regexMatch "^[a-z]{2}(-[a-z]+)+-[0-9]+$" (toString $c.search.opensearch.region)) }}{{ fail "session-read-api: search.opensearch.region must be an AWS region" }}{{ end -}}
{{- if and $c.search.opensearch.indexPrefix (not (regexMatch "^[a-z0-9][a-z0-9_-]{0,63}$" (toString $c.search.opensearch.indexPrefix))) }}{{ fail "session-read-api: search.opensearch.indexPrefix must be lowercase letters, digits, _ or -" }}{{ end -}}
{{- end -}}
{{- if not (kindIs "bool" $c.turns.assumeNoLegacy) }}{{ fail "session-read-api: turns.assumeNoLegacy must be a boolean" }}{{ end -}}
{{- if not (kindIs "bool" $c.serviceAccountCreate) }}{{ fail "session-read-api: serviceAccountCreate must be a boolean" }}{{ end -}}
{{- if and $c.serviceAccountCreate (not $c.serviceAccountName) }}{{ fail "session-read-api: serviceAccountCreate requires serviceAccountName" }}{{ end -}}
{{- /* Postgres TLS: always verified, against the image's pin or a mounted CA. */ -}}
{{- $profile := required "session-read-api: postgres.tlsProfile is required (supabase or custom-ca); the service refuses to start without it" $c.postgres.tlsProfile -}}
{{- if not (has $profile (list "supabase" "custom-ca")) }}{{ fail "session-read-api: postgres.tlsProfile must be supabase or custom-ca" }}{{ end -}}
{{- $ca := $c.postgresCa -}}
{{- if not (kindIs "bool" $ca.enabled) }}{{ fail "session-read-api: postgresCa.enabled must be a boolean" }}{{ end -}}
{{- if eq $profile "custom-ca" -}}
{{- if not $ca.enabled }}{{ fail "session-read-api: postgres.tlsProfile=custom-ca requires postgresCa.enabled=true" }}{{ end -}}
{{- else if $ca.enabled -}}
{{- fail "session-read-api: postgresCa.enabled=true requires postgres.tlsProfile=custom-ca; a CA with another profile would be ignored" -}}
{{- end -}}
{{- if $ca.enabled -}}
{{- if eq (empty $ca.configMap) (empty $ca.secret) }}{{ fail "session-read-api: postgresCa.enabled=true requires exactly one of postgresCa.configMap or postgresCa.secret" }}{{ end -}}
{{- $ref := default $ca.secret $ca.configMap -}}
{{- if or (gt (len $ref) 253) (not (regexMatch "^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?(\\.[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?)*$" $ref)) }}{{ fail "session-read-api: postgresCa.configMap and postgresCa.secret must be a Kubernetes object name" }}{{ end -}}
{{- if not (regexMatch "^[A-Za-z0-9._-]+$" (toString $ca.key)) }}{{ fail "session-read-api: postgresCa.key must be a Kubernetes data key" }}{{ end -}}
{{- if not (regexMatch "^[a-f0-9]{64}$" (toString $ca.sha256)) }}{{ fail "session-read-api: postgresCa.sha256 must be 64 lowercase hex characters" }}{{ end -}}
{{- else if or $ca.configMap $ca.secret -}}
{{- fail "session-read-api: postgresCa.configMap and postgresCa.secret require postgresCa.enabled=true; a CA name while disabled would leave the certificate unverified" -}}
{{- end -}}
{{- /* Auth. One token family per mode; a half-configured mode refuses to render. */ -}}
{{- if not (kindIs "bool" $c.auth.relaycontrol.enabled) }}{{ fail "session-read-api: auth.relaycontrol.enabled must be a boolean" }}{{ end -}}
{{- if not (kindIs "string" $c.auth.mode) }}{{ fail "session-read-api: auth.mode must be legacy, relaycontrol_only or self_issued" }}{{ end -}}
{{- if not (has $c.auth.mode (list "legacy" "relaycontrol_only" "self_issued")) }}{{ fail "session-read-api: auth.mode must be legacy, relaycontrol_only or self_issued" }}{{ end -}}
{{- $jwks := trim $c.auth.relayauth.jwksUrl -}}
{{- $issuer := trim $c.auth.relayauth.issuer -}}
{{- $selfIssued := $c.auth.selfIssued -}}
{{- $internal := $selfIssued.internalSecret -}}
{{- $previous := $selfIssued.previousInternalSecret -}}
{{- $objectName := "^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?(\\.[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?)*$" -}}
{{- if eq $c.auth.mode "self_issued" -}}
{{- if or $jwks $issuer }}{{ fail "session-read-api: auth.mode=self_issued requires empty relayauth.jwksUrl and relayauth.issuer" }}{{ end -}}
{{- if $c.auth.relaycontrol.enabled }}{{ fail "session-read-api: auth.mode=self_issued requires auth.relaycontrol.enabled=false; the service refuses Control introspection in this mode" }}{{ end -}}
{{- if or $c.auth.relaycontrol.url $c.auth.relaycontrol.existingSecret }}{{ fail "session-read-api: auth.mode=self_issued requires empty auth.relaycontrol.url and existingSecret" }}{{ end -}}
{{- if $c.login.advertisesSync }}{{ fail "session-read-api: auth.mode=self_issued requires login.advertisesSync=false; POST /v1/cli/login does not exist in this mode" }}{{ end -}}
{{- if or (gt (len (toString $internal.existingSecret)) 253) (not (regexMatch $objectName (toString $internal.existingSecret))) }}{{ fail "session-read-api: auth.mode=self_issued requires auth.selfIssued.internalSecret.existingSecret, a Secret holding at least 32 characters" }}{{ end -}}
{{- if not (regexMatch "^[A-Za-z0-9._-]+$" (toString $internal.key)) }}{{ fail "session-read-api: auth.selfIssued.internalSecret.key must be a Kubernetes data key" }}{{ end -}}
{{- if $previous.existingSecret -}}
{{- if or (gt (len (toString $previous.existingSecret)) 253) (not (regexMatch $objectName (toString $previous.existingSecret))) }}{{ fail "session-read-api: auth.selfIssued.previousInternalSecret.existingSecret must be a Kubernetes object name" }}{{ end -}}
{{- if not (regexMatch "^[A-Za-z0-9._-]+$" (toString $previous.key)) }}{{ fail "session-read-api: auth.selfIssued.previousInternalSecret.key must be a Kubernetes data key" }}{{ end -}}
{{- if and (eq $previous.existingSecret $internal.existingSecret) (eq $previous.key $internal.key) }}{{ fail "session-read-api: auth.selfIssued.previousInternalSecret must name a different Secret key from internalSecret" }}{{ end -}}
{{- end -}}
{{- $ttl := toString $selfIssued.accessTokenTtlSeconds -}}
{{- if or (not (regexMatch "^[1-9][0-9]{0,4}$" $ttl)) (lt (int $ttl) 60) (gt (int $ttl) 300) }}{{ fail "session-read-api: auth.selfIssued.accessTokenTtlSeconds must be an integer from 60 to 300" }}{{ end -}}
{{- if not $c.networkPolicy.enabled }}{{ fail "session-read-api: auth.mode=self_issued requires networkPolicy.enabled=true with networkPolicy.controlFrom, so only Control is admitted for /internal" }}{{ end -}}
{{- else -}}
{{- if or $internal.existingSecret $previous.existingSecret }}{{ fail "session-read-api: auth.selfIssued secrets require auth.mode=self_issued" }}{{ end -}}
{{- if ne (toString $selfIssued.accessTokenTtlSeconds) "300" }}{{ fail "session-read-api: auth.selfIssued.accessTokenTtlSeconds requires auth.mode=self_issued" }}{{ end -}}
{{- if eq $c.auth.mode "relaycontrol_only" -}}
{{- if or $jwks $issuer }}{{ fail "session-read-api: auth.mode=relaycontrol_only requires empty relayauth.jwksUrl and relayauth.issuer" }}{{ end -}}
{{- if not $c.auth.relaycontrol.enabled }}{{ fail "session-read-api: auth.mode=relaycontrol_only requires auth.relaycontrol.enabled=true" }}{{ end -}}
{{- else -}}
{{- $_ := required "session-read-api: auth.relayauth.jwksUrl must explicitly configure the temporary issuer" $jwks -}}
{{- $_ := required "session-read-api: auth.relayauth.issuer must explicitly configure the temporary issuer" $issuer -}}
{{- end -}}
{{- end -}}
{{- if $c.auth.relaycontrol.enabled -}}
{{- $url := required "session-read-api: auth.relaycontrol.url is required" $c.auth.relaycontrol.url -}}
{{- $inCluster := regexMatch "^http://[a-z0-9]([-a-z0-9.]*[a-z0-9])?\\.svc(\\.cluster\\.local)?(:[0-9]{1,5})?$" $url -}}
{{- if not (or (regexMatch "^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?$" $url) (and $c.allowInClusterHttp $inCluster)) }}{{ fail "session-read-api: auth.relaycontrol.url must be a base https origin, or http to an in-cluster Service with allowInClusterHttp=true" }}{{ end -}}
{{- $_ := required "session-read-api: auth.relaycontrol.existingSecret is required" $c.auth.relaycontrol.existingSecret -}}
{{- $_ := required "session-read-api: auth.relaycontrol.key is required" $c.auth.relaycontrol.key -}}
{{- end -}}
{{- /* NetworkPolicy peers: no catch-all can stand in for a named caller. */ -}}
{{- $np := $c.networkPolicy -}}
{{- if not (kindIs "bool" $np.enabled) }}{{ fail "session-read-api: networkPolicy.enabled must be a boolean" }}{{ end -}}
{{- if not (kindIs "bool" $c.ingress.enabled) }}{{ fail "session-read-api: ingress.enabled must be a boolean" }}{{ end -}}
{{- range $field := list "controlFrom" "publicFrom" -}}
{{- $peers := index $np $field -}}
{{- if not (kindIs "slice" $peers) }}{{ fail (printf "session-read-api: networkPolicy.%s must be a list" $field) }}{{ end -}}
{{- range $peer := $peers -}}
{{- if not (kindIs "map" $peer) }}{{ fail (printf "session-read-api: networkPolicy.%s entries must be NetworkPolicy peers" $field) }}{{ end -}}
{{- $pods := index $peer "podSelector" | default dict -}}
{{- $namespaces := index $peer "namespaceSelector" | default dict -}}
{{- $block := index $peer "ipBlock" | default dict -}}
{{- $namesPods := or $pods.matchLabels $pods.matchExpressions -}}
{{- $namesNamespaces := or $namespaces.matchLabels $namespaces.matchExpressions -}}
{{- if eq $field "controlFrom" -}}
{{- if or (not $namesPods) $block }}{{ fail "session-read-api: networkPolicy.controlFrom entries must select Control with podSelector labels (optionally a namespaceSelector), never an ipBlock or a whole namespace" }}{{ end -}}
{{- else if $block -}}
{{- if or $pods $namespaces }}{{ fail "session-read-api: networkPolicy.publicFrom ipBlock entries cannot also set selectors" }}{{ end -}}
{{- if or (not $block.cidr) (has (toString $block.cidr) (list "0.0.0.0/0" "::/0")) }}{{ fail "session-read-api: networkPolicy.publicFrom ipBlock needs a specific cidr, not 0.0.0.0/0 or ::/0" }}{{ end -}}
{{- else if not (or $namesPods $namesNamespaces) -}}
{{- fail "session-read-api: networkPolicy.publicFrom entries need selector labels or an ipBlock; an empty peer admits everyone" -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- if $np.enabled -}}
{{- if not $np.controlFrom }}{{ fail "session-read-api: networkPolicy.enabled=true requires networkPolicy.controlFrom naming the Control pods" }}{{ end -}}
{{- if and $c.ingress.enabled (not $np.publicFrom) }}{{ fail "session-read-api: ingress.enabled with networkPolicy.enabled requires networkPolicy.publicFrom, or the policy would block the ingress" }}{{ end -}}
{{- end -}}
{{- if not (kindIs "bool" $c.events.messageIds) }}{{ fail "session-read-api: events.messageIds must be a boolean" }}{{ end -}}
{{- if not (kindIs "bool" $c.coordinationOverlaps.enabled) }}{{ fail "session-read-api: coordinationOverlaps.enabled must be a boolean" }}{{ end -}}
{{- /* CORS: exact origins only, matching what the service itself accepts. */ -}}
{{- if not (kindIs "slice" $c.cors.allowedOrigins) }}{{ fail "session-read-api: cors.allowedOrigins must be a list" }}{{ end -}}
{{- range $o := $c.cors.allowedOrigins -}}
{{- if not (kindIs "string" $o) }}{{ fail "session-read-api: cors.allowedOrigins entries must be strings" }}{{ end -}}
{{- if not (or (regexMatch "^https://[a-z0-9]([-a-z0-9.]*[a-z0-9])?(:[0-9]{1,5})?$" $o) (regexMatch "^http://(localhost|127\\.0\\.0\\.1)(:[0-9]{1,5})?$" $o)) }}{{ fail "session-read-api: cors.allowedOrigins must be exact lowercase https origins (http only on loopback), with no wildcard, path or trailing slash" }}{{ end -}}
{{- end -}}
{{- if $c.analytics.enabled -}}
{{- range $v := $c.extraVolumes -}}
{{- if eq $v.name "analytics-ca" }}{{ fail "analytics-ca is a managed volume name" }}{{ end -}}
{{- end -}}
{{- range $m := $c.extraVolumeMounts -}}
{{- if or (eq $m.name "analytics-ca") (hasPrefix "/etc/analytics-ca" $m.mountPath) }}{{ fail "analytics-ca is a managed mount" }}{{ end -}}
{{- end -}}
{{- end -}}
{{- /* extraEnv: nothing managed above can be overridden or hidden here. */ -}}
{{- $reserved := list "SERVICE" "READER_MAX_RULESET" "RELAYHISTORY_SELFHOST_READ_API" "RELAYHISTORY_READ_API_PORT" "RELAYHISTORY_READ_API_SECRET" "READ_API_ORIGIN" "READ_API_AUTH_MODE" "READ_API_COMPLETE_SINCE" "READ_API_DIRECTORY_WORKSPACES" "READ_API_CORS_ALLOWED_ORIGINS" "RELAYHISTORY_SELFHOST_LOGIN_ADVERTISES_SYNC" "READ_API_TURNS_ASSUME_NO_LEGACY" "READ_API_COORDINATION_OVERLAPS_ENABLED" "SEARCH_INDEX_POSTGRES_BACKEND_ID" "SEARCH_INDEX_OPENSEARCH_URL" "SEARCH_INDEX_OPENSEARCH_AUTH" "SEARCH_INDEX_OPENSEARCH_AWS_REGION" "SEARCH_INDEX_OPENSEARCH_INDEX_PREFIX" "READ_API_INTERNAL_SECRET" "READ_API_INTERNAL_SECRET_PREVIOUS" "READ_API_ACCESS_TOKEN_TTL_SECONDS" "READ_API_EVENT_MESSAGE_IDS" "SEARCH_INDEX_BACKEND" "ALLOW_IN_CLUSTER_HTTP" "RELAYAUTH_JWKS_URL" "RELAYAUTH_ISSUER" "RELAYHISTORY_ACCEPT_RELAYCONTROL_TOKENS" "RELAYCONTROL_INTROSPECT_URL" "RELAYCONTROL_INTROSPECT_SECRET" "SESSION_POSTGRES_TLS_PROFILE" "SESSION_POSTGRES_CA_FILE" "SESSION_POSTGRES_CA_SHA256" -}}
{{- $seen := dict -}}
{{- $canonical := dict -}}
{{- range $e := $c.extraEnv -}}
{{- $envName := required "session-read-api: extraEnv entries require name" $e.name -}}
{{- if or (has $envName $reserved) (hasKey $seen $envName) (hasPrefix "ANALYTICS_" $envName) (and $c.analytics.enabled (eq $envName "NODE_EXTRA_CA_CERTS")) }}{{ fail (printf "session-read-api: extraEnv duplicates a managed or repeated variable: %s" $envName) }}{{ end -}}
{{- if not (regexMatch "^[A-Za-z_][A-Za-z0-9_]*$" $envName) }}{{ fail "session-read-api: extraEnv has an invalid variable name" }}{{ end -}}
{{- if hasPrefix "CLICKHOUSE_" $envName }}{{ fail "session-read-api: the service reads no CLICKHOUSE_* environment; put ClickHouse in the read API Secret's clickhouse block" }}{{ end -}}
{{- if eq (hasKey $e "value") (hasKey $e "valueFrom") }}{{ fail "session-read-api: extraEnv requires exactly one of value or valueFrom" }}{{ end -}}
{{- if regexMatch "(?i)(^|_)(SECRET|TOKEN|PASSWORD|CREDENTIAL|DSN|API_KEY|PRIVATE_KEY|ACCESS_KEY|ACCESS_KEY_ID|DATABASE_URL|DB_URL|HOOPDB_URL|POSTGRES_URL|POSTGRESQL_URL|PGPASSWORD)$" $envName -}}
{{- if hasKey $e "value" }}{{ fail "session-read-api: sensitive extraEnv settings require valueFrom.secretKeyRef, never inline values" }}{{ end -}}
{{- if not (kindIs "map" $e.valueFrom) }}{{ fail "session-read-api: sensitive extraEnv settings require valueFrom.secretKeyRef" }}{{ end -}}
{{- if or (ne (len $e.valueFrom) 1) (not (hasKey $e.valueFrom "secretKeyRef")) }}{{ fail "session-read-api: sensitive extraEnv settings require valueFrom.secretKeyRef" }}{{ end -}}
{{- $ref := $e.valueFrom.secretKeyRef -}}
{{- if not (kindIs "map" $ref) }}{{ fail "session-read-api: extraEnv secretKeyRef must be an object" }}{{ end -}}
{{- if or (not (kindIs "string" $ref.name)) (not $ref.name) (not (kindIs "string" $ref.key)) (not $ref.key) }}{{ fail "session-read-api: extraEnv secretKeyRef requires nonempty string name and key" }}{{ end -}}
{{- end -}}
{{- $_ := set $seen $envName true -}}
{{- if has $envName (list "LOCKER_BUCKET" "PIPELINE_ORG_FROM_PREFIX" "PIPELINE_KEY_PREFIX") }}{{ $_ := set $canonical $envName $e }}{{ end -}}
{{- end -}}
{{- if and $c.events.messageIds (not (hasKey $canonical "LOCKER_BUCKET")) }}{{ fail "session-read-api: events.messageIds=true requires LOCKER_BUCKET in extraEnv; the service serves message ids only from the canonical store" }}{{ end -}}
{{- if hasKey $canonical "LOCKER_BUCKET" -}}
{{- $bucket := index $canonical "LOCKER_BUCKET" -}}
{{- if or (not (hasKey $bucket "value")) (not (kindIs "string" $bucket.value)) }}{{ fail "session-read-api: LOCKER_BUCKET requires an explicit nonempty literal value for canonical layout admission" }}{{ end -}}
{{- if or (not $bucket.value) (ne (trim $bucket.value) $bucket.value) }}{{ fail "session-read-api: LOCKER_BUCKET requires an explicit nonempty literal value without surrounding whitespace for canonical layout admission" }}{{ end -}}
{{- $orgPrefix := index $canonical "PIPELINE_ORG_FROM_PREFIX" | default dict -}}
{{- if or (not (hasKey $orgPrefix "value")) (ne (toString $orgPrefix.value) "true") }}{{ fail "session-read-api: LOCKER_BUCKET requires literal PIPELINE_ORG_FROM_PREFIX=true" }}{{ end -}}
{{- $keyPrefix := index $canonical "PIPELINE_KEY_PREFIX" | default dict -}}
{{- if or (not (hasKey $keyPrefix "value")) (ne (toString $keyPrefix.value) "96bulls") }}{{ fail "session-read-api: LOCKER_BUCKET requires literal PIPELINE_KEY_PREFIX=96bulls (the bare INGEST_KEY_ROOT, without an org suffix)" }}{{ end -}}
{{- end -}}
{{- end -}}
