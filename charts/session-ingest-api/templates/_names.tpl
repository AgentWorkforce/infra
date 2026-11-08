{{- define "alleyoop.name" -}}
{{- default (ternary "alleyoop" "session-ingest-api" .Values.legacyResourceNames) .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "alleyoop.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := include "alleyoop.name" . }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- end }}
{{- end }}

{{/*
Join name parts and fit them in 63 chars. When too long, keep a prefix and
append a hash of the full name so two long release names never collide.
Usage: include "alleyoop.fit" "<name>"
*/}}
{{- define "alleyoop.fit" -}}
{{- if le (len .) 63 }}{{ . }}{{ else }}{{ printf "%s-%s" (trunc 54 . | trimSuffix "-") (sha256sum . | trunc 8) }}{{ end -}}
{{- end }}

{{/*
Component object name. Usage: include "alleyoop.componentName" (dict "context" . "component" "referee")
*/}}
{{- define "alleyoop.componentName" -}}
{{- include "alleyoop.fit" (printf "%s-%s" (include "alleyoop.fullname" .context) .component) }}
{{- end }}

{{- define "alleyoop.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "alleyoop.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "alleyoop.deploymentName" -}}
{{- if .Values.legacyResourceNames -}}
{{- include "alleyoop.componentName" (dict "context" . "component" "ingest") -}}
{{- else -}}
{{- include "alleyoop.fullname" . -}}
{{- end -}}
{{- end }}
