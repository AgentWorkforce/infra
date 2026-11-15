{{/* Bare destination origins only. HTTP requires explicit in-cluster Service DNS. */}}
{{- define "sessions-pipeline.ingestEdge.endpoint" -}}
{{- $url := required (printf "%s is required" .name) .url | trim -}}
{{- $host := regexReplaceAll ":[0-9]+$" (regexReplaceAll "^https?://" $url "") "" -}}
{{- if gt (len $host) 253 }}{{ fail (printf "%s hostname must be at most 253 characters" .name) }}{{ end -}}
{{- $https := "^https://([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z]([a-z0-9-]{0,61}[a-z0-9])?(:[0-9]{1,5})?$" -}}
{{- $http := "^http://[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?\\.[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?\\.svc(\\.cluster\\.local)?(:[0-9]{1,5})?$" -}}
{{- if not (or (regexMatch $https $url) (and .allowHttp (regexMatch $http $url))) -}}
{{- fail (printf "%s must be a bare HTTPS DNS origin, or an explicitly admitted HTTP Kubernetes Service origin" .name) -}}
{{- end -}}
{{- $port := regexFind ":[0-9]+$" $url -}}
{{- if and $port (or (lt (int (trimPrefix ":" $port)) 1) (gt (int (trimPrefix ":" $port)) 65535)) -}}
{{- fail (printf "%s has an invalid port" .name) -}}
{{- end -}}
{{- $url -}}
{{- end -}}

{{/* An older image can ignore a new environment variable. Require the real
admission-consumer response before routing async/drain traffic to the Pod. */}}
{{- define "sessions-pipeline.ingestEdge.admissionProbe" -}}
const fail = () => { process.exitCode = 1; };
const port = Number(process.env.RELAYHISTORY_INGEST_PORT);
const mode = process.env.SELFHOST_INGEST_ADMISSION;
const count = v => Number.isSafeInteger(v) && v >= 0;
if (!["async", "drain"].includes(mode) || !Number.isInteger(port) || port < 1024 || port > 65535) {
  fail();
} else {
  fetch(`http://127.0.0.1:${port}/readyz`, { redirect: "error", signal: AbortSignal.timeout(1500) })
    .then(async response => {
      if (!response.ok) return fail();
      const body = await response.json();
      const a = body?.consumer;
      if (body?.ok !== true || body?.enabled !== true || body?.admission !== mode
          || a?.ok !== true || a?.state !== "ok"
          || ![a.backlog, a.deadLettered, a.inFlight, a.lastScanAgeMs].every(count)
          || !(a.oldestAgeMs === null || count(a.oldestAgeMs))) fail();
    }).catch(fail);
}
{{- end -}}

{{/* ingestEdge.ledger (pipeline decision 0005, INGEST_LEDGER): validated, and the binary's s3 startup refusals
(pipeline selfhost-config.ts selfhostLedger) mirrored, so a refused combination never renders. Their state is
SQL-only. INGEST_UPLOAD_CONSENT is never rendered and ingestEdge.extraEnv is refused, so upload consent is always off
here. Included first by every template that depends on the ledger, so the same message wins whichever renders first.
Returns sql or s3. */}}
{{- define "sessions-pipeline.ingestEdge.ledger" -}}
{{- $c := .Values.ingestEdge -}}
{{- $ledger := $c.ledger | default "sql" -}}
{{- if not (has $ledger (list "sql" "s3")) }}{{ fail "ingestEdge.ledger must be sql or s3" }}{{ end -}}
{{- if and $c.enabled (eq $ledger "s3") -}}
{{- if $c.sessionSelection }}{{ fail "ingestEdge.ledger=s3 refuses ingestEdge.sessionSelection=true (RELAYHISTORY_SELFHOST_SESSION_SELECTION): its state is SQL-only, and the binary refuses this combination at startup" }}{{ end -}}
{{- if or .Values.global.operatorSessionErase.fenceEnforced .Values.operatorSessionErase.api.enabled .Values.operatorSessionErase.bytes.enabled }}{{ fail "ingestEdge.ledger=s3 refuses the operator session erase (global.operatorSessionErase.fenceEnforced, operatorSessionErase.api.enabled, operatorSessionErase.bytes.enabled): its state is SQL-only, and the binary refuses this combination at startup" }}{{ end -}}
{{- end -}}
{{- $ledger -}}
{{- end -}}
