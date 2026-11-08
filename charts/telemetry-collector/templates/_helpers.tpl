{{- define "telemetry-collector.name" -}}
{{- default "telemetry-collector" .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- define "telemetry-collector.fullname" -}}
{{- default (printf "%s-%s" .Release.Name (include "telemetry-collector.name" .)) .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- define "telemetry-collector.selectorLabels" -}}
app.kubernetes.io/name: {{ include "telemetry-collector.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
{{- define "telemetry-collector.labels" -}}
{{ include "telemetry-collector.selectorLabels" . }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}
{{- define "telemetry-collector.image" -}}
{{- if not (regexMatch "^sha256:[a-f0-9]{64}$" .digest) -}}
{{- fail "telemetry-collector: an immutable image sha256 digest is required" -}}
{{- end -}}
{{- printf "%s@%s" (required "telemetry-collector: image repository is required" .repository) .digest -}}
{{- end -}}
{{- define "telemetry-collector.validate" -}}
{{- range .Values.imagePullSecrets -}}
{{- if empty .name }}{{ fail "telemetry-collector: imagePullSecrets.name must be non-empty" }}{{ end -}}
{{- end -}}
{{- if ne (int .Values.replicaCount) 1 }}{{ fail "telemetry-collector: exactly one writer replica is required" }}{{ end -}}
{{- if not (regexMatch "^[a-f0-9]{40}$" .Values.image.sourceRevision) }}{{ fail "telemetry-collector: image.sourceRevision must record the exact 40-character source revision" }}{{ end -}}
{{- if ne .Values.image.sourceRevision "8359483d2666c1f374190c102237c3022ca3d466" }}{{ fail "telemetry-collector: declared source revision is not in the reviewed allowlist" }}{{ end -}}
{{- if empty .Values.producersSecret }}{{ fail "telemetry-collector: producersSecret is required" }}{{ end -}}
{{- if empty .Values.tlsSecret }}{{ fail "telemetry-collector: tlsSecret is required" }}{{ end -}}
{{- if eq .Values.tlsSecret .Values.producersSecret }}{{ fail "telemetry-collector: producer credentials and TLS keys require distinct Secrets" }}{{ end -}}
{{- if empty .Values.networkPolicy.allowedFrom }}{{ fail "telemetry-collector: networkPolicy.allowedFrom must identify authorized producer pods" }}{{ end -}}
{{- if gt (int64 .Values.limits.maxEventBytes) (int64 .Values.limits.maxBatchBytes) }}{{ fail "telemetry-collector: maxEventBytes must not exceed maxBatchBytes" }}{{ end -}}
{{- if gt (int64 .Values.limits.maxBatchBytes) (int64 .Values.limits.maxDiskBytes) }}{{ fail "telemetry-collector: maxBatchBytes must not exceed maxDiskBytes" }}{{ end -}}
{{- if lt (mul (int .Values.terminationGracePeriodSeconds) 1000) (add (int .Values.limits.shutdownDeadlineMs) 2000) }}{{ fail "telemetry-collector: termination grace must exceed the shutdown deadline by at least two seconds" }}{{ end -}}
{{- if and .Values.retention.maxAgeMs (ne .Values.retention.policy "delete-oldest-closed") }}{{ fail "telemetry-collector: retention.maxAgeMs requires delete-oldest-closed" }}{{ end -}}
{{- end -}}
