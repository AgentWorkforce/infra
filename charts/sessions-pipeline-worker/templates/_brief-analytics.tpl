{{- define "sessions-pipeline-worker.validateBriefAnalytics" -}}
{{- $a := .Values.nativeBrief.analytics -}}
{{- if not (kindIs "map" $a) }}{{ fail "nativeBrief.analytics must be an object" }}{{ end -}}
{{- range $key, $_ := $a -}}
{{- if not (has $key (list "enabled" "deploymentId" "collectorUrl" "existingSecret" "tokenKey" "caConfigMap" "caKey" "egress")) }}{{ fail "nativeBrief.analytics contains an unsupported setting" }}{{ end -}}
{{- end -}}
{{- if not (kindIs "bool" $a.enabled) }}{{ fail "nativeBrief.analytics.enabled must be a boolean" }}{{ end -}}
{{- if not (kindIs "map" $a.egress) }}{{ fail "nativeBrief.analytics.egress must be an object" }}{{ end -}}
{{- if not (kindIs "slice" $a.egress.to) }}{{ fail "nativeBrief.analytics.egress.to must be a list" }}{{ end -}}
{{- range $key, $_ := $a.egress -}}
{{- if not (has $key (list "port" "to")) }}{{ fail "nativeBrief.analytics.egress contains an unsupported setting" }}{{ end -}}
{{- end -}}
{{- if .Values.nativeBrief.enabled -}}
{{- $brief := index .Values.components "session-brief" -}}
{{- range $entry := concat (.Values.extraEnv | default list) ($brief.env | default list) -}}
{{- if hasPrefix "ANALYTICS_" ($entry.name | default "") }}{{ fail "use nativeBrief.analytics for managed brief analytics" }}{{ end -}}
{{- end -}}
{{- end -}}
{{- if $a.enabled -}}
{{- if not .Values.nativeBrief.enabled }}{{ fail "nativeBrief.analytics requires nativeBrief.enabled" }}{{ end -}}
{{- if hasKey (.Values.podLabels | default dict) "agentworkforce.dev/analytics-producer" }}{{ fail "nativeBrief.analytics manages the analytics producer pod label" }}{{ end -}}
{{- if or (not (kindIs "string" $a.deploymentId)) (not (regexMatch "^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$" (toString $a.deploymentId))) }}{{ fail "nativeBrief.analytics.deploymentId must be an opaque installation ID" }}{{ end -}}
{{- if or (not (kindIs "string" $a.collectorUrl)) (not (regexMatch "^https://[a-z0-9]([-a-z0-9.]*[a-z0-9])?(:[0-9]{1,5})?/v1/events$" (toString $a.collectorUrl))) }}{{ fail "nativeBrief.analytics.collectorUrl must be an HTTPS collector URL ending in /v1/events" }}{{ end -}}
{{- $host := (urlParse $a.collectorUrl).host -}}
{{- if contains ":" $host -}}
{{- $port := last (splitList ":" $host) | atoi -}}
{{- if or (lt $port 1) (gt $port 65535) }}{{ fail "nativeBrief.analytics.collectorUrl port must be 1..65535" }}{{ end -}}
{{- end -}}
{{- if not $a.existingSecret }}{{ fail "nativeBrief.analytics.existingSecret is required" }}{{ end -}}
{{- range $key, $value := dict "existingSecret" $a.existingSecret "caConfigMap" $a.caConfigMap -}}
{{- if or (not (kindIs "string" $value)) (and (ne $value "") (or (gt (len $value) 253) (not (regexMatch "^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?(\\.[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?)*$" $value)))) }}{{ fail (printf "nativeBrief.analytics.%s must be a Kubernetes object name" $key) }}{{ end -}}
{{- end -}}
{{- range $key, $value := dict "tokenKey" $a.tokenKey "caKey" $a.caKey -}}
{{- if or (not (kindIs "string" $value)) (gt (len $value) 253) (not (regexMatch "^[A-Za-z0-9._-]+$" $value)) }}{{ fail (printf "nativeBrief.analytics.%s must be a Kubernetes data key" $key) }}{{ end -}}
{{- end -}}
{{- $managedEgress := or .Values.networkPolicy.enabled .Values.nativeBrief.openaiEgress.enabled -}}
{{- if and $managedEgress (empty $a.egress.to) }}{{ fail "nativeBrief.analytics.egress.to must list collector peers when chart-managed egress selects the brief worker" }}{{ end -}}
{{- if and (not $managedEgress) $a.egress.to }}{{ fail "nativeBrief.analytics.egress.to requires a chart-managed brief egress policy" }}{{ end -}}
{{- if or (not (regexMatch "^[0-9]+$" (toString $a.egress.port))) (lt (int $a.egress.port) 1) (gt (int $a.egress.port) 65535) }}{{ fail "nativeBrief.analytics.egress.port must be an integer 1..65535" }}{{ end -}}
{{- range $peer := $a.egress.to -}}
{{- if not (kindIs "map" $peer) }}{{ fail "nativeBrief.analytics.egress.to must contain collector pod selectors" }}{{ end -}}
{{- if not (hasKey $peer "podSelector") }}{{ fail "nativeBrief.analytics.egress.to must contain collector pod selectors" }}{{ end -}}
{{- range $key, $selector := $peer -}}
{{- if or (not (has $key (list "podSelector" "namespaceSelector"))) (not (kindIs "map" $selector)) }}{{ fail "nativeBrief.analytics.egress.to only accepts pod and namespace selectors" }}{{ end -}}
{{- if and (empty $selector.matchLabels) (empty $selector.matchExpressions) }}{{ fail "nativeBrief.analytics.egress.to selectors must match explicit labels" }}{{ end -}}
{{- end -}}
{{- end -}}
{{- else if or $a.existingSecret $a.collectorUrl $a.deploymentId $a.caConfigMap $a.egress.to -}}
{{- fail "nativeBrief.analytics inputs require enabled=true" -}}
{{- end -}}
{{- end -}}

{{- define "sessions-pipeline-worker.briefAnalyticsEnv" -}}
{{- $a := .Values.nativeBrief.analytics -}}
{{- if $a.enabled }}
- { name: ANALYTICS_SINK, value: collector }
- { name: ANALYTICS_DEPLOYMENT_ID, value: {{ $a.deploymentId | quote }} }
- { name: ANALYTICS_COLLECTOR_URL, value: {{ $a.collectorUrl | quote }} }
- name: ANALYTICS_COLLECTOR_TOKEN
  valueFrom:
    secretKeyRef: { name: {{ $a.existingSecret | quote }}, key: {{ $a.tokenKey | quote }} }
{{- if $a.caConfigMap }}
- { name: ANALYTICS_COLLECTOR_CA_FILE, value: /etc/brief-analytics-ca/ca.crt }
{{- end }}
{{- end }}
{{- end -}}
