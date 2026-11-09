{{/* Go-only managed contracts. Empty/off values preserve legacy rendering. */}}
{{- define "relayfile.go.managed" -}}
{{- if or .Values.postgres.enabled (eq .Values.auth.mode "introspection") }}true{{ end -}}
{{- end -}}

{{- define "relayfile.go.resourceName" -}}
{{- $name := .name -}}
{{- if or (not (kindIs "string" $name)) (not $name) (gt (len $name) 253) }}{{ fail (printf "%s must be a Kubernetes DNS subdomain name" .path) }}{{ end -}}
{{- range splitList "." $name -}}
{{- if or (gt (len .) 63) (not (regexMatch "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$" .)) }}{{ fail (printf "%s must be a Kubernetes DNS subdomain name" $.path) }}{{ end -}}
{{- end -}}
{{- end -}}

{{- define "relayfile.go.secretRef" -}}
{{- include "relayfile.go.resourceName" (dict "name" .ref.name "path" (printf "%s.name" .path)) -}}
{{- if or (not (kindIs "string" .ref.key)) (not (regexMatch "^[A-Za-z0-9._-]{1,253}$" .ref.key)) }}{{ fail (printf "%s.key must be a Kubernetes Secret data key" .path) }}{{ end -}}
{{- end -}}

{{- define "relayfile.go.origin" -}}
{{- $url := .value -}}
{{- if or (not (kindIs "string" $url)) (not (regexMatch "^https?://[A-Za-z0-9.-]+(:[1-9][0-9]{0,4})?$" $url)) }}{{ fail (printf "%s must be a bare http(s) origin without userinfo, path, query, fragment or a noncanonical port" .path) }}{{ end -}}
{{- $parts := urlParse $url -}}
{{- include "relayfile.go.resourceName" (dict "name" (regexReplaceAll ":[0-9]+$" $parts.host "" | lower) "path" (printf "%s hostname" .path)) -}}
{{- if and .https (ne $parts.scheme "https") }}{{ fail (printf "%s must be an HTTPS origin" .path) }}{{ end -}}
{{- if regexMatch ":[0-9]+$" $parts.host -}}
{{- $port := regexFind "[0-9]+$" $parts.host | int -}}
{{- if or (lt $port 1) (gt $port 65535) }}{{ fail (printf "%s port must be between 1 and 65535" .path) }}{{ end -}}
{{- end -}}
{{- end -}}

{{- define "relayfile.go.validate" -}}
{{- if not (kindIs "map" .Values.postgres) }}{{ fail "postgres must be an object with boolean postgres.enabled" }}{{ end -}}
{{- if not (kindIs "bool" .Values.postgres.enabled) }}{{ fail "postgres.enabled must be a boolean" }}{{ end -}}
{{- if not (has .Values.auth.mode (list "" "introspection")) }}{{ fail "auth.mode must be empty or introspection" }}{{ end -}}
{{- $auth := eq .Values.auth.mode "introspection" -}}
{{- $pg := .Values.postgres.enabled -}}
{{- if or $auth $pg -}}
{{- if ne .Values.runtime.backend "go" }}{{ fail "managed introspection and postgres.enabled require runtime.backend=go" }}{{ end -}}
{{- if or (not (kindIs "string" .Values.image.repository)) (not .Values.image.repository) (not (regexMatch "^sha256:[a-f0-9]{64}$" .Values.image.digest)) .Values.image.tag }}{{ fail "managed Go mode requires image.repository and image.digest with an empty image.tag" }}{{ end -}}
{{- include "relayfile.go.resourceName" (dict "name" .Values.secrets.existingSecret "path" "secrets.existingSecret") -}}
{{- if .Values.extraEnvFrom }}{{ fail "managed Go mode forbids extraEnvFrom; use explicit non-conflicting extraEnv entries" }}{{ end -}}
{{- $reserved := list "RELAYFILE_INTERNAL_HMAC_SECRET" "RELAYFILE_DEV_MODE" -}}
{{- if $auth }}{{ $reserved = concat $reserved (list "RELAYFILE_AUTH_MODE" "RELAYAUTH_JWKS_URL" "RELAYFILE_JWT_SECRET" "RELAYCONTROL_INTERNAL_URL" "RELAYCONTROL_INTROSPECT_SECRET" "RELAYCONTROL_INTROSPECT_SECRET_FILE" "RELAYFILE_PUBLIC_ORIGIN" "RELAYFILE_INTROSPECTION_TIMEOUT" "RELAYFILE_INTROSPECTION_CACHE_TTL") }}{{ end -}}
{{- if $pg }}{{ $reserved = concat $reserved (list "RELAYFILE_BACKEND_PROFILE" "RELAYFILE_STATE_BACKEND_DSN" "RELAYFILE_STATE_FILE" "RELAYFILE_ENVELOPE_QUEUE_DSN" "RELAYFILE_WRITEBACK_QUEUE_DSN" "RELAYFILE_ENVELOPE_QUEUE_FILE" "RELAYFILE_WRITEBACK_QUEUE_FILE" "RELAYFILE_PRODUCTION_DSN" "RELAYFILE_POSTGRES_DSN") }}{{ end -}}
{{- range .Values.extraEnv -}}
{{- if or (has .name $reserved) (and $pg (hasPrefix "PG" .name)) }}{{ fail (printf "%s is managed by the selected Go contract; remove it from extraEnv" .name) }}{{ end -}}
{{- end -}}
{{- if hasKey .Values.podSecurityContext "fsGroup" -}}
{{- if or (not (include "relayfile.isInt" .Values.podSecurityContext.fsGroup)) (lt (int64 .Values.podSecurityContext.fsGroup) 0) }}{{ fail "managed Go podSecurityContext.fsGroup must be a non-negative integer" }}{{ end -}}
{{- end -}}
{{- end -}}
{{- if $auth -}}
{{- if .Values.auth.jwksUrl }}{{ fail "auth.mode=introspection forbids auth.jwksUrl; there is no JWKS fallback" }}{{ end -}}
{{- $i := .Values.auth.introspection -}}
{{- include "relayfile.go.origin" (dict "value" $i.internalUrl "path" "auth.introspection.internalUrl" "https" false) -}}
{{- include "relayfile.go.origin" (dict "value" $i.publicOrigin "path" "auth.introspection.publicOrigin" "https" true) -}}
{{- include "relayfile.go.secretRef" (dict "ref" $i.secretRef "path" "auth.introspection.secretRef") -}}
{{- if or (not (include "relayfile.isInt" $i.timeoutSeconds)) (lt (int64 $i.timeoutSeconds) 1) (gt (int64 $i.timeoutSeconds) 30) }}{{ fail "auth.introspection.timeoutSeconds must be an integer from 1 to 30" }}{{ end -}}
{{- if or (not (include "relayfile.isInt" $i.cacheTtlSeconds)) (lt (int64 $i.cacheTtlSeconds) 0) (gt (int64 $i.cacheTtlSeconds) 60) }}{{ fail "auth.introspection.cacheTtlSeconds must be an integer from 0 to 60" }}{{ end -}}
{{- else if or .Values.auth.introspection.internalUrl .Values.auth.introspection.publicOrigin .Values.auth.introspection.secretRef.name -}}
{{- fail "auth.introspection settings require auth.mode=introspection" -}}
{{- end -}}
{{- if $pg -}}
{{- if or (not (include "relayfile.isInt" .Values.replicaCount)) (ne (int64 .Values.replicaCount) 1) .Values.autoscaling.enabled }}{{ fail "postgres.enabled requires replicaCount=1 and autoscaling.enabled=false; concurrent snapshot writers are not qualified" }}{{ end -}}
{{- if not (has .Values.server.backendProfile (list "production" "prod")) }}{{ fail "postgres.enabled requires server.backendProfile=production" }}{{ end -}}
{{- if .Values.secrets.productionDsn }}{{ fail "postgres.enabled uses only postgres.runtimeSecret; remove secrets.productionDsn" }}{{ end -}}
{{- range $field := list "database" "ownerRole" "runtimeRole" -}}
{{- if not (regexMatch "^[a-z_][a-z0-9_]{0,62}$" (index $.Values.postgres $field)) }}{{ fail (printf "postgres.%s must match the official PostgreSQL role/database identifier contract" $field) }}{{ end -}}
{{- end -}}
{{- if eq .Values.postgres.ownerRole .Values.postgres.runtimeRole }}{{ fail "postgres.runtimeRole must differ from postgres.ownerRole" }}{{ end -}}
{{- include "relayfile.go.secretRef" (dict "ref" .Values.postgres.runtimeSecret "path" "postgres.runtimeSecret") -}}
{{- include "relayfile.go.resourceName" (dict "name" .Values.postgres.ca.configMap "path" "postgres.ca.configMap") -}}
{{- if not (regexMatch "^[A-Za-z0-9._-]{1,253}$" .Values.postgres.ca.key) }}{{ fail "postgres.ca.key must be a Kubernetes ConfigMap data key" }}{{ end -}}
{{- if not (regexMatch "^[a-f0-9]{64}$" .Values.postgres.ca.sha256) }}{{ fail "postgres.ca.sha256 must contain exactly 64 lowercase hex characters" }}{{ end -}}
{{- end -}}
{{- end -}}

{{- define "relayfile.go.podSecurityContext" -}}
{{- $context := deepCopy .Values.podSecurityContext -}}
{{- if not (hasKey $context "fsGroup") }}{{ $_ := set $context "fsGroup" 1000 }}{{ end -}}
{{- if not (hasKey $context "fsGroupChangePolicy") }}{{ $_ := set $context "fsGroupChangePolicy" "OnRootMismatch" }}{{ end -}}
{{- toYaml $context -}}
{{- end -}}
