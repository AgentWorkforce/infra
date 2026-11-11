{{- define "relaycast.analytics.validate" -}}
{{- $a := .Values.analytics | default dict -}}
{{- if and (hasKey $a "enabled") (not (kindIs "bool" $a.enabled)) }}
{{- fail "analytics.enabled must be a boolean" }}
{{- end }}
{{- if $a.enabled }}
{{- if include "relaycast.actors.enabled" . }}
{{- fail "analytics.enabled requires the Relaycast Node runtime" }}
{{- end }}
{{- if hasKey (.Values.podLabels | default dict) "agentworkforce.dev/analytics-producer" }}
{{- fail "analytics.enabled manages the analytics-producer pod label" }}
{{- end }}
{{- if not (and (kindIs "string" $a.deploymentId) (regexMatch "^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$" (toString $a.deploymentId))) }}
{{- fail "analytics.deploymentId must be a stable opaque installation ID" }}
{{- end }}
{{- $endpoint := "^https://[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+(:[0-9]{1,5})?/v1/events$" }}
{{- if not (and (kindIs "string" $a.collectorUrl) (regexMatch $endpoint (toString $a.collectorUrl))) }}
{{- fail "analytics.collectorUrl must be an HTTPS DNS endpoint ending in /v1/events" }}
{{- end }}
{{- $host := (urlParse $a.collectorUrl).host }}
{{- if contains ":" $host }}
{{- $port := last (splitList ":" $host) | atoi }}
{{- if or (lt $port 1) (gt $port 65535) }}
{{- fail "analytics.collectorUrl port must be 1..65535" }}
{{- end }}
{{- end }}
{{- range $key := list "existingSecret" "caConfigMap" }}
{{- $value := get $a $key }}
{{- if not (and (kindIs "string" $value) (le (len (toString $value)) 253) (regexMatch "^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$" (toString $value))) }}
{{- fail (printf "analytics.%s must name an existing Kubernetes object" $key) }}
{{- end }}
{{- end }}
{{- if eq $a.existingSecret .Values.existingSecret }}
{{- fail "analytics.existingSecret must be separate from the Relaycast credential Secret" }}
{{- end }}
{{- range $key := list "tokenKey" "caKey" }}
{{- $value := get $a $key }}
{{- if not (and (kindIs "string" $value) (regexMatch "^[A-Za-z0-9_.-]{1,253}$" (toString $value)) (not (has $value (list "." "..")))) }}
{{- fail (printf "analytics.%s must be a Secret or ConfigMap key" $key) }}
{{- end }}
{{- end }}
{{- $image := .Values.image }}
{{- if include "relaycast.postgres.enabled" . }}
{{- $image = .Values.runtime.postgres.image }}
{{- end }}
{{- $withoutCollector := list "sha256:81274dca7ab58673383dc7a9c777f422f29606c7422e81b5ea15724770f1455e" "sha256:84f59482cb82f3c50d38f45cfca7d004cffaa95652782dbfc93c179cc343ac59" }}
{{- if or (not (regexMatch "^sha256:[a-f0-9]{64}$" (toString $image.digest))) (has $image.digest $withoutCollector) }}
{{- fail "analytics.enabled requires an immutable Relaycast image with collector support" }}
{{- end }}
{{- range .Values.extraEnv }}
{{- if or (hasPrefix "RELAYCAST_TELEMETRY_" .name) (has .name (list "NODE_EXTRA_CA_CERTS" "NODE_TLS_REJECT_UNAUTHORIZED")) }}
{{- fail (printf "%s cannot override managed Relaycast analytics" .name) }}
{{- end }}
{{- end }}
{{- else if or $a.collectorUrl $a.deploymentId $a.existingSecret $a.caConfigMap }}
{{- fail "analytics inputs require analytics.enabled=true" }}
{{- end }}
{{- end }}

{{- define "relaycast.analytics.env" -}}
- { name: RELAYCAST_TELEMETRY_DESTINATION, value: collector }
- { name: RELAYCAST_TELEMETRY_COLLECTOR_URL, value: {{ .Values.analytics.collectorUrl | quote }} }
- { name: RELAYCAST_TELEMETRY_DEPLOYMENT_ID, value: {{ .Values.analytics.deploymentId | quote }} }
- { name: RELAYCAST_TELEMETRY_COLLECTOR_TOKEN_FILE, value: /var/run/secrets/relaycast-analytics/token }
- { name: NODE_EXTRA_CA_CERTS, value: /etc/relaycast-analytics-ca/ca.crt }
{{- end }}
