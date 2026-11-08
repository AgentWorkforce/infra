{{- define "sessions-pipeline.searchIndexer.env" -}}
{{- $c := .c -}}
- { name: SERVICE, value: {{ .service }} }
- { name: RELAYHISTORY_SELFHOST_PIPELINE_CONSUMER, value: "true" }
- name: RELAYHISTORY_PIPELINE_CONSUMER_SECRET
  valueFrom:
    secretKeyRef: { name: {{ .secret | quote }}, key: {{ .key | quote }} }
- { name: SEARCH_INDEX_BACKEND, value: {{ $c.search.backend | quote }} }
- { name: SEARCH_INDEX_POSTGRES_BACKEND_ID, value: {{ $c.search.backendId | quote }} }
- { name: READ_API_COMPLETE_SINCE, value: {{ $c.completeSince | quote }} }
- { name: PIPELINE_KEY_PREFIX, value: {{ $c.keyPrefix | quote }} }
- { name: PIPELINE_ORG_FROM_PREFIX, value: "true" }
- { name: SESSION_POSTGRES_TLS_PROFILE, value: {{ $c.postgres.tlsProfile | quote }} }
{{- if eq $c.postgres.tlsProfile "custom-ca" }}
- { name: SESSION_POSTGRES_CA_FILE, value: /etc/search-indexer-postgres/ca.crt }
- { name: SESSION_POSTGRES_CA_SHA256, value: {{ $c.postgres.caSha256 | quote }} }
{{- end }}
- { name: LOCKER_BUCKET, value: {{ $c.locker.bucket | quote }} }
- { name: LOCKER_REGION, value: {{ $c.locker.region | quote }} }
{{- with $c.locker.endpoint }}
- { name: LOCKER_ENDPOINT, value: {{ . | quote }} }
{{- end }}
{{- if eq $c.search.backend "opensearch" }}
- { name: SEARCH_INDEX_OPENSEARCH_URL, value: {{ $c.search.opensearch.url | quote }} }
- { name: SEARCH_INDEX_OPENSEARCH_AUTH, value: sigv4 }
- { name: SEARCH_INDEX_OPENSEARCH_AWS_REGION, value: {{ $c.search.opensearch.region | quote }} }
- { name: SEARCH_INDEX_OPENSEARCH_INDEX_PREFIX, value: {{ $c.search.opensearch.indexPrefix | quote }} }
{{- end }}
{{- end -}}
{{- define "sessions-pipeline.searchIndexer.container" -}}
securityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities: { drop: [ALL] }
volumeMounts:
  - { name: tmp, mountPath: /tmp }
  {{- if eq .Values.searchIndexer.postgres.tlsProfile "custom-ca" }}
  - { name: postgres-ca, mountPath: /etc/search-indexer-postgres, readOnly: true }
  {{- end }}
{{- end -}}
{{- define "sessions-pipeline.searchIndexer.pod" -}}
{{- $c := .Values.searchIndexer -}}
automountServiceAccountToken: false
serviceAccountName: {{ $c.serviceAccount.name | quote }}
{{- with $c.imagePullSecrets }}
imagePullSecrets:
  {{- toYaml . | nindent 2 }}
{{- end }}
securityContext:
  runAsNonRoot: true
  runAsUser: 1000
  runAsGroup: 1000
  fsGroup: 1000
  seccompProfile: { type: RuntimeDefault }
{{- with $c.nodeSelector }}
nodeSelector:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with $c.tolerations }}
tolerations:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with $c.affinity }}
affinity:
  {{- toYaml . | nindent 2 }}
{{- end }}
volumes:
  - name: tmp
    emptyDir: { sizeLimit: 2Gi }
  {{- if eq $c.postgres.tlsProfile "custom-ca" }}
  - name: postgres-ca
    configMap:
      name: {{ $c.postgres.caConfigMap | quote }}
      items:
        - { key: {{ $c.postgres.caKey | quote }}, path: ca.crt }
  {{- end }}
{{- end -}}
