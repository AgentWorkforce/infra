{{- define "sessions-pipeline-worker.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "sessions-pipeline-worker.fullname" -}}
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

{{/*
Join name parts and fit them in 63 chars. When too long, keep a prefix and
append a hash of the full name so two long release names never collide.
Usage: include "sessions-pipeline-worker.fit" "<name>"
*/}}
{{- define "sessions-pipeline-worker.fit" -}}
{{- if le (len .) 63 }}{{ . }}{{ else }}{{ printf "%s-%s" (trunc 54 . | trimSuffix "-") (sha256sum . | trunc 8) }}{{ end -}}
{{- end }}

{{/*
Component object name. Usage: include "sessions-pipeline-worker.componentName" (dict "context" . "component" "referee")
*/}}
{{- define "sessions-pipeline-worker.componentName" -}}
{{- if and (not .context.Values.legacyResourceNames) (hasKey (dict "bob-costas" "" "hoopdb-indexer" "" "referee" "" "session-brief" "") .component) -}}
{{- $override := dig .component "fullnameOverride" "" .context.Values.components -}}
{{- if $override -}}
{{- include "sessions-pipeline-worker.fit" $override -}}
{{- else -}}
{{- include "sessions-pipeline-worker.fit" (printf "%s-%s" (include "sessions-pipeline-worker.fullname" .context) (include "sessions-pipeline-worker.publicComponent" .)) -}}
{{- end -}}
{{- else -}}
{{- include "sessions-pipeline-worker.fit" (printf "%s-%s" (include "sessions-pipeline-worker.fullname" .context) .component) }}
{{- end -}}
{{- end }}

{{/* Engine SERVICE keys remain internal; public workload names are descriptive. */}}
{{- define "sessions-pipeline-worker.publicComponent" -}}
{{- if .context.Values.legacyResourceNames -}}
{{- .component -}}
{{- else -}}
{{- get (dict "bob-costas" "session-summary-worker" "hoopdb-indexer" "session-metadata-indexer" "referee" "session-status-worker") .component | default .component -}}
{{- end -}}
{{- end }}

{{- define "sessions-pipeline-worker.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "sessions-pipeline-worker.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Content-addressed Job name: <fullname>-<job>-<sha8 of the rendered Job spec>.
Hashing the spec itself means ANY change to the pod template (image, env,
secret names, security context, ...) yields a new Job: Job pod templates are
immutable and server-side apply cannot patch them.
Usage: include "sessions-pipeline-worker.jobName" (dict "context" . "job" "migrate" "spec" $spec)
*/}}
{{- define "sessions-pipeline-worker.jobName" -}}
{{- $base := include "sessions-pipeline-worker.fit" (printf "%s-%s" (include "sessions-pipeline-worker.fullname" .context) .job) | trunc 54 | trimSuffix "-" }}
{{- printf "%s-%s" $base (sha256sum .spec | trunc 8) }}
{{- end }}
