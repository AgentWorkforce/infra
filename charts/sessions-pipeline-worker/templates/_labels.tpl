{{- define "sessions-pipeline-worker.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "sessions-pipeline-worker.selectorLabels" -}}
app.kubernetes.io/name: {{ include "sessions-pipeline-worker.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "sessions-pipeline-worker.labels" -}}
helm.sh/chart: {{ include "sessions-pipeline-worker.chart" . }}
{{ include "sessions-pipeline-worker.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: sessions-pipeline
{{- end }}

{{/*
Usage: include "sessions-pipeline-worker.componentLabels" (dict "context" . "component" "referee")
*/}}
{{- define "sessions-pipeline-worker.componentLabels" -}}
{{ include "sessions-pipeline-worker.labels" .context }}
app.kubernetes.io/component: {{ include "sessions-pipeline-worker.publicComponent" . }}
{{- end }}

{{- define "sessions-pipeline-worker.componentSelectorLabels" -}}
{{ include "sessions-pipeline-worker.selectorLabels" .context }}
app.kubernetes.io/component: {{ include "sessions-pipeline-worker.publicComponent" . }}
{{- end }}
