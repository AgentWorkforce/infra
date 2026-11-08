{{/* Expand the chart name. */}}
{{- define "relay-chief.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* Create a DNS-safe fully qualified name, short enough for CronJob names. */}}
{{- define "relay-chief.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 52 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 52 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 52 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/* Immutable selector labels. */}}
{{- define "relay-chief.selectorLabels" -}}
app.kubernetes.io/name: {{ include "relay-chief.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/* Common labels. */}}
{{- define "relay-chief.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{ include "relay-chief.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/* The claim holding chief.db. */}}
{{- define "relay-chief.claimName" -}}
{{- default (include "relay-chief.fullname" .) .Values.persistence.existingClaim }}
{{- end }}

{{/* Fail closed on every value the runtime cannot safely default. */}}
{{- define "relay-chief.validate" -}}
{{- if not (regexMatch "^sha256:[a-f0-9]{64}$" (toString .Values.image.digest)) -}}
{{- fail "image.digest is required and must be sha256:<64 hex>: Relay Chief is deployed by immutable digest only" -}}
{{- end -}}
{{- if not (regexMatch "^https://[^/?#@[:space:]]+/?$" (toString .Values.relay.baseUrl)) -}}
{{- fail "relay.baseUrl is required and must be a bare https origin: the runtime refuses anything else, and unset it would use the hosted Relay" -}}
{{- end -}}
{{- if not (regexMatch "^https://[^/?#@[:space:]]+/?$" (toString .Values.controlPlane.url)) -}}
{{- fail "controlPlane.url is required and must be a bare https origin: the runtime refuses anything else" -}}
{{- end -}}
{{- if not .Values.existingSecret -}}
{{- fail "existingSecret is required: it holds the Relay Chief runtime credentials" -}}
{{- end -}}
{{- $secretKeys := .Values.secretKeys | default dict -}}
{{- range $name := list "relayAgentToken" "typesafeApiKey" "controlPlaneToken" -}}
{{- if not (regexMatch "^[A-Za-z0-9._-]+$" (toString (get $secretKeys $name))) -}}
{{- fail (printf "secretKeys.%s must be a Kubernetes Secret data key" $name) -}}
{{- end -}}
{{- end -}}
{{- if or (not (kindIs "map" .Values.config)) (empty .Values.config) -}}
{{- fail "config is required: supply the Relay Chief configuration (identifiers only, no secrets)" -}}
{{- end -}}
{{- $configKeys := list "revision" "chiefId" "organizationId" "workspaceId" "projectId" "relayCallerId" "repositories" "workers" "policy" -}}
{{- range $key := $configKeys -}}
{{- if kindIs "invalid" (index $.Values.config $key) -}}
{{- fail (printf "config.%s is required by the Relay Chief configuration schema" $key) -}}
{{- end -}}
{{- end -}}
{{- range $key, $_ := .Values.config -}}
{{- if not (has $key $configKeys) -}}
{{- fail (printf "config.%s is not a Relay Chief configuration key: the runtime refuses unknown keys" $key) -}}
{{- end -}}
{{- end -}}
{{- if not (kindIs "bool" .Values.suspend) -}}
{{- fail "suspend must be true or false: Kubernetes treats a blank value as false, which would start dispatching" -}}
{{- end -}}
{{- if not (regexMatch "^\\S+(\\s+\\S+){4}$" (toString .Values.schedule)) -}}
{{- fail "schedule must have 5 whitespace-separated cron fields" -}}
{{- end -}}
{{- if lt (int .Values.startingDeadlineSeconds) 10 -}}
{{- fail "startingDeadlineSeconds must be at least 10" -}}
{{- end -}}
{{- if le (int .Values.activeDeadlineSeconds) 0 -}}
{{- fail "activeDeadlineSeconds must be positive" -}}
{{- end -}}
{{- end }}
