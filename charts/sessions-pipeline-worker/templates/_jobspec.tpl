{{/*
Job spec, rendered once so its exact text can be hashed into the Job name.
*/}}
{{- define "sessions-pipeline-worker.jobSpec" -}}
{{- $ := .context -}}
{{- $component := .service -}}
backoffLimit: {{ .config.backoffLimit }}
activeDeadlineSeconds: {{ .config.activeDeadlineSeconds }}
{{- if .config.ttlSecondsAfterFinished }}
ttlSecondsAfterFinished: {{ .config.ttlSecondsAfterFinished }}
{{- end }}
template:
  metadata:
    labels:
      {{- include "sessions-pipeline-worker.componentSelectorLabels" (dict "context" $ "component" $component) | nindent 6 }}
      {{- with $.Values.podLabels }}
      {{- toYaml . | nindent 6 }}
      {{- end }}
    {{- with $.Values.podAnnotations }}
    annotations:
      {{- toYaml . | nindent 6 }}
    {{- end }}
  spec:
    restartPolicy: Never
    {{- include "sessions-pipeline-worker.podSpecCommon" (dict "context" $ "component" .service) | nindent 4 }}
    {{- if and (eq .job "migrate") .config.waitForRole.enabled }}
    {{- $w := .config.waitForRole }}
    {{- if not (regexMatch "^[^@]+@sha256:[0-9a-f]{64}$" $w.image) }}{{ fail "sessions-pipeline-worker: migrations.waitForRole.image must be a full image reference with @sha256:<64 hex>" }}{{ end }}
    {{- if not (regexMatch "^[a-z_][a-z0-9_]*$" $w.role) }}{{ fail "sessions-pipeline-worker: migrations.waitForRole.role must be a plain lower-case role name" }}{{ end }}
    initContainers:
      # Runs before migrate: blocks until the role exists in HoopDb.
      - name: wait-for-role
        image: {{ $w.image | quote }}
        imagePullPolicy: IfNotPresent
        env:
          {{- include "sessions-pipeline-worker.hoopdbUrlEnv" (dict "root" $ "migrate" true) | nindent 10 }}
          {{- $roles := list $w.role }}{{ if ne $.Values.migrations.databaseMode "local" }}{{ $roles = append $roles $.Values.migrations.runtimeRole }}{{ end }}
          - { name: ROLES, value: {{ join " " $roles | quote }} }
          - { name: FUNCTION_DEFAULT, value: {{ ternary "true" "false" (eq $w.functionDefault true) | quote }} }
          - { name: INTERVAL, value: {{ $w.intervalSeconds | quote }} }
          - { name: HOME, value: /tmp }
          {{- if ($.Values.postgresCa | default dict).enabled }}
          - { name: PGSSLROOTCERT, value: /etc/postgres-ca/ca.crt }
          {{- end }}
        command: ["/bin/sh", "-c"]
        args:
          - |
            set -u
            n=0; list=""
            for r in $ROLES; do n=$((n + 1)); list="${list:+$list,}'$r'"; done
            q="SELECT (SELECT count(*) FROM pg_roles WHERE rolname IN ($list)) = $n"
            what="$ROLES"
            if [ "$FUNCTION_DEFAULT" = true ]; then
              # The migration owner's (current_user's) global function default is
              # exactly {<owner>:EXECUTE}: hoopdb_function_default_revoke.sql ran.
              q="$q AND EXISTS (SELECT 1 FROM pg_default_acl d WHERE d.defaclrole = (SELECT oid FROM pg_roles WHERE rolname = current_user) AND d.defaclnamespace = 0 AND d.defaclobjtype = 'f' AND (SELECT array_agg(a.grantee::text || ':' || a.privilege_type || ':' || a.is_grantable::text) FROM aclexplode(d.defaclacl) a) = ARRAY[d.defaclrole::text || ':EXECUTE:false'])"
              what="$ROLES + owner function default"
            fi
            # A failed query (connection, auth) is logged, not hidden.
            until out=$(psql "$HOOPDB_URL" -X -At -c "$q" 2>&1) && [ "$out" = t ]; do
              case $out in t|f) ;; *) echo "wait-for-role: query failed: $out" ;; esac
              echo "wait-for-role: waiting for ${what}"
              sleep "$INTERVAL"
            done
            echo "wait-for-role: present: ${what}"
        {{- with $.Values.containerSecurityContext }}
        securityContext:
          {{- toYaml . | nindent 10 }}
        {{- end }}
        resources:
          {{- toYaml $w.resources | nindent 10 }}
        volumeMounts:
          - name: tmp
            mountPath: /tmp
          {{- if ($.Values.postgresCa | default dict).enabled }}
          - { name: postgres-ca, mountPath: /etc/postgres-ca, readOnly: true }
          {{- end }}
    {{- end }}
    containers:
      - name: {{ .job }}
        image: {{ include "sessions-pipeline-worker.image" $ | quote }}
        imagePullPolicy: {{ $.Values.image.pullPolicy }}
        env:
          {{- include "sessions-pipeline-worker.env" (dict "context" $ "service" .service) | nindent 10 }}
          {{- if eq .job "migrate" }}
          {{- include "sessions-pipeline-worker.profileEnv" $.Values.migrations | nindent 10 }}
          # Always on: readiness needs the phase 2 PASS marker this run writes.
          - name: HOOPDB_ROLE_VERIFY
            value: "true"
          {{- if ($.Values.postgresCa | default dict).enabled }}
          - { name: NODE_EXTRA_CA_CERTS, value: /etc/postgres-ca/ca.crt }
          {{- end }}
          {{- end }}
        {{- with $.Values.containerSecurityContext }}
        securityContext:
          {{- toYaml . | nindent 10 }}
        {{- end }}
        {{- with .config.resources }}
        resources:
          {{- toYaml . | nindent 10 }}
        {{- end }}
        volumeMounts:
          - name: tmp
            mountPath: /tmp
          {{- if and ($.Values.postgresCa | default dict).enabled (eq .job "migrate") }}
          - { name: postgres-ca, mountPath: /etc/postgres-ca, readOnly: true }
          {{- end }}
{{- end }}
