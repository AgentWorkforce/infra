{{- define "relayfile-control.name" -}}{{ default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}{{- end -}}
{{- /* A release named after the chart keeps the bare name, so the default
`helm install relayfile-control` Service matches EKS_ALB_RELAYFILE_CONTROL_SERVICE. */ -}}
{{- define "relayfile-control.fullname" -}}{{ if .Values.fullnameOverride }}{{ .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}{{ else if contains (include "relayfile-control.name" .) .Release.Name }}{{ .Release.Name | trunc 63 | trimSuffix "-" }}{{ else }}{{ printf "%s-%s" .Release.Name (include "relayfile-control.name" .) | trunc 63 | trimSuffix "-" }}{{ end }}{{- end -}}
{{- define "relayfile-control.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{ include "relayfile-control.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}
{{- define "relayfile-control.selectorLabels" -}}
app.kubernetes.io/name: {{ include "relayfile-control.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: server
{{- end -}}
{{- define "relayfile-control.serviceAccountName" -}}{{ if .Values.serviceAccount.create }}{{ default (include "relayfile-control.fullname" .) .Values.serviceAccount.name }}{{ else }}{{ default "default" .Values.serviceAccount.name }}{{ end }}{{- end -}}
{{- define "relayfile-control.image" -}}
{{- $digest := required "image.digest is required; relayfile-control images must be pinned by sha256 digest" .Values.image.digest -}}
{{- if not (regexMatch "^sha256:[a-f0-9]{64}$" $digest) }}{{ fail "image.digest must be sha256:<64 lowercase hex characters>" }}{{ end -}}
{{- printf "%s@%s" .Values.image.repository $digest -}}
{{- end -}}

{{- /* Secret env the chart injects, as [env, secretKeys field] pairs. */ -}}
{{- define "relayfile-control.secretPairs" -}}
{{- $core := list (list "DATABASE_URL" "databaseUrl") (list "RELAYFILE_INTERNAL_HMAC_SECRET" "relayfileInternalHmacSecret") (list "RELAYFILE_CONTROL_ADMIN_TOKEN" "adminToken") (list "RELAYCONTROL_SERVICE_TOKEN" "relaycontrolServiceToken") -}}
{{- $flows := list (list "RELAYCONTROL_INTROSPECT_SECRET" "introspectSecret") (list "RELAYFILE_CONTROL_BROKER_SECRET" "brokerSecret") (list "RELAYFILE_CONTROL_ENCRYPTION_KEY" "encryptionKey") -}}
{{- $flowsOptional := list (list "RELAYFILE_CONTROL_ENCRYPTION_PREVIOUS_KEY" "previousEncryptionKey") (list "RELAYFILE_CONTROL_TELEMETRY_SECRET" "telemetrySecret") (list "RELAYFILE_CONTROL_RUNTIME_VERIFY_SECRET" "runtimeVerifySecret") -}}
{{- $webhooks := list (list "GITHUB_WEBHOOK_SECRET" "githubWebhookSecret") (list "NANGO_WEBHOOK_SECRET" "nangoWebhookSecret") (list "HOOKDECK_WEBHOOK_SECRET" "hookdeckWebhookSecret") (list "DROPBOX_APP_SECRET" "dropboxAppSecret") (list "SLACK_SIGNING_SECRET" "slackSigningSecret") (list "LINEAR_WEBHOOK_SECRET" "linearWebhookSecret") -}}
{{- dict "core" $core "flows" $flows "flowsOptional" $flowsOptional "webhooks" $webhooks | toJson -}}
{{- end -}}

{{- define "relayfile-control.secretEnvVar" -}}
- name: {{ .name }}
  valueFrom:
    secretKeyRef:
      name: {{ .secret }}
      key: {{ .key | quote }}
{{- end -}}

{{- define "relayfile-control.secretEnv" -}}
{{- $root := . -}}
{{- $pairs := include "relayfile-control.secretPairs" . | fromJson -}}
{{- $active := concat $pairs.core $pairs.webhooks -}}
{{- if .Values.flows.enabled }}{{ $active = concat $active $pairs.flows $pairs.flowsOptional }}{{ end -}}
{{- range $i, $pair := $active }}
{{- $key := get $root.Values.secretKeys (index $pair 1) -}}
{{- if $key }}
{{ include "relayfile-control.secretEnvVar" (dict "name" (index $pair 0) "secret" $root.Values.existingSecret "key" $key) }}
{{- end }}
{{- end }}
{{- end -}}

{{- define "relayfile-control.validate" -}}
{{- $image := include "relayfile-control.image" . -}}
{{- $replicas := .Values.replicaCount -}}
{{- if not (and (or (kindIs "int" $replicas) (kindIs "int64" $replicas) (kindIs "float64" $replicas)) (eq (float64 $replicas) 1.0)) }}{{ fail "replicaCount must be 1: the chart runs one replica and makes no HA claim" }}{{ end -}}
{{- if not .Values.existingSecret }}{{ fail "existingSecret is required; the chart never creates Secrets" }}{{ end -}}
{{- range $name, $key := .Values.secretKeys }}{{ if and $key (not (regexMatch "^[A-Za-z0-9._-]+$" (toString $key))) }}{{ fail (printf "secretKeys.%s must be a Kubernetes Secret data key" $name) }}{{ end }}{{ end -}}
{{- range $name := list "databaseUrl" "relayfileInternalHmacSecret" "adminToken" "relaycontrolServiceToken" }}{{ if not (get $.Values.secretKeys $name) }}{{ fail (printf "secretKeys.%s is required" $name) }}{{ end }}{{ end -}}
{{- $origin := "^https?://[^/?#@[:space:]]+$" -}}
{{- $url := "^https?://[^/?#@[:space:]]+(/[^?#[:space:]]*)?$" -}}
{{- if not (regexMatch $url (toString .Values.config.relayfileBaseUrl)) }}{{ fail "config.relayfileBaseUrl (RELAYFILE_BASE_URL) is required and must be an http(s) URL without credentials, query or fragment" }}{{ end -}}
{{- if not (regexMatch $origin (toString .Values.config.relaycontrolBaseUrl)) }}{{ fail "config.relaycontrolBaseUrl (RELAYCONTROL_BASE_URL) is required and must be an http(s) origin with no path" }}{{ end -}}
{{- with .Values.config.publicOrigin }}{{ if not (regexMatch $origin (toString .)) }}{{ fail "config.publicOrigin (RELAYFILE_CONTROL_PUBLIC_ORIGIN) must be an http(s) origin with no path" }}{{ end }}{{ end -}}
{{- if not (kindIs "bool" .Values.flows.enabled) }}{{ fail "flows.enabled must be a boolean" }}{{ end -}}
{{- if ne (toString .Values.flows.storage) "postgres" }}{{ fail "flows.storage must be postgres" }}{{ end -}}
{{- if .Values.flows.enabled }}
{{- if not .Values.config.publicOrigin }}{{ fail "flows.enabled=true requires config.publicOrigin (RELAYFILE_CONTROL_PUBLIC_ORIGIN)" }}{{ end -}}
{{- if not .Values.flows.encryptionKeyId }}{{ fail "flows.enabled=true requires flows.encryptionKeyId (RELAYFILE_CONTROL_ENCRYPTION_KEY_ID)" }}{{ end -}}
{{- if not (or .Values.flows.workerRelaycastUrl .Values.flows.relaycastPublicUrl) }}{{ fail "flows.enabled=true requires flows.workerRelaycastUrl or flows.relaycastPublicUrl" }}{{ end -}}
{{- range $name := list "introspectSecret" "brokerSecret" "encryptionKey" }}{{ if not (get $.Values.secretKeys $name) }}{{ fail (printf "flows.enabled=true requires secretKeys.%s" $name) }}{{ end }}{{ end -}}
{{- $previousId := .Values.flows.previousEncryptionKeyId -}}
{{- $previousKey := .Values.secretKeys.previousEncryptionKey -}}
{{- if or (and $previousId (not $previousKey)) (and $previousKey (not $previousId)) }}{{ fail "flows.previousEncryptionKeyId and secretKeys.previousEncryptionKey must be set together" }}{{ end -}}
{{- $seen := dict -}}
{{- range $name := list "introspectSecret" "brokerSecret" "telemetrySecret" "runtimeVerifySecret" }}
{{- $key := get $.Values.secretKeys $name | toString -}}
{{- if $key }}{{ if hasKey $seen $key }}{{ fail (printf "secretKeys.%s and secretKeys.%s name the same Secret key; these secrets must differ or the server refuses to start" (get $seen $key) $name) }}{{ end }}{{ $_ := set $seen $key $name }}{{ end -}}
{{- end -}}
{{- range $name, $value := dict "workerRelaycastUrl" .Values.flows.workerRelaycastUrl "relaycastPublicUrl" .Values.flows.relaycastPublicUrl "workerRelayfileUrl" .Values.flows.workerRelayfileUrl "dashboardUrl" .Values.flows.dashboardUrl "publicBaseUrl" .Values.flows.publicBaseUrl }}
{{- if and $value (not (regexMatch $url (toString $value))) }}{{ fail (printf "flows.%s must be an http(s) URL without credentials, query or fragment" $name) }}{{ end -}}
{{- end -}}
{{- end -}}
{{- $serverPort := .Values.server.port -}}
{{- if not (and (or (kindIs "int" $serverPort) (kindIs "int64" $serverPort) (kindIs "float64" $serverPort)) (ge (float64 $serverPort) 1.0) (le (float64 $serverPort) 65535.0) (eq (float64 $serverPort) (float64 (int64 $serverPort)))) }}{{ fail "server.port must be a port number" }}{{ end -}}
{{- if eq (int64 $serverPort) 3101 }}{{ fail "server.port must not be 3101: the admin listener binds it on loopback" }}{{ end -}}
{{- if and .Values.networkPolicy.enabled (not .Values.networkPolicy.allowAllEgress) (empty .Values.networkPolicy.additionalEgress) }}{{ fail "networkPolicy.enabled with allowAllEgress=false requires networkPolicy.additionalEgress: restricted egress allows only same-namespace pods and DNS, which blocks the external PostgreSQL database" }}{{ end -}}
{{- range .Values.networkPolicy.additionalEgress }}{{ if empty .to }}{{ fail "every networkPolicy.additionalEgress rule needs a non-empty to (an empty to matches every destination; use ipBlock 0.0.0.0/0 to allow any destination explicitly)" }}{{ end }}{{ end -}}
{{- range $key, $_ := include "relayfile-control.selectorLabels" . | fromYaml }}{{ if hasKey ($.Values.podLabels | default dict) $key }}{{ fail (printf "podLabels must not set selector label %s: the Deployment selector would no longer match its pods" $key) }}{{ end }}{{ end -}}
{{- if ne .Values.service.type "ClusterIP" }}{{ fail "service.type must be ClusterIP" }}{{ end -}}
{{- if .Values.ingress.enabled }}
{{- if not .Values.flows.enabled }}{{ fail "ingress.enabled=true requires flows.enabled=true: the Ingress only routes Flows paths" }}{{ end -}}
{{- if empty .Values.ingress.hosts }}{{ fail "ingress.enabled=true requires at least one host" }}{{ end -}}
{{- if and (not .Values.ingress.externalTls) (empty .Values.ingress.tls) }}{{ fail "ingress.enabled=true requires ingress.tls unless externalTls=true" }}{{ end -}}
{{- if and .Values.networkPolicy.enabled (empty .Values.networkPolicy.ingressFrom) }}{{ fail "ingress with networkPolicy requires networkPolicy.ingressFrom" }}{{ end -}}
{{- end -}}
{{- $reservedEnv := list "LISTEN" "ADMIN_LISTEN" "MIGRATE_ON_START" "RELAYFILE_BASE_URL" "RELAYCONTROL_BASE_URL" "RELAYFILE_CONTROL_PUBLIC_ORIGIN" "FLOWS_ENABLED" "SELFHOST_FLOWS_STORAGE" "RELAYFILE_CONTROL_ENCRYPTION_KEY_ID" "RELAYFILE_CONTROL_ENCRYPTION_PREVIOUS_KEY_ID" "SELFHOST_FLOWS_WORKER_RELAYCAST_URL" "RELAYCAST_PUBLIC_URL" "SELFHOST_FLOWS_WORKER_RELAYFILE_URL" "SELFHOST_DASHBOARD_URL" "FLOWS_PUBLIC_BASE_URL" -}}
{{- $pairs := include "relayfile-control.secretPairs" . | fromJson -}}
{{- range $pair := concat $pairs.core $pairs.flows $pairs.flowsOptional $pairs.webhooks }}{{ $reservedEnv = concat $reservedEnv (list (index $pair 0) (printf "%s_FILE" (index $pair 0))) }}{{ end -}}
{{- if (.Values.postgresCa | default dict).enabled }}{{ $reservedEnv = append $reservedEnv "NODE_EXTRA_CA_CERTS" }}{{ end -}}
{{- range .Values.extraEnv }}{{ if has .name $reservedEnv }}{{ fail (printf "%s is managed by structured chart values and must not appear in extraEnv" .name) }}{{ end }}{{ end -}}
{{- include "relayfile-control.validatePostgresCa" . -}}
{{- end -}}

{{- /* Optional Postgres server CA bundle (postgresCa.*). NODE_EXTRA_CA_CERTS adds the
mounted PEM to the roots node-pg verifies against for sslmode=verify-full. */ -}}
{{- define "relayfile-control.postgresCaVolume" -}}
{{- $ca := .Values.postgresCa -}}
- name: postgres-ca
{{- if $ca.configMap }}
  configMap:
    name: {{ $ca.configMap | quote }}
    items: [{ key: {{ $ca.key | quote }}, path: ca.crt }]
{{- else }}
  secret:
    secretName: {{ $ca.secret | quote }}
    # Public certificates, readable whatever the Pod's fsGroup is.
    defaultMode: 0444
    items: [{ key: {{ $ca.key | quote }}, path: ca.crt }]
{{- end }}
{{- end -}}

{{- /* Fail closed on a half-configured bundle: a name without enabled=true would
leave the certificate unverified while looking configured. */ -}}
{{- define "relayfile-control.validatePostgresCa" -}}
{{- $ca := .Values.postgresCa | default dict -}}
{{- $enabled := dig "enabled" false $ca -}}
{{- if not (kindIs "bool" $enabled) }}{{ fail "postgresCa.enabled must be a boolean" }}{{ end -}}
{{- $configMap := get $ca "configMap" | default "" | toString -}}
{{- $secret := get $ca "secret" | default "" | toString -}}
{{- if not $enabled -}}
{{- if or $configMap $secret }}{{ fail "postgresCa.configMap and postgresCa.secret require postgresCa.enabled=true; a CA name while disabled would leave the certificate unverified" }}{{ end -}}
{{- else -}}
{{- if eq (empty $configMap) (empty $secret) }}{{ fail "postgresCa.enabled=true requires exactly one of postgresCa.configMap or postgresCa.secret" }}{{ end -}}
{{- $ref := default $secret $configMap -}}
{{- if or (gt (len $ref) 253) (not (regexMatch "^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?(\\.[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?)*$" $ref)) }}{{ fail "postgresCa.configMap and postgresCa.secret must be a Kubernetes object name" }}{{ end -}}
{{- if not (regexMatch "^[A-Za-z0-9._-]+$" (get $ca "key" | default "" | toString)) }}{{ fail "postgresCa.key must be a Kubernetes data key" }}{{ end -}}
{{- end -}}
{{- end -}}
