{{- define "relay-control.historyUpload.validate" -}}
{{- $c := .Values.historyUpload -}}
{{- if not (kindIs "map" $c) }}{{ fail "historyUpload must be an object" }}{{ end -}}
{{- if not (kindIs "string" $c.mode) }}{{ fail "historyUpload.mode must be a string" }}{{ end -}}
{{- if not (kindIs "slice" $c.allowlist) }}{{ fail "historyUpload.allowlist must be a list" }}{{ end -}}
{{- if not (has $c.mode (list "off" "allowlist" "on")) }}{{ fail "historyUpload.mode must be off, allowlist or on" }}{{ end -}}
{{- if ne $c.mode "off" -}}
{{- if and (eq $c.mode "allowlist") (empty $c.allowlist) }}{{ fail "historyUpload.allowlist is required in allowlist mode" }}{{ end -}}
{{- range $id := $c.allowlist }}{{ if or (not (kindIs "string" $id)) (not $id) (contains "," $id) (ne (trim $id) $id) }}{{ fail "historyUpload.allowlist must contain nonempty user IDs without commas or surrounding whitespace" }}{{ end }}{{ end -}}
{{- if not (regexMatch "^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$" $c.bucket) }}{{ fail "historyUpload.bucket must be an S3 bucket name without dots" }}{{ end -}}
{{- if not (regexMatch "^[a-z0-9-]+$" $c.region) }}{{ fail "historyUpload.region is required" }}{{ end -}}
{{- if not (regexMatch "^[a-z0-9][a-z0-9-]{0,62}$" $c.keyRoot) }}{{ fail "historyUpload.keyRoot must follow relay-upload-inbox-v1" }}{{ end -}}
{{- if not (regexMatch "^arn:aws(-[a-z]+)*:iam::[0-9]{12}:role/.+$" $c.roleArn) }}{{ fail "historyUpload.roleArn must be an IAM role ARN" }}{{ end -}}
{{- if not (regexMatch "^arn:aws(-[a-z]+)*:kms:[a-z0-9-]+:[0-9]{12}:key/[0-9a-f-]{36}$" $c.kmsKeyArn) }}{{ fail "historyUpload.kmsKeyArn must be a customer-managed KMS key ARN" }}{{ end -}}
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
- { name: SELFHOST_HISTORY_UPLOAD_ROLE_ARN, value: {{ $c.roleArn | quote }} }
- { name: SELFHOST_HISTORY_UPLOAD_KMS_KEY_ARN, value: {{ $c.kmsKeyArn | quote }} }
- { name: SELFHOST_HISTORY_UPLOAD_MAX_OBJECT_BYTES, value: "2097152" }
- { name: SELFHOST_HISTORY_UPLOAD_WITNESS_KEY_FILE, value: /var/run/agent-relay/history-upload/witness }
{{- end }}
{{- end -}}
