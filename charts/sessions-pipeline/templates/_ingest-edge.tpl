{{/* Bare destination origins only. HTTP requires explicit in-cluster Service DNS. */}}
{{- define "sessions-pipeline.ingestEdge.endpoint" -}}
{{- $url := required (printf "%s is required" .name) .url | trim -}}
{{- $https := "^https://([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z]([a-z0-9-]{0,61}[a-z0-9])?(:[0-9]{1,5})?$" -}}
{{- $http := "^http://[a-z0-9]([-a-z0-9]*[a-z0-9])?\\.[a-z0-9]([-a-z0-9]*[a-z0-9])?\\.svc(\\.cluster\\.local)?(:[0-9]{1,5})?$" -}}
{{- if not (or (regexMatch $https $url) (and .allowHttp (regexMatch $http $url))) -}}
{{- fail (printf "%s must be a bare HTTPS DNS origin, or an explicitly admitted HTTP Kubernetes Service origin" .name) -}}
{{- end -}}
{{- $port := regexFind ":[0-9]+$" $url -}}
{{- if and $port (or (lt (int (trimPrefix ":" $port)) 1) (gt (int (trimPrefix ":" $port)) 65535)) -}}
{{- fail (printf "%s has an invalid port" .name) -}}
{{- end -}}
{{- $url -}}
{{- end -}}
