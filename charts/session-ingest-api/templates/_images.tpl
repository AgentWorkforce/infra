{{/*
Full image reference. A digest wins over the tag; the tag defaults to
.Chart.AppVersion. global.imageRegistry is prefixed only to relative repositories.
*/}}
{{- define "alleyoop.image" -}}
{{- $repo := .Values.image.repository -}}
{{- /* A repository whose first segment looks like a host (has "." or ":",
or is "localhost") is already fully qualified: never prefix it. */ -}}
{{- $first := first (splitList "/" $repo) -}}
{{- $qualified := and (gt (len (splitList "/" $repo)) 1) (or (contains "." $first) (contains ":" $first) (eq "localhost" $first)) -}}
{{- if and .Values.global.imageRegistry (not $qualified) }}{{ $repo = printf "%s/%s" (trimSuffix "/" .Values.global.imageRegistry) $repo }}{{ end -}}
{{- if .Values.image.digest -}}
{{- printf "%s@%s" $repo .Values.image.digest -}}
{{- else -}}
{{- printf "%s:%s" $repo (.Values.image.tag | default .Chart.AppVersion) -}}
{{- end -}}
{{- end }}

{{- define "alleyoop.pullSecrets" -}}
{{- with .Values.imagePullSecrets }}
imagePullSecrets:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end }}
