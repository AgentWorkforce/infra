{{- define "alleyoop.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "alleyoop.selectorLabels" -}}
app.kubernetes.io/name: {{ include "alleyoop.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "alleyoop.labels" -}}
helm.sh/chart: {{ include "alleyoop.chart" . }}
{{ include "alleyoop.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: sessions-pipeline
{{- end }}

{{/*
Usage: include "alleyoop.componentLabels" (dict "context" . "component" "referee")
*/}}
{{- define "alleyoop.componentLabels" -}}
{{ include "alleyoop.labels" .context }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{- define "alleyoop.componentSelectorLabels" -}}
{{ include "alleyoop.selectorLabels" .context }}
app.kubernetes.io/component: {{ .component }}
{{- end }}
