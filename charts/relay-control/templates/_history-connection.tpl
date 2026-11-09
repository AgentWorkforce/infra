{{- define "relay-control.validateHistoryConnection" -}}
{{- $services := .Values.services -}}
{{- $url := $services.relayhistoryReadApiUrl -}}
{{- if not (kindIs "string" $url) }}{{ fail "services.relayhistoryReadApiUrl must be a string" }}{{ end -}}
{{- if not (kindIs "bool" $services.relayhistoryReadApiEvents) }}{{ fail "services.relayhistoryReadApiEvents must be a boolean" }}{{ end -}}
{{- if $url -}}
{{- $pattern := "^https://([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\\.)+[A-Za-z]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(:[0-9]{1,5})?$" -}}
{{- if or (not (regexMatch $pattern $url)) (regexMatch "(?i)\\.(localhost|local|internal|lan|invalid|test|example|home\\.arpa|onion)(:[0-9]{1,5})?$" $url) (regexMatch "(?i)\\.example\\.(com|net|org)(:[0-9]{1,5})?$" $url) }}{{ fail "services.relayhistoryReadApiUrl must be a bare public HTTPS DNS origin" }}{{ end -}}
{{- $port := regexFind ":[0-9]+$" $url -}}
{{- if and $port (or (lt (int (trimPrefix ":" $port)) 1) (gt (int (trimPrefix ":" $port)) 65535)) }}{{ fail "services.relayhistoryReadApiUrl port must be between 1 and 65535" }}{{ end -}}
{{- if not .Values.secretKeys.introspectSecret }}{{ fail "managed native History requires secretKeys.introspectSecret" }}{{ end -}}
{{- $audiences := .Values.introspection.audiences | default (list .Values.services.relayhistoryPublicUrl) -}}
{{- if not (has $url $audiences) }}{{ fail "SELFHOST_INTROSPECT_AUDIENCES must include the exact managed native History reader origin" }}{{ end -}}
{{- else if $services.relayhistoryReadApiEvents }}{{ fail "services.relayhistoryReadApiEvents requires services.relayhistoryReadApiUrl" }}{{ end -}}
{{- $aliases := $services.relayhistoryHostAliases -}}
{{- if not (kindIs "slice" $aliases) }}{{ fail "services.relayhistoryHostAliases must be a list" }}{{ end -}}
{{- if gt (len $aliases) 1 }}{{ fail "services.relayhistoryHostAliases accepts one explicit reader address" }}{{ end -}}
{{- range $aliases -}}
{{- if or (not $url) (not (kindIs "map" .)) }}{{ fail "services.relayhistoryHostAliases requires the managed reader URL and an ip/hostnames object" }}{{ end -}}
{{- if or (ne (len (keys .)) 2) (not (hasKey . "ip")) (not (hasKey . "hostnames")) }}{{ fail "each reader hostAlias must contain only ip and hostnames" }}{{ end -}}
{{- if or (not (kindIs "string" .ip)) (not (regexMatch "^([0-9]{1,3}\\.){3}[0-9]{1,3}$" (toString .ip))) }}{{ fail "reader hostAlias.ip must be an IPv4 literal" }}{{ end -}}
{{- range splitList "." .ip }}{{ if or (gt (int .) 255) (ne . (toString (int .))) }}{{ fail "reader hostAlias.ip must use canonical IPv4 octets" }}{{ end }}{{ end -}}
{{- if or (not (kindIs "slice" .hostnames)) (ne (len .hostnames) 1) }}{{ fail "reader hostAlias must name exactly the configured reader hostname" }}{{ end -}}
{{- if or (not (kindIs "string" (index .hostnames 0))) (ne (index .hostnames 0) ((urlParse $url).hostname)) }}{{ fail "reader hostAlias hostname must equal services.relayhistoryReadApiUrl hostname" }}{{ end -}}
{{- end -}}
{{- end -}}

{{- define "relay-control.historyConnectionEnv" -}}
{{- with .Values.services.relayhistoryReadApiUrl }}
- { name: RELAYHISTORY_READ_API_URL, value: {{ . | quote }} }
- { name: RELAYHISTORY_READ_API_EVENTS, value: {{ $.Values.services.relayhistoryReadApiEvents | quote }} }
{{- end -}}
{{- end -}}
