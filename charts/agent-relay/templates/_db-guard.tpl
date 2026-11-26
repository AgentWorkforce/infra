{{- /*
Database credential guard (databaseGuard in values.yaml,
docs/self-hosted-rds-manual-setup.md "Credential guard").

agent-relay.dbGuard.targets: JSON list of every database URL this release's
workloads read from a Secret, one entry per Secret key:
  secret, key   the Secret and key
  format        url (a bare postgres:// URL) or json (a JSON object holding it)
  field         the JSON field holding the URL (format json)
  role          the login's job; two different roles must not share a login
  relaycast     owner or runtime: relaycast's own identity check applies in full
  allowMaster   true only for the HoopDb owner on a legacy administrator-owned
                install (sessions-pipeline.worker.migrations.rdsLayout=master-owner)
  external      the Secret comes from this release's ExternalSecrets, so it may
                not exist before the install
Only enabled components contribute, and only Secrets an operator supplies:
in-cluster HoopDb (sessions-pipeline.hoopdb.enabled) is chart-managed and skipped.
*/ -}}
{{- define "agent-relay.dbGuard.targets" -}}
{{- $v := .Values -}}
{{- $components := $v.components | default dict -}}
{{- $es := $v.externalSecrets | default dict -}}
{{- $esSecrets := dict -}}
{{- if $es.enabled }}{{ $esSecrets = $es.secrets | default dict }}{{ end -}}
{{- $out := list -}}
{{- if dig "control" true $components -}}
{{- $c := index $v "relay-control" | default dict -}}
{{- $secret := toString ($c.existingSecret | default "") -}}
{{- if $secret -}}
{{- $out = append $out (dict "secret" $secret "key" (dig "secretKeys" "databaseUrl" "database-url" $c) "format" "url" "role" "relay-control runtime") -}}
{{- $out = append $out (dict "secret" $secret "key" (dig "secretKeys" "databaseMigrationsUrl" "database-migrations-url" $c) "format" "url" "role" "relay-control migrations owner") -}}
{{- end -}}
{{- end -}}
{{- $rc := index $v "relaycast" | default dict -}}
{{- if and (dig "relaycast" true $components) (eq (dig "runtime" "backend" "" $rc | toString) "postgres") -}}
{{- $secret := toString ($rc.existingSecret | default "") -}}
{{- if $secret -}}
{{- $out = append $out (dict "secret" $secret "key" (dig "secretKeys" "databaseOwnerUrl" "database-owner-url" $rc) "format" "url" "role" "relaycast owner" "relaycast" "owner") -}}
{{- $out = append $out (dict "secret" $secret "key" (dig "secretKeys" "databaseRuntimeUrl" "database-runtime-url" $rc) "format" "url" "role" "relaycast runtime" "relaycast" "runtime") -}}
{{- end -}}
{{- end -}}
{{- $sp := index $v "sessions-pipeline" | default dict -}}
{{- if and (dig "sessionsPipeline" true $components) (not (dig "hoopdb" "enabled" true $sp)) -}}
{{- $legacy := eq (dig "worker" "migrations" "rdsLayout" "" $sp | toString) "master-owner" -}}
{{- $runtime := dig "worker" "hoopdb" dict $sp | default dict -}}
{{- if $runtime.existingSecret -}}
{{- $out = append $out (dict "secret" $runtime.existingSecret "key" ($runtime.key | default "HOOPDB_URL") "format" "url" "role" "HoopDb runtime") -}}
{{- end -}}
{{- $mig := dig "worker" "migrations" "hoopdb" dict $sp | default dict -}}
{{- if and $mig.existingSecret $mig.key -}}
{{- $out = append $out (dict "secret" $mig.existingSecret "key" $mig.key "format" "url" "role" "HoopDb owner" "allowMaster" $legacy) -}}
{{- end -}}
{{- $read := $sp.sessionReadApi | default dict -}}
{{- if and $read.enabled (dig "config" "existingSecret" "" $read) -}}
{{- $out = append $out (dict "secret" $read.config.existingSecret "key" ($read.config.key | default "RELAYHISTORY_READ_API_SECRET") "format" "json" "field" "supabase_url" "role" "read API") -}}
{{- end -}}
{{- $ingest := $sp.ingestEdge | default dict -}}
{{- if and $ingest.enabled (dig "config" "existingSecret" "" $ingest) -}}
{{- $out = append $out (dict "secret" $ingest.config.existingSecret "key" ($ingest.config.databaseUrlKey | default "database-url") "format" "url" "role" "ingest edge") -}}
{{- end -}}
{{- $search := $sp.searchIndexer | default dict -}}
{{- if $search.enabled -}}
{{- if dig "config" "existingSecret" "" $search -}}
{{- $out = append $out (dict "secret" $search.config.existingSecret "key" ($search.config.key | default "RELAYHISTORY_PIPELINE_CONSUMER_SECRET") "format" "json" "field" "hoopdb_url" "role" "search indexer runtime") -}}
{{- end -}}
{{- if and (dig "bootstrap" "enabled" false $search) (dig "bootstrap" "existingSecret" "" $search) -}}
{{- $out = append $out (dict "secret" $search.bootstrap.existingSecret "key" ($search.bootstrap.key | default "RELAYHISTORY_PIPELINE_CONSUMER_SECRET") "format" "json" "field" "hoopdb_url" "role" "HoopDb owner" "allowMaster" $legacy) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- /* One entry per Secret key (the worker and alleyoop share HOOPDB_URL). */ -}}
{{- $seen := dict -}}
{{- $uniq := list -}}
{{- range $t := $out -}}
{{- $id := printf "%s/%s" $t.secret $t.key -}}
{{- if hasKey $seen $id }}{{ continue }}{{ end -}}
{{- $_ := set $seen $id true -}}
{{- $_ := set $t "external" (hasKey $esSecrets $t.secret) -}}
{{- $_ := set $t "allowMaster" (eq (toString (get $t "allowMaster")) "true") -}}
{{- $uniq = append $uniq $t -}}
{{- end -}}
{{- toJson $uniq -}}
{{- end }}

{{- define "agent-relay.dbGuard.enabled" -}}
{{- $g := .Values.databaseGuard | default dict -}}
{{- if not (hasKey $g "enabled") }}true{{ else if not (kindIs "bool" $g.enabled) }}{{ fail "databaseGuard.enabled must be true or false" }}{{ else if $g.enabled }}true{{ end -}}
{{- end }}

{{- define "agent-relay.dbGuard.pointer" -}}
Run scripts/selfhost/configure-rds.sh, which creates the logins and writes these Secrets, or see docs/self-hosted-rds-manual-setup.md §1.3 (https://agentrelay.com/docs/self-hosting/troubleshooting#database-logins).
{{- end }}

{{- /*
Render-time check with Helm lookup. lookup returns nothing under helm
template, helm install/upgrade --dry-run (client) and helm lint, so the check
runs only against a live cluster: it is skipped unless kube-system answers.
Fails the render with every problem at once, before anything is applied.
*/ -}}
{{- define "agent-relay.dbGuard.render" -}}
{{- if include "agent-relay.dbGuard.enabled" . -}}
{{- if lookup "v1" "Namespace" "" "kube-system" -}}
{{- $g := .Values.databaseGuard | default dict -}}
{{- $masters := list -}}
{{- range ($g.masterLogins | default list) }}{{ $masters = append $masters (lower (toString .)) }}{{ end -}}
{{- $problems := list -}}
{{- $byLogin := dict -}}
{{- $cache := dict -}}
{{- range $t := (include "agent-relay.dbGuard.targets" . | fromJsonArray) -}}
{{- $label := printf "%s: %s" $t.secret $t.key -}}
{{- if not (hasKey $cache $t.secret) }}{{ $_ := set $cache $t.secret (lookup "v1" "Secret" $.Release.Namespace $t.secret | default dict) }}{{ end -}}
{{- $s := get $cache $t.secret -}}
{{- if not $s -}}
{{- if not $t.external }}{{ $problems = append $problems (printf "%s: Secret %q does not exist in namespace %q (it must hold %s, the %s database URL)." $t.secret $t.secret $.Release.Namespace $t.key $t.role) }}{{ end -}}
{{- continue -}}
{{- end -}}
{{- $data := $s.data | default dict -}}
{{- if not (hasKey $data $t.key) -}}
{{- $problems = append $problems (printf "%s has no key %s (the %s database URL)." $t.secret $t.key $t.role) -}}
{{- continue -}}
{{- end -}}
{{- $raw := trim (b64dec (get $data $t.key)) -}}
{{- $url := $raw -}}
{{- if eq $t.format "json" -}}
{{- if regexMatch "^postgres(ql)?://" $raw -}}
{{- $problems = append $problems (printf "%s holds a bare URL; it must be JSON {%q:\"postgresql://...\"}." $label $t.field) -}}
{{- continue -}}
{{- end -}}
{{- $obj := dict -}}
{{- if hasPrefix "{" $raw }}{{ $obj = fromJson $raw }}{{ end -}}
{{- if or (not $obj) (hasKey $obj "Error") (not (kindIs "string" (get $obj $t.field))) -}}
{{- $problems = append $problems (printf "%s is not JSON with a %q field; it must be {%q:\"postgresql://...\"}." $label $t.field $t.field) -}}
{{- continue -}}
{{- end -}}
{{- $url = trim (get $obj $t.field) -}}
{{- else if hasPrefix "{" $raw -}}
{{- $problems = append $problems (printf "%s holds JSON; it must be a bare postgresql:// URL." $label) -}}
{{- continue -}}
{{- end -}}
{{- if not (regexMatch "^postgres(ql)?://[^/?#]+" $url) -}}
{{- $problems = append $problems (printf "%s is not a postgres:// or postgresql:// URL." $label) -}}
{{- continue -}}
{{- end -}}
{{- $u := urlParse $url -}}
{{- $user := index (splitList ":" ($u.userinfo | default "")) 0 -}}
{{- if not $user -}}
{{- $problems = append $problems (printf "%s names no login (user) in its URL." $label) -}}
{{- continue -}}
{{- end -}}
{{- if and (has (lower $user) $masters) (not $t.allowMaster) -}}
{{- $what := "a database master/administrator login" -}}
{{- if contains ".rds.amazonaws.com" ($u.host | default "") }}{{ $what = "the RDS master user" }}{{ end -}}
{{- $problems = append $problems (printf "%s logs in as %q (%s). Each service needs its own login." $label $user $what) -}}
{{- continue -}}
{{- end -}}
{{- $prev := get $byLogin $user -}}
{{- if and $prev (ne $prev.role $t.role) -}}
{{- $problems = append $problems (printf "%s: %s and %s both log in as %q; the %s and the %s need different logins." $prev.secret $prev.key $label $user $prev.role $t.role) -}}
{{- else if not $prev -}}
{{- $_ := set $byLogin $user (dict "secret" $t.secret "key" $t.key "role" $t.role) -}}
{{- end -}}
{{- end -}}
{{- if $problems -}}
{{- $header := "AR_DB_LOGIN: the database credentials in this release's Secrets are wrong; nothing was installed or changed:" -}}
{{- $footer := printf "%s Then run helm again. (databaseGuard.enabled=false turns this check off, only for a setup it does not understand.)" (include "agent-relay.dbGuard.pointer" .) -}}
{{- fail (printf "\n%s\n  - %s\n%s" $header (join "\n  - " $problems) $footer) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end }}

{{- /* The live privilege check (pre-install/pre-upgrade hook) runs in the
relaycast image, whose @relaycast/engine/adapters/postgres verifyIdentity is
the single source of the identity rules. Rendered when the guard is on, the
hook is on, relaycast runs on PostgreSQL (so its image and CA exist) and there
is at least one target. */ -}}
{{- define "agent-relay.dbGuard.hookEnabled" -}}
{{- $g := .Values.databaseGuard | default dict -}}
{{- $rc := index .Values "relaycast" | default dict -}}
{{- if and (include "agent-relay.dbGuard.enabled" .) (dig "privilegeCheck" "enabled" true $g) (dig "relaycast" true (.Values.components | default dict)) (eq (dig "runtime" "backend" "" $rc | toString) "postgres") (dig "postgresCa" "enabled" false $rc) (include "agent-relay.dbGuard.targets" . | fromJsonArray) }}true{{ end -}}
{{- end }}
