{{- define "relay-control.validateAdapters" -}}
{{- $object := "^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?(\\.[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?)*$" -}}
{{- $dataKey := "^[A-Za-z0-9._-]+$" -}}
{{- $i := .Values.introspection -}}
{{- if not (kindIs "map" $i) }}{{ fail "introspection must be an object" }}{{ end -}}
{{- if not (kindIs "string" $i.existingSecret) }}{{ fail "introspection.existingSecret must be a Kubernetes Secret name" }}{{ end -}}
{{- if $i.existingSecret -}}
{{- if or (gt (len $i.existingSecret) 253) (not (regexMatch $object $i.existingSecret)) }}{{ fail "introspection.existingSecret must be a Kubernetes Secret name" }}{{ end -}}
{{- if or (not (kindIs "string" $i.key)) (gt (len $i.key) 253) (not (regexMatch $dataKey $i.key)) }}{{ fail "introspection.key must be a Kubernetes data key" }}{{ end -}}
{{- if .Values.secretKeys.introspectSecret }}{{ fail "choose introspection.existingSecret or secretKeys.introspectSecret, never both" }}{{ end -}}
{{- if eq $i.existingSecret .Values.existingSecret -}}
{{- range $key := values .Values.secretKeys }}{{ if and $key (eq $i.key $key) }}{{ fail "introspection must not reuse an application, identity or migration credential" }}{{ end }}{{ end -}}
{{- end -}}
{{- end -}}
{{- $a := .Values.analytics -}}
{{- if not (kindIs "map" $a) }}{{ fail "analytics must be an object" }}{{ end -}}
{{- range $key, $_ := $a }}{{ if not (has $key (list "enabled" "deploymentId" "profile" "collectorUrl" "existingSecret" "tokenKey" "caConfigMap" "caKey")) }}{{ fail "analytics contains an unsupported setting; use the managed collector adapter" }}{{ end }}{{ end -}}
{{- if not (kindIs "bool" $a.enabled) }}{{ fail "analytics.enabled must be a boolean" }}{{ end -}}
{{- if $a.enabled -}}
{{- if or (not (kindIs "string" $a.deploymentId)) (not (regexMatch "^[A-Za-z0-9_-]{8,64}$" $a.deploymentId)) }}{{ fail "analytics.deploymentId must be an opaque 8-64 character collector registration id" }}{{ end -}}
{{- if not (has $a.profile (list "production" "development")) }}{{ fail "analytics.profile must be production or development" }}{{ end -}}
{{- if or (not (kindIs "string" $a.collectorUrl)) (not (regexMatch "^https://([a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?\\.)+[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?(:[0-9]{1,5})?/v1/events$" $a.collectorUrl)) }}{{ fail "analytics.collectorUrl must be a complete HTTPS DNS endpoint ending /v1/events, without credentials, query or fragment" }}{{ end -}}
{{- $url := urlParse $a.collectorUrl -}}
{{- if or (gt (len $url.hostname) 253) (regexMatch "^[0-9]+(\\.[0-9]+){3}$" $url.hostname) }}{{ fail "analytics.collectorUrl requires a DNS host, not an IP address" }}{{ end -}}
{{- $port := regexFind ":[0-9]+$" $url.host -}}
{{- if and $port (or (lt (atoi (trimPrefix ":" $port)) 1) (gt (atoi (trimPrefix ":" $port)) 65535)) }}{{ fail "analytics.collectorUrl port must be 1..65535" }}{{ end -}}
{{- range $key, $value := dict "existingSecret" $a.existingSecret "caConfigMap" $a.caConfigMap -}}
{{- if or (not (kindIs "string" $value)) (and $value (or (gt (len $value) 253) (not (regexMatch $object $value)))) }}{{ fail (printf "analytics.%s must be a Kubernetes object name" $key) }}{{ end -}}
{{- end -}}
{{- if not $a.existingSecret }}{{ fail "analytics.existingSecret is required; inline producer credentials are unsupported" }}{{ end -}}
{{- if or (eq $a.existingSecret .Values.existingSecret) (eq $a.existingSecret $i.existingSecret) }}{{ fail "analytics requires a dedicated producer Secret, separate from application and introspection credentials" }}{{ end -}}
{{- range $key, $value := dict "tokenKey" $a.tokenKey "caKey" $a.caKey -}}
{{- if or (not (kindIs "string" $value)) (gt (len $value) 253) (not (regexMatch $dataKey $value)) }}{{ fail (printf "analytics.%s must be a Kubernetes data key" $key) }}{{ end -}}
{{- end -}}
{{- if hasKey (.Values.podLabels | default dict) "agentworkforce.dev/analytics-producer" }}{{ fail "analytics manages the producer Pod label; remove it from podLabels" }}{{ end -}}
{{- end -}}
{{- $erase := .Values.sessionErasureApi -}}
{{- if not (kindIs "map" $erase) }}{{ fail "sessionErasureApi must be an object" }}{{ end -}}
{{- if not (kindIs "bool" $erase.enabled) }}{{ fail "sessionErasureApi.enabled must be a boolean" }}{{ end -}}
{{- range $name := list "url" "existingSecret" "secretKey" }}{{ if not (kindIs "string" (index $erase $name)) }}{{ fail (printf "sessionErasureApi.%s must be a string" $name) }}{{ end }}{{ end -}}
{{- if $erase.enabled -}}
{{- $_ := include "relay-control.historyUpload.endpoint" (dict "name" "sessionErasureApi.url" "url" (required "sessionErasureApi.url is required" $erase.url) "internal" true) -}}
{{- if or (not $erase.existingSecret) (gt (len $erase.existingSecret) 253) (not (regexMatch $object $erase.existingSecret)) }}{{ fail "sessionErasureApi.existingSecret must be a Kubernetes Secret name" }}{{ end -}}
{{- if or (not $erase.secretKey) (gt (len $erase.secretKey) 253) (not (regexMatch $dataKey $erase.secretKey)) }}{{ fail "sessionErasureApi.secretKey must be a Kubernetes Secret data key" }}{{ end -}}
{{- if or (eq $erase.existingSecret .Values.existingSecret) (eq $erase.existingSecret $i.existingSecret) (eq $erase.existingSecret $a.existingSecret) }}{{ fail "sessionErasureApi requires a dedicated Secret, separate from application, introspection and analytics credentials" }}{{ end -}}
{{- else if or $erase.url $erase.existingSecret -}}
{{- fail "sessionErasureApi.url and existingSecret require enabled=true" -}}
{{- end -}}
{{- end -}}

{{- define "relay-control.analyticsEnv" -}}
{{- if .Values.analytics.enabled }}
- { name: SELFHOST_ANALYTICS_DESTINATION, value: collector }
- { name: SELFHOST_ANALYTICS_PROFILE, value: {{ .Values.analytics.profile | quote }} }
- { name: SELFHOST_ANALYTICS_DEPLOYMENT_ID, value: {{ .Values.analytics.deploymentId | quote }} }
- { name: SELFHOST_ANALYTICS_COLLECTOR_URL, value: {{ .Values.analytics.collectorUrl | quote }} }
- { name: SELFHOST_ANALYTICS_COLLECTOR_TOKEN_FILE, value: /var/run/secrets/analytics-control/token }
{{- if .Values.analytics.caConfigMap }}
- { name: SELFHOST_ANALYTICS_COLLECTOR_CA_FILE, value: /var/run/analytics-collector-ca/ca.crt }
{{- end }}
{{- end }}
{{- end -}}

{{- define "relay-control.sessionErasureApiEnv" -}}
{{- if .Values.sessionErasureApi.enabled }}
- { name: SESSION_ERASE_API_URL, value: {{ .Values.sessionErasureApi.url | quote }} }
- name: SESSION_ERASE_API_SECRET
  valueFrom:
    secretKeyRef: { name: {{ .Values.sessionErasureApi.existingSecret | quote }}, key: {{ .Values.sessionErasureApi.secretKey | quote }} }
{{- end }}
{{- end -}}
