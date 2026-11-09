{{- define "session-read-api.analytics.validate" -}}
{{- $a := . -}}
{{- if not (kindIs "map" $a) }}{{ fail "analytics must be an object" }}{{ end -}}
{{- range $k, $_ := $a -}}
{{- if not (has $k (list "enabled" "deploymentId" "collectorUrl" "existingSecret" "tokenKey" "caConfigMap" "caKey")) }}{{ fail "analytics contains an unsupported setting; use managed collector configuration" }}{{ end -}}
{{- end -}}
{{- if not (kindIs "bool" $a.enabled) }}{{ fail "analytics.enabled must be a boolean" }}{{ end -}}
{{- if $a.enabled -}}
{{- if or (not (kindIs "string" $a.deploymentId)) (not (regexMatch "^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$" $a.deploymentId)) }}{{ fail "analytics.deploymentId must be an opaque installation id" }}{{ end -}}
{{- if or (not (kindIs "string" $a.collectorUrl)) (not (regexMatch "^https://[a-z0-9]([-a-z0-9.]*[a-z0-9])?(:[0-9]{1,5})?/v1/events$" $a.collectorUrl)) }}{{ fail "analytics.collectorUrl must be an HTTPS collector URL without credentials, query or fragment" }}{{ end -}}
{{- $host := (urlParse $a.collectorUrl).host -}}
{{- if contains ":" $host -}}
{{- $port := last (splitList ":" $host) | atoi -}}
{{- if or (lt $port 1) (gt $port 65535) }}{{ fail "analytics.collectorUrl port must be 1..65535" }}{{ end -}}
{{- end -}}
{{- range $name, $v := dict "existingSecret" $a.existingSecret "caConfigMap" $a.caConfigMap -}}
{{- if or (not (kindIs "string" $v)) (and (ne $v "") (or (gt (len $v) 253) (not (regexMatch "^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?(\\.[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?)*$" $v)))) }}{{ fail (printf "analytics.%s must be a Kubernetes object name" $name) }}{{ end -}}
{{- end -}}
{{- if not $a.existingSecret }}{{ fail "analytics.existingSecret is required; no inline producer credentials" }}{{ end -}}
{{- range $name, $v := dict "tokenKey" $a.tokenKey "caKey" $a.caKey -}}
{{- if or (not (kindIs "string" $v)) (gt (len $v) 253) (not (regexMatch "^[A-Za-z0-9._-]+$" $v)) }}{{ fail (printf "analytics.%s must be a Kubernetes data key" $name) }}{{ end -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "session-read-api.analytics.env" -}}
{{- if .enabled }}
- { name: ANALYTICS_SINK, value: collector }
- { name: ANALYTICS_DEPLOYMENT_ID, value: {{ .deploymentId | quote }} }
- { name: ANALYTICS_COLLECTOR_URL, value: {{ .collectorUrl | quote }} }
- name: ANALYTICS_COLLECTOR_TOKEN
  valueFrom:
    secretKeyRef: { name: {{ .existingSecret | quote }}, key: {{ .tokenKey | quote }} }
{{- if .caConfigMap }}
- { name: NODE_EXTRA_CA_CERTS, value: /etc/analytics-ca/ca.crt }
{{- end }}
{{- end }}
{{- end -}}

{{- define "session-read-api.analytics.mount" -}}
{{- if and .enabled .caConfigMap }}
- { name: analytics-ca, mountPath: /etc/analytics-ca, readOnly: true }
{{- end }}
{{- end -}}

{{- define "session-read-api.analytics.volume" -}}
{{- if and .enabled .caConfigMap }}
- name: analytics-ca
  configMap:
    name: {{ .caConfigMap | quote }}
    defaultMode: 0444
    items: [{ key: {{ .caKey | quote }}, path: ca.crt }]
{{- end }}
{{- end -}}
