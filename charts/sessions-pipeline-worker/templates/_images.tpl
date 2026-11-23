{{/*
Full image reference. A digest wins over the tag; the tag defaults to
.Chart.AppVersion. global.imageRegistry is prefixed only to relative repositories.
*/}}
{{- define "sessions-pipeline-worker.image" -}}
{{- include "sessions-pipeline-worker.imageRef" (dict "root" . "image" .Values.image) -}}
{{- end }}

{{- define "sessions-pipeline-worker.imageRef" -}}
{{- $root := .root -}}
{{- $image := .image -}}
{{- $repo := $image.repository -}}
{{- /* A repository whose first segment looks like a host (has "." or ":",
or is "localhost") is already fully qualified: never prefix it. */ -}}
{{- $first := first (splitList "/" $repo) -}}
{{- $qualified := and (gt (len (splitList "/" $repo)) 1) (or (contains "." $first) (contains ":" $first) (eq "localhost" $first)) -}}
{{- if and $root.Values.global.imageRegistry (not $qualified) }}{{ $repo = printf "%s/%s" (trimSuffix "/" $root.Values.global.imageRegistry) $repo }}{{ end -}}
{{- if $image.digest -}}
{{- printf "%s@%s" $repo $image.digest -}}
{{- else -}}
{{- printf "%s:%s" $repo ($image.tag | default $root.Chart.AppVersion) -}}
{{- end -}}
{{- end }}

{{- define "sessions-pipeline-worker.analysisImage" -}}
{{- $image := .Values.sessionAnalysis.image | default dict -}}
{{- if $image.repository -}}
{{- include "sessions-pipeline-worker.imageRef" (dict "root" . "image" $image) -}}
{{- else -}}
{{- include "sessions-pipeline-worker.image" . -}}
{{- end -}}
{{- end }}

{{- define "sessions-pipeline-worker.pullSecrets" -}}
{{- with .Values.imagePullSecrets }}
imagePullSecrets:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end }}
