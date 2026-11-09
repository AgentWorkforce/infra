{{- define "actors.name" -}}
{{- printf "%s-durable-actors" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- /* Local patch 4: the pool manager name and label must fit 63 characters. */ -}}
{{- define "actors.poolManagerName" -}}
{{- printf "%s-pool-manager" (include "actors.name" . | trunc 50 | trimSuffix "-") -}}
{{- end -}}
{{- define "actors.sandboxNamespace" -}}
{{- default (printf "%s-%s" .Release.Namespace .Release.Name | trunc 63 | trimSuffix "-") .Values.sandboxNamespace -}}
{{- end -}}
{{- define "actors.image" -}}
{{- printf "%s@sha256:%s" .repository (required "image digest is required for source builds; published charts include all image digests" .digest) -}}
{{- end -}}
{{- define "actors.validate" -}}
{{- if eq (include "actors.sandboxNamespace" .) .Release.Namespace }}{{ fail "sandbox namespace must differ from the control-plane namespace" }}{{ end -}}
{{- if and (gt (int .Values.replicaCount) 1) (not .Values.redis.urlSecretKey) }}{{ fail "replicaCount above 1 requires redis.urlSecretKey" }}{{ end -}}
{{- if eq .Values.analytics.backend "clickhouse" -}}
{{- range $key, $value := .Values.analytics.clickhouse -}}
{{- if empty $value }}{{ fail (printf "analytics.clickhouse.%s is required" $key) }}{{ end -}}
{{- end -}}
{{- end -}}
{{- /* Local patch 10: S3 storage. */ -}}
{{- if eq .Values.storage.provider "s3" -}}
{{- if empty .Values.storage.s3.region }}{{ fail "storage.provider=s3 requires storage.s3.region" }}{{ end -}}
{{- if eq .Values.storage.s3.actorCredentials "control-plane" -}}
{{- if .Values.storage.s3.actorRoleArn }}{{ fail "storage.s3.actorRoleArn applies only to storage.s3.actorCredentials=assume-role" }}{{ end -}}
{{- else if empty .Values.storage.s3.actorRoleArn }}{{ fail "storage.s3.actorCredentials=assume-role requires storage.s3.actorRoleArn" }}{{ end -}}
{{- if eq .Values.storage.mode "rapid" }}{{ fail "Rapid persistence requires storage.provider=gcs" }}{{ end -}}
{{- end -}}
{{- if .Values.ingress.enabled -}}
{{- if or (empty .Values.ingress.className) (empty .Values.ingress.tlsSecret) }}{{ fail "ingress requires className and tlsSecret" }}{{ end -}}
{{- end -}}
{{- if eq .Values.storage.mode "rapid" -}}
{{- if or (lt (len .Values.storage.rapid.buckets) 1) (gt (len .Values.storage.rapid.buckets) 2) }}{{ fail "Rapid requires one or two buckets in distinct zones" }}{{ end -}}
{{- if and (eq .Values.storage.rapid.placement "nearest") (ne (len .Values.storage.rapid.buckets) 2) }}{{ fail "nearest Rapid placement requires two buckets" }}{{ end -}}
{{- $zones := dict -}}{{- $buckets := dict -}}
{{- range .Values.storage.rapid.buckets -}}
{{- if hasKey $zones .zone }}{{ fail "Rapid buckets require distinct zones" }}{{ end -}}
{{- if or (hasKey $buckets .bucket) (eq .bucket $.Values.storage.bucket) }}{{ fail "Rapid and Standard buckets must be distinct" }}{{ end -}}
{{- $_ := set $zones .zone true -}}{{- $_ := set $buckets .bucket true -}}
{{- end -}}
{{- else if or .Values.storage.rapid.buckets (eq .Values.storage.rapid.placement "nearest") }}{{ fail "Rapid settings require storage.mode=rapid" }}{{ end -}}
{{- end -}}
