{{- define "relaychief-control.name" -}}{{ default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}{{- end -}}
{{- define "relaychief-control.fullname" -}}{{ if .Values.fullnameOverride }}{{ .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}{{ else }}{{ printf "%s-%s" .Release.Name (include "relaychief-control.name" .) | trunc 63 | trimSuffix "-" }}{{ end }}{{- end -}}
{{- define "relaychief-control.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{ include "relaychief-control.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}
{{- /* Job metadata labels: the runtime component label is replaced by
migration so `kubectl wait job -l app.kubernetes.io/component=migration`
(NOTES.txt) finds the Job. */ -}}
{{- define "relaychief-control.migrationLabels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
app.kubernetes.io/name: {{ include "relaychief-control.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: migration
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}
{{- define "relaychief-control.selectorLabels" -}}
app.kubernetes.io/name: {{ include "relaychief-control.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: server
{{- end -}}
{{- define "relaychief-control.serviceAccountName" -}}{{ if .Values.serviceAccount.create }}{{ default (include "relaychief-control.fullname" .) .Values.serviceAccount.name }}{{ else }}{{ default "default" .Values.serviceAccount.name }}{{ end }}{{- end -}}
{{- define "relaychief-control.image" -}}
{{- $digest := required "image.digest is required; relaychief-control images must be pinned by sha256 digest" .Values.image.digest -}}
{{- if not (regexMatch "^sha256:[a-f0-9]{64}$" $digest) }}{{ fail "image.digest must be sha256:<64 lowercase hex characters>" }}{{ end -}}
{{- printf "%s@%s" .Values.image.repository $digest -}}
{{- end -}}
{{- define "relaychief-control.validate" -}}
{{- $image := include "relaychief-control.image" . -}}
{{- $replicas := .Values.replicaCount -}}
{{- if not (and (or (kindIs "int" $replicas) (kindIs "int64" $replicas) (kindIs "float64" $replicas)) (eq (float64 $replicas) 1.0)) }}{{ fail "replicaCount must be 1: the chart runs one replica and makes no HA claim" }}{{ end -}}
{{- if not .Values.existingSecret }}{{ fail "existingSecret is required; the chart never creates Secrets" }}{{ end -}}
{{- range $name, $key := .Values.secretKeys }}{{ if and $key (not (regexMatch "^[A-Za-z0-9._-]+$" (toString $key))) }}{{ fail (printf "secretKeys.%s must be a Kubernetes Secret data key" $name) }}{{ end }}{{ end -}}
{{- range $name := list "databaseUrl" "introspectSecret" "adminToken" }}{{ if not (get $.Values.secretKeys $name) }}{{ fail (printf "secretKeys.%s is required" $name) }}{{ end }}{{ end -}}
{{- $relayIdentity := list "relaySecret" "encryptionKeyId" "encryptionKey" -}}
{{- $relayIdentitySet := 0 -}}
{{- range $relayIdentity }}{{ if get $.Values.secretKeys . }}{{ $relayIdentitySet = add1 $relayIdentitySet }}{{ end }}{{ end -}}
{{- if and (gt $relayIdentitySet 0) (lt $relayIdentitySet (len $relayIdentity)) }}{{ fail "secretKeys.relaySecret, secretKeys.encryptionKeyId and secretKeys.encryptionKey must be set together or not at all: the server refuses to start with only some of RELAYCHIEF_CONTROL_RELAY_SECRET, RELAYCHIEF_CONTROL_ENCRYPTION_KEY_ID and RELAYCHIEF_CONTROL_ENCRYPTION_KEY" }}{{ end -}}
{{- $origin := "^https?://[^/?#@[:space:]]+$" -}}
{{- if not (regexMatch $origin (toString .Values.config.relaycontrolUrl)) }}{{ fail "config.relaycontrolUrl (RELAYCONTROL_URL) is required and must be an http(s) origin with no path" }}{{ end -}}
{{- if not (regexMatch $origin (toString .Values.config.publicOrigin)) }}{{ fail "config.publicOrigin (RELAYCHIEF_CONTROL_PUBLIC_ORIGIN) is required and must be an http(s) origin with no path" }}{{ end -}}
{{- range splitList "," (toString .Values.config.browserOrigins) }}{{ $entry := trim . }}{{ if and $entry (not (regexMatch $origin $entry)) }}{{ fail (printf "config.browserOrigins must be comma-separated http(s) origins with no path; got %q" $entry) }}{{ end }}{{ end -}}
{{- if .Values.config.nangoHost }}
{{- if not (regexMatch $origin (toString .Values.config.nangoHost)) }}{{ fail "config.nangoHost (NANGO_HOST) must be an http(s) origin with no path" }}{{ end -}}
{{- if not .Values.secretKeys.nangoSecretKey }}{{ fail "config.nangoHost (NANGO_HOST) requires secretKeys.nangoSecretKey: the server refuses to start with NANGO_HOST and no NANGO_SECRET_KEY" }}{{ end -}}
{{- end -}}
{{- $serverPort := .Values.server.port -}}
{{- if not (and (or (kindIs "int" $serverPort) (kindIs "int64" $serverPort) (kindIs "float64" $serverPort)) (ge (float64 $serverPort) 1.0) (le (float64 $serverPort) 65535.0) (eq (float64 $serverPort) (float64 (int64 $serverPort)))) }}{{ fail "server.port must be a port number" }}{{ end -}}
{{- if eq (int64 $serverPort) 3201 }}{{ fail "server.port must not be 3201: the admin listener binds it on loopback" }}{{ end -}}
{{- if and .Values.networkPolicy.enabled (not .Values.networkPolicy.allowAllEgress) (empty .Values.networkPolicy.additionalEgress) }}{{ fail "networkPolicy.enabled with allowAllEgress=false requires networkPolicy.additionalEgress: restricted egress allows only same-namespace pods and DNS, which blocks the external PostgreSQL database" }}{{ end -}}
{{- range .Values.networkPolicy.additionalEgress }}{{ if empty .to }}{{ fail "every networkPolicy.additionalEgress rule needs a non-empty to (an empty to matches every destination; use ipBlock 0.0.0.0/0 to allow any destination explicitly)" }}{{ end }}{{ end -}}
{{- range $key, $_ := include "relaychief-control.selectorLabels" . | fromYaml }}{{ if hasKey ($.Values.podLabels | default dict) $key }}{{ fail (printf "podLabels must not set selector label %s: the Deployment selector would no longer match its pods" $key) }}{{ end }}{{ end -}}
{{- if ne .Values.service.type "ClusterIP" }}{{ fail "service.type must be ClusterIP" }}{{ end -}}
{{- if .Values.ingress.enabled }}{{ if empty .Values.ingress.hosts }}{{ fail "ingress.enabled=true requires at least one host" }}{{ end }}{{ if and (not .Values.ingress.externalTls) (empty .Values.ingress.tls) }}{{ fail "ingress.enabled=true requires ingress.tls unless externalTls=true" }}{{ end }}{{ if and .Values.networkPolicy.enabled (empty .Values.networkPolicy.ingressFrom) }}{{ fail "ingress with networkPolicy requires networkPolicy.ingressFrom" }}{{ end }}{{ end -}}
{{- range .Values.ingress.extraPaths }}
{{- if not (regexMatch "^/[^*?#[:space:]]+$" (toString .path)) }}{{ fail (printf "ingress.extraPaths: path %q must be an absolute path other than /: a root rule would expose every route" (toString .path)) }}{{ end -}}
{{- if not (has (default "Prefix" .pathType) (list "Prefix" "Exact")) }}{{ fail "ingress.extraPaths: pathType must be Prefix or Exact" }}{{ end -}}
{{- end -}}
{{- $reservedEnv := list "PORT" "HOST" "ADMIN_HOST" "ADMIN_PORT" "RELAYCONTROL_URL" "RELAYCHIEF_CONTROL_PUBLIC_ORIGIN" "RELAYCHIEF_CONTROL_BROWSER_ORIGINS" "NANGO_HOST" "DATABASE_URL" "RELAYCONTROL_INTROSPECT_SECRET" "RELAYCHIEF_CONTROL_ADMIN_TOKEN" "NANGO_SECRET_KEY" "RELAYCHIEF_CONTROL_RELAY_SECRET" "RELAYCHIEF_CONTROL_ENCRYPTION_KEY_ID" "RELAYCHIEF_CONTROL_ENCRYPTION_KEY" -}}
{{- if (.Values.postgresCa | default dict).enabled }}{{ $reservedEnv = append $reservedEnv "NODE_EXTRA_CA_CERTS" }}{{ end -}}
{{- range .Values.extraEnv }}{{ if has .name $reservedEnv }}{{ fail (printf "%s is managed by structured chart values and must not appear in extraEnv" .name) }}{{ end }}{{ end -}}
{{- include "relaychief-control.validatePostgresCa" . -}}
{{- end -}}
{{- define "relaychief-control.secretEnvVar" -}}
- name: {{ .name }}
  valueFrom:
    secretKeyRef:
      name: {{ .secret }}
      key: {{ .key | quote }}
{{- end -}}
{{- define "relaychief-control.secretEnv" -}}
{{- include "relaychief-control.secretEnvVar" (dict "name" "DATABASE_URL" "secret" .Values.existingSecret "key" .Values.secretKeys.databaseUrl) }}
{{ include "relaychief-control.secretEnvVar" (dict "name" "RELAYCONTROL_INTROSPECT_SECRET" "secret" .Values.existingSecret "key" .Values.secretKeys.introspectSecret) }}
{{ include "relaychief-control.secretEnvVar" (dict "name" "RELAYCHIEF_CONTROL_ADMIN_TOKEN" "secret" .Values.existingSecret "key" .Values.secretKeys.adminToken) }}
{{- with .Values.secretKeys.nangoSecretKey }}
{{ include "relaychief-control.secretEnvVar" (dict "name" "NANGO_SECRET_KEY" "secret" $.Values.existingSecret "key" .) }}
{{- end }}
{{- if .Values.secretKeys.relaySecret }}
{{ include "relaychief-control.secretEnvVar" (dict "name" "RELAYCHIEF_CONTROL_RELAY_SECRET" "secret" .Values.existingSecret "key" .Values.secretKeys.relaySecret) }}
{{ include "relaychief-control.secretEnvVar" (dict "name" "RELAYCHIEF_CONTROL_ENCRYPTION_KEY_ID" "secret" .Values.existingSecret "key" .Values.secretKeys.encryptionKeyId) }}
{{ include "relaychief-control.secretEnvVar" (dict "name" "RELAYCHIEF_CONTROL_ENCRYPTION_KEY" "secret" .Values.existingSecret "key" .Values.secretKeys.encryptionKey) }}
{{- end }}
{{- end -}}
{{- define "relaychief-control.migrationPodTemplate" -}}
metadata:
  labels:
    app.kubernetes.io/name: {{ include "relaychief-control.name" . }}
    app.kubernetes.io/instance: {{ .Release.Name }}
    app.kubernetes.io/component: migration
spec:
  restartPolicy: Never
  serviceAccountName: {{ include "relaychief-control.serviceAccountName" . }}
  automountServiceAccountToken: false
  securityContext: {{ toYaml .Values.podSecurityContext | nindent 4 }}
  {{- with .Values.imagePullSecrets }}
  imagePullSecrets: {{ toYaml . | nindent 4 }}
  {{- end }}
  {{- /* Same node placement as the server, so the Job can schedule wherever the
  Deployment can. topologySpreadConstraints select the server's labels, so they
  do not apply here. */}}
  {{- with .Values.nodeSelector }}
  nodeSelector: {{ toYaml . | nindent 4 }}
  {{- end }}
  {{- with .Values.affinity }}
  affinity: {{ toYaml . | nindent 4 }}
  {{- end }}
  {{- with .Values.tolerations }}
  tolerations: {{ toYaml . | nindent 4 }}
  {{- end }}
  containers:
    - name: migrate
      image: {{ include "relaychief-control.image" . | quote }}
      imagePullPolicy: {{ .Values.image.pullPolicy }}
      command: [node]
      args: [node_modules/relaychief-control/dist/migrate-cli.js]
      securityContext: {{ toYaml .Values.containerSecurityContext | nindent 8 }}
      env:
        {{- include "relaychief-control.secretEnvVar" (dict "name" "DATABASE_URL" "secret" .Values.existingSecret "key" .Values.secretKeys.databaseUrl) | nindent 8 }}
        {{- if (.Values.postgresCa | default dict).enabled }}
        - { name: NODE_EXTRA_CA_CERTS, value: /etc/postgres-ca/ca.crt }
        {{- end }}
      resources: {{ toYaml .Values.resources | nindent 8 }}
      volumeMounts:
        - { name: tmp, mountPath: /tmp }
        {{- if (.Values.postgresCa | default dict).enabled }}
        - { name: postgres-ca, mountPath: /etc/postgres-ca, readOnly: true }
        {{- end }}
  volumes:
    - name: tmp
      emptyDir: { medium: Memory, sizeLimit: 64Mi }
    {{- if (.Values.postgresCa | default dict).enabled }}
    {{- include "relaychief-control.postgresCaVolume" . | nindent 4 }}
    {{- end }}
{{- end -}}

{{- /* Optional Postgres server CA bundle (postgresCa.*). NODE_EXTRA_CA_CERTS adds the
mounted PEM to the roots node-pg verifies against for sslmode=verify-full. */ -}}
{{- define "relaychief-control.postgresCaVolume" -}}
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
{{- define "relaychief-control.validatePostgresCa" -}}
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
