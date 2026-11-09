{{- define "relayauth.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "relayauth.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "relayauth.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "relayauth.labels" -}}
helm.sh/chart: {{ include "relayauth.chart" . }}
{{ include "relayauth.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "relayauth.selectorLabels" -}}
app.kubernetes.io/name: {{ include "relayauth.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "relayauth.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "relayauth.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "relayauth.claimName" -}}
{{- default (printf "%s-data" (include "relayauth.fullname" .)) .Values.persistence.existingClaim }}
{{- end }}

{{- define "relayauth.baseUrl" -}}
{{- if .Values.baseUrl }}
{{- .Values.baseUrl | trimSuffix "/" }}
{{- else }}
{{- printf "http://%s.%s.svc:%v" (include "relayauth.fullname" .) .Release.Namespace .Values.server.port }}
{{- end }}
{{- end }}

{{- define "relayauth.issuer" -}}
{{- default (include "relayauth.baseUrl" .) .Values.issuer | trimSuffix "/" }}
{{- end }}

{{- define "relayauth.image" -}}
{{- $digest := required "image.digest is required; RelayAuth images must be pinned by sha256 digest" .Values.image.digest }}
{{- if not (regexMatch "^sha256:[a-f0-9]{64}$" $digest) }}
{{- fail "image.digest must be sha256:<64 lowercase hex characters>" }}
{{- end }}
{{- printf "%s@%s" .Values.image.repository $digest }}
{{- end }}

{{- define "relayauth.validate" -}}
{{- if not (kindIs "map" .Values.deployment) }}{{ fail "deployment must be an object with boolean deployment.enabled" }}{{ end -}}
{{- if not (kindIs "bool" .Values.deployment.enabled) }}{{ fail "deployment.enabled must be a boolean" }}{{ end -}}
{{- if ne (int .Values.replicaCount) 1 }}
{{- fail "replicaCount must be 1: RelayAuth stores state in a single SQLite file" }}
{{- end }}
{{- if not .Values.existingSecret }}
{{- fail "existingSecret is required; this chart never renders secret or signing-key material" }}
{{- end }}
{{- if not .Values.secretKeys.internalSecret }}
{{- fail "secretKeys.internalSecret is required" }}
{{- end }}
{{- if not .Values.secretKeys.signingKey }}
{{- fail "secretKeys.signingKey is required" }}
{{- end }}
{{- range $name, $key := .Values.secretKeys }}
{{- if and $key (not (regexMatch "^[A-Za-z0-9._-]+$" $key)) }}
{{- fail (printf "secretKeys.%s must be a Kubernetes Secret data key" $name) }}
{{- end }}
{{- end }}
{{- if and .Values.secretKeys.relaycastCredentialKeyring (not .Values.secretKeys.relaycastInternalSecret) }}
{{- fail "secretKeys.relaycastInternalSecret is required when secretKeys.relaycastCredentialKeyring is set: RelayAuth authenticates to Relaycast's internal API to push ar_ws_ keys" }}
{{- end }}
{{- if and .Values.secretKeys.relaycastInternalSecret (not .Values.secretKeys.relaycastCredentialKeyring) }}
{{- fail "secretKeys.relaycastInternalSecret requires secretKeys.relaycastCredentialKeyring: the ar_ keyring is what RelayAuth pushes" }}
{{- end }}
{{- if and .Values.secretKeys.relaycastServiceApiKey (not .Values.secretKeys.relaycastCredentialKeyring) }}
{{- fail "secretKeys.relaycastServiceApiKey requires secretKeys.relaycastCredentialKeyring" }}
{{- end }}
{{- if and .Values.secretKeys.relaycastCredentialKeyring (not (dig "url" "" (.Values.relaycast | default dict))) }}
{{- fail "relaycast.url is required when secretKeys.relaycastCredentialKeyring is set" }}
{{- end }}
{{- if ne (int .Values.service.port) (int .Values.server.port) }}
{{- fail "service.port must equal server.port: RelayAuth discovery derives its reachable Service URL from server.port" }}
{{- end }}
{{- if and .Values.jwksIngress.enabled (not .Values.jwksIngress.hosts) }}
{{- fail "jwksIngress.enabled=true requires at least one host" }}
{{- end }}
{{- if and .Values.jwksIngress.enabled (not .Values.baseUrl) }}
{{- fail "jwksIngress.enabled=true requires an explicit externally reachable baseUrl" }}
{{- end }}
{{- if and .Values.jwksIngress.enabled .Values.networkPolicy.enabled (not .Values.networkPolicy.ingressFrom) }}
{{- fail "jwksIngress with networkPolicy requires networkPolicy.ingressFrom to allow the ingress controller explicitly" }}
{{- end }}
{{- end }}
