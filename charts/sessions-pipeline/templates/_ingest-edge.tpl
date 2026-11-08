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
