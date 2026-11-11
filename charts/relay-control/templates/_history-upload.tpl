{{/* Public PUT URLs have a TLS origin; private HTTP is limited to Service DNS. */}}
{{- define "relay-control.historyUpload.endpoint" -}}
{{- $url := trimSuffix "/" .url -}}
{{- $https := "^https://([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z]([a-z0-9-]{0,61}[a-z0-9])?(:[0-9]{1,5})?$" -}}
{{- $service := "^http://[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?\\.[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?\\.svc(\\.cluster\\.local)?(:[0-9]{1,5})?$" -}}
{{- if not (or (regexMatch $https $url) (and .internal (regexMatch $service $url))) }}{{ fail (printf "%s must be a bare HTTPS DNS origin; internal HTTP requires a Kubernetes Service origin" .name) }}{{ end -}}
{{- $host := regexReplaceAll ":[0-9]+$" (regexReplaceAll "^https?://" $url "") "" -}}
{{- if gt (len $host) 253 }}{{ fail (printf "%s hostname is too long" .name) }}{{ end -}}
{{- $port := regexFind ":[0-9]+$" $url -}}
{{- if and $port (or (lt (int (trimPrefix ":" $port)) 1) (gt (int (trimPrefix ":" $port)) 65535)) }}{{ fail (printf "%s port must be 1..65535" .name) }}{{ end -}}
{{- $url -}}
{{- end -}}

{{- define "relay-control.historyUpload.validate" -}}
{{- $c := .Values.historyUpload -}}
{{- if not (kindIs "map" $c) }}{{ fail "historyUpload must be an object" }}{{ end -}}
{{- if not (kindIs "string" $c.mode) }}{{ fail "historyUpload.mode must be a string" }}{{ end -}}
{{- if not (kindIs "slice" $c.allowlist) }}{{ fail "historyUpload.allowlist must be a list" }}{{ end -}}
{{- range $name := list "publicEndpoint" "internalEndpoint" "roleArn" "kmsKeyArn" -}}
{{- if not (kindIs "string" (index $c $name)) }}{{ fail (printf "historyUpload.%s must be a string" $name) }}{{ end -}}
{{- end -}}
{{- if not (kindIs "map" $c.credentials) }}{{ fail "historyUpload.credentials must be an object" }}{{ end -}}
{{- if not (has $c.mode (list "off" "allowlist" "on")) }}{{ fail "historyUpload.mode must be off, allowlist or on" }}{{ end -}}
{{- if ne $c.mode "off" -}}
{{- if and (eq $c.mode "allowlist") (empty $c.allowlist) }}{{ fail "historyUpload.allowlist is required in allowlist mode" }}{{ end -}}
{{- range $id := $c.allowlist }}{{ if or (not (kindIs "string" $id)) (not $id) (contains "," $id) (ne (trim $id) $id) }}{{ fail "historyUpload.allowlist must contain nonempty user IDs without commas or surrounding whitespace" }}{{ end }}{{ end -}}
{{- if not (regexMatch "^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$" $c.bucket) }}{{ fail "historyUpload.bucket must be an S3 bucket name without dots" }}{{ end -}}
{{- if not (regexMatch "^[a-z0-9-]+$" $c.region) }}{{ fail "historyUpload.region is required" }}{{ end -}}
{{- if not (regexMatch "^[a-z0-9][a-z0-9-]{0,62}$" $c.keyRoot) }}{{ fail "historyUpload.keyRoot must follow relay-upload-inbox-v1" }}{{ end -}}
{{- if $c.publicEndpoint -}}
{{- $public := include "relay-control.historyUpload.endpoint" (dict "name" "historyUpload.publicEndpoint" "url" $c.publicEndpoint "internal" false) -}}
{{- if $c.internalEndpoint }}{{ $internal := include "relay-control.historyUpload.endpoint" (dict "name" "historyUpload.internalEndpoint" "url" $c.internalEndpoint "internal" true) }}{{ end -}}
{{- if $c.roleArn }}{{ fail "historyUpload.roleArn must be empty with publicEndpoint: compatible stores use presigned uploads" }}{{ end -}}
{{- if and $c.kmsKeyArn (or (gt (len $c.kmsKeyArn) 2048) (not (regexMatch "^[A-Za-z0-9:/_.+=,@-]+$" $c.kmsKeyArn))) }}{{ fail "historyUpload.kmsKeyArn must be a key ID without whitespace (at most 2048 characters)" }}{{ end -}}
{{- if or (not (kindIs "string" $c.credentials.existingSecret)) (not $c.credentials.existingSecret) (gt (len $c.credentials.existingSecret) 253) (not (regexMatch "^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?(\\.[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?)*$" $c.credentials.existingSecret)) }}{{ fail "historyUpload.credentials.existingSecret must name the dedicated issuer Secret" }}{{ end -}}
{{- range $key := list $c.credentials.accessKeyIdKey $c.credentials.secretAccessKeyKey -}}
{{- if or (not (kindIs "string" $key)) (not $key) (gt (len $key) 253) (not (regexMatch "^[A-Za-z0-9._-]+$" $key)) }}{{ fail "historyUpload.credentials keys must be Kubernetes data key names" }}{{ end -}}
{{- if and (eq $c.credentials.existingSecret $.Values.existingSecret) (eq $key $.Values.secretKeys.databaseMigrationsUrl) }}{{ fail "historyUpload.credentials must not reference the migration credential" }}{{ end -}}
{{- end -}}
{{- if eq $c.credentials.accessKeyIdKey $c.credentials.secretAccessKeyKey }}{{ fail "historyUpload.credentials requires distinct access and secret keys" }}{{ end -}}
{{- else -}}
{{- if $c.internalEndpoint }}{{ fail "historyUpload.internalEndpoint requires publicEndpoint" }}{{ end -}}
{{- if $c.credentials.existingSecret }}{{ fail "historyUpload.credentials requires publicEndpoint; AWS uses workload identity" }}{{ end -}}
{{- if not (regexMatch "^arn:aws(-[a-z]+)*:iam::[0-9]{12}:role/.+$" $c.roleArn) }}{{ fail "historyUpload.roleArn must be an IAM role ARN" }}{{ end -}}
{{- if not (regexMatch "^arn:aws(-[a-z]+)*:kms:[a-z0-9-]+:[0-9]{12}:key/[0-9a-f-]{36}$" $c.kmsKeyArn) }}{{ fail "historyUpload.kmsKeyArn must be a customer-managed KMS key ARN" }}{{ end -}}
{{- end -}}
{{- if or (not $c.witness.existingSecret) (not (regexMatch "^[A-Za-z0-9._-]+$" $c.witness.key)) }}{{ fail "historyUpload.witness requires an existingSecret and data key" }}{{ end -}}
{{- if and (eq $c.witness.existingSecret .Values.existingSecret) (eq $c.witness.key .Values.secretKeys.databaseMigrationsUrl) }}{{ fail "historyUpload witness must not reference the migration credential" }}{{ end -}}
{{- end -}}
{{- end -}}

{{- define "relay-control.historyUpload.env" -}}
{{- if ne .Values.historyUpload.mode "off" }}
- { name: SELFHOST_HISTORY_UPLOAD_DIRECT, value: {{ .Values.historyUpload.mode | quote }} }
{{- $c := .Values.historyUpload }}
- { name: SELFHOST_HISTORY_UPLOAD_ALLOWLIST, value: {{ join "," $c.allowlist | quote }} }
- { name: SELFHOST_HISTORY_UPLOAD_BUCKET, value: {{ $c.bucket | quote }} }
- { name: SELFHOST_HISTORY_UPLOAD_REGION, value: {{ $c.region | quote }} }
- { name: SELFHOST_HISTORY_UPLOAD_KEY_ROOT, value: {{ $c.keyRoot | quote }} }
{{- if $c.publicEndpoint }}
- { name: SELFHOST_HISTORY_UPLOAD_PUBLIC_ENDPOINT, value: {{ trimSuffix "/" $c.publicEndpoint | quote }} }
{{- with $c.internalEndpoint }}
- { name: SELFHOST_HISTORY_UPLOAD_INTERNAL_ENDPOINT, value: {{ trimSuffix "/" . | quote }} }
{{- end }}
- { name: SELFHOST_HISTORY_UPLOAD_ACCESS_KEY_ID_FILE, value: /var/run/agent-relay/history-upload-store/access-key-id }
- { name: SELFHOST_HISTORY_UPLOAD_SECRET_ACCESS_KEY_FILE, value: /var/run/agent-relay/history-upload-store/secret-access-key }
{{- else }}
- { name: SELFHOST_HISTORY_UPLOAD_ROLE_ARN, value: {{ $c.roleArn | quote }} }
{{- end }}
{{- if or (not $c.publicEndpoint) $c.kmsKeyArn }}
- { name: SELFHOST_HISTORY_UPLOAD_KMS_KEY_ARN, value: {{ $c.kmsKeyArn | quote }} }
{{- end }}
- { name: SELFHOST_HISTORY_UPLOAD_MAX_OBJECT_BYTES, value: "2097152" }
- { name: SELFHOST_HISTORY_UPLOAD_WITNESS_KEY_FILE, value: /var/run/agent-relay/history-upload/witness }
{{- end }}
{{- end -}}
