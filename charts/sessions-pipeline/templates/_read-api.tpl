{{- define "sessions-pipeline.readApi.validateLogin" -}}
{{- if not (kindIs "bool" .Values.readApi.loginAdvertisesSync) }}{{ fail "readApi.loginAdvertisesSync must be a boolean" }}{{ end -}}
{{- end -}}
