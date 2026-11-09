{{- define "sessions-pipeline.nativeRouting.fullname" -}}
{{- default (printf "%s-native-history" .Release.Name) .Values.nativeRouting.fullnameOverride -}}
{{- end -}}

{{- /* These are the existing native Service names, not their container ports.
Keep admission tests bound to the actual rendered read-api/ingest-edge Services. */ -}}
{{- define "sessions-pipeline.nativeRouting.readerServiceName" -}}
{{- default (printf "%s-read-api" .Release.Name) .Values.sessionReadApi.fullnameOverride -}}
{{- end -}}
{{- define "sessions-pipeline.nativeRouting.ingestServiceName" -}}
{{- default (printf "%s-ingest-edge" .Release.Name) .Values.ingestEdge.fullnameOverride -}}
{{- end -}}

{{- define "sessions-pipeline.nativeRouting.validate" -}}
{{- $c := .Values.nativeRouting -}}
{{- if not (kindIs "map" $c) }}{{ fail "nativeRouting must be an object" }}{{ end -}}
{{- if not (kindIs "bool" $c.enabled) }}{{ fail "nativeRouting.enabled must be a boolean" }}{{ end -}}
{{- range $name, $_ := $c -}}
{{- if not (has $name (list "enabled" "fullnameOverride" "origin" "className" "tls")) }}{{ fail (printf "nativeRouting.%s is unsupported; routes and backends are managed" $name) }}{{ end -}}
{{- end -}}
{{- if $c.enabled -}}
{{- if or (not (kindIs "bool" .Values.sessionReadApi.enabled)) (not (kindIs "bool" .Values.ingestEdge.enabled)) (not .Values.sessionReadApi.enabled) (not .Values.ingestEdge.enabled) }}{{ fail "nativeRouting requires sessionReadApi.enabled=true and ingestEdge.enabled=true" }}{{ end -}}
{{- $reader := .Values.sessionReadApi -}}
{{- if not (has $reader.auth.mode (list "relaycontrol_only" "self_issued")) }}{{ fail "nativeRouting requires a supported Control-owned or independent-issuer reader mode" }}{{ end -}}
{{- if eq $reader.auth.mode "self_issued" -}}
{{- if or $reader.login.advertisesSync $reader.auth.relaycontrol.enabled $reader.auth.relaycontrol.url $reader.auth.relaycontrol.existingSecret }}{{ fail "self-issued native routing refuses reader sync-login and Control introspection; Control owns sync issuance" }}{{ end -}}
{{- if not $reader.events.messageIds }}{{ fail "self-issued native routing requires native message IDs for Control dashboard events" }}{{ end -}}
{{- else -}}
{{- if or (not (kindIs "bool" $reader.login.advertisesSync)) (not $reader.login.advertisesSync) }}{{ fail "nativeRouting requires sessionReadApi.login.advertisesSync=true for the caller-token composition" }}{{ end -}}
{{- end -}}
{{- range $field := list "fullnameOverride" "origin" "className" -}}
{{- if not (kindIs "string" (get $c $field)) }}{{ fail (printf "nativeRouting.%s must be a string" $field) }}{{ end -}}
{{- end -}}
{{- $origin := required "nativeRouting.origin is required" $c.origin -}}
{{- $pattern := "^https://([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z]([a-z0-9-]{0,61}[a-z0-9])?(:[0-9]{1,5})?$" -}}
{{- $host := regexReplaceAll ":[0-9]+$" (trimPrefix "https://" $origin) "" -}}
{{- if or (not (regexMatch $pattern $origin)) (gt (len $host) 253) (regexMatch "\\.(localhost|local|internal|lan|invalid|test|example|home\\.arpa|onion)$" $host) (regexMatch "(^|\\.)example\\.(com|net|org)$" $host) }}{{ fail "nativeRouting.origin must be a normalized public HTTPS origin with lowercase DNS and no credentials, path, query or fragment" }}{{ end -}}
{{- $port := regexFind ":[0-9]+$" $origin -}}
{{- if and $port (or (lt (int (trimPrefix ":" $port)) 1) (gt (int (trimPrefix ":" $port)) 65535) (eq (int (trimPrefix ":" $port)) 443) (ne $port (printf ":%d" (int (trimPrefix ":" $port))))) }}{{ fail "nativeRouting.origin port must be valid and normalized without leading zeros or the default HTTPS port" }}{{ end -}}
{{- if or (ne $origin .Values.sessionReadApi.origin) (ne $origin .Values.ingestEdge.origin) }}{{ fail "nativeRouting.origin must exactly equal sessionReadApi.origin and ingestEdge.origin, including any port" }}{{ end -}}
{{- if not (kindIs "map" $c.tls) }}{{ fail "nativeRouting.tls must be an object" }}{{ end -}}
{{- range $name, $_ := $c.tls -}}
{{- if ne $name "existingSecret" }}{{ fail (printf "nativeRouting.tls.%s is unsupported; select an existingSecret" $name) }}{{ end -}}
{{- end -}}
{{- if not (kindIs "string" $c.tls.existingSecret) }}{{ fail "nativeRouting.tls.existingSecret must be a string" }}{{ end -}}
{{- $secret := required "nativeRouting.tls.existingSecret is required" $c.tls.existingSecret -}}
{{- $class := required "nativeRouting.className is required" $c.className -}}
{{- $dns := "^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?(\\.[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?)*$" -}}
{{- range $field, $value := dict "fullnameOverride" (include "sessions-pipeline.nativeRouting.fullname" .) "className" $class "tls.existingSecret" $secret -}}
{{- if or (gt (len $value) 253) (not (regexMatch $dns $value)) }}{{ fail (printf "nativeRouting.%s must be a Kubernetes DNS subdomain name" $field) }}{{ end -}}
{{- end -}}
{{- if eq (include "sessions-pipeline.nativeRouting.readerServiceName" .) (include "sessions-pipeline.nativeRouting.ingestServiceName" .) }}{{ fail "nativeRouting requires distinct reader and ingest Service names" }}{{ end -}}
{{- end -}}
{{- end -}}
