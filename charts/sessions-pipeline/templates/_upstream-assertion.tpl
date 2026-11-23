{{- /* Upstream verification (global.relaygate.upstreamAuth.verify, set in the
agent-relay umbrella): the service accepts only relaygate-signed requests
(header X-Relaygate-Assertion, Ed25519). mode off renders nothing (the service
default); log or enforce render INGEST_UPSTREAM_ASSERTION_MODE and the
current (and, during a rotation, previous) public key, canonical base64 SPKI
DER, from one Secret or ConfigMap, with their kids. */ -}}
{{- /* A kid as a string: an unquoted number (YAML 1000000) would otherwise print as 1e+06. */ -}}
{{- define "sessions-pipeline.upstreamAssertion.kid" -}}
{{- if or (kindIs "float64" .) (kindIs "int" .) (kindIs "int64" .) }}{{ printf "%.0f" (float64 .) }}{{ else }}{{ toString (. | default "") }}{{ end -}}
{{- end }}

{{- define "sessions-pipeline.upstreamAssertion.mode" -}}
{{- $m := dig "relaygate" "upstreamAuth" "verify" "mode" "off" (.Values.global | default dict) -}}
{{- if kindIs "bool" $m }}{{ ternary "on" "off" $m }}{{ else }}{{ $m | toString }}{{ end -}}
{{- end }}

{{- define "sessions-pipeline.upstreamAssertion.on" -}}
{{- if has (include "sessions-pipeline.upstreamAssertion.mode" .) (list "log" "enforce") }}true{{ end -}}
{{- end }}

{{- define "sessions-pipeline.upstreamAssertion.validate" -}}
{{- $m := include "sessions-pipeline.upstreamAssertion.mode" . -}}
{{- if not (has $m (list "off" "log" "enforce")) }}{{ fail (printf "sessions-pipeline: global.relaygate.upstreamAuth.verify.mode must be off, log or enforce, got %q" $m) }}{{ end -}}
{{- if include "sessions-pipeline.upstreamAssertion.on" . }}
{{- $pk := dig "relaygate" "upstreamAuth" "verify" "publicKeys" dict .Values.global -}}
{{- if eq (empty (dig "secretName" "" $pk)) (empty (dig "configMapName" "" $pk)) }}{{ fail "sessions-pipeline: global.relaygate.upstreamAuth.verify.mode log or enforce needs exactly one of verify.publicKeys.secretName or configMapName (the public keys)" }}{{ end -}}
{{- if or (not (dig "currentKey" "" $pk)) (not (regexMatch "^[A-Za-z0-9._-]{1,64}$" (include "sessions-pipeline.upstreamAssertion.kid" (dig "currentKid" "" $pk)))) }}{{ fail "sessions-pipeline: global.relaygate.upstreamAuth.verify needs publicKeys.currentKey and currentKid (1-64 of A-Z a-z 0-9 . _ -)" }}{{ end -}}
{{- end }}
{{- end }}

{{- define "sessions-pipeline.upstreamAssertion.env" -}}
{{- if include "sessions-pipeline.upstreamAssertion.on" . }}
{{- $pk := .Values.global.relaygate.upstreamAuth.verify.publicKeys -}}
{{- $ref := ternary (printf "configMapKeyRef: { name: %s" ($pk.configMapName | quote)) (printf "secretKeyRef: { name: %s" ($pk.secretName | quote)) (not (empty (dig "configMapName" "" $pk))) -}}
- { name: INGEST_UPSTREAM_ASSERTION_MODE, value: {{ include "sessions-pipeline.upstreamAssertion.mode" . | quote }} }
- name: INGEST_UPSTREAM_ASSERTION_PUBLIC_KEY
  valueFrom: { {{ $ref }}, key: {{ $pk.currentKey | quote }} } }
- { name: INGEST_UPSTREAM_ASSERTION_KID, value: {{ include "sessions-pipeline.upstreamAssertion.kid" $pk.currentKid | quote }} }
{{- if dig "previousKey" "" $pk }}
- name: INGEST_UPSTREAM_ASSERTION_PUBLIC_KEY_PREVIOUS
  valueFrom: { {{ $ref }}, key: {{ $pk.previousKey | quote }} } }
- { name: INGEST_UPSTREAM_ASSERTION_KID_PREVIOUS, value: {{ include "sessions-pipeline.upstreamAssertion.kid" $pk.previousKid | quote }} }
{{- end }}
{{- end }}
{{- end }}

{{- /* Rolls the pods when the verify settings change (a rotation changes a kid). */ -}}
{{- define "sessions-pipeline.upstreamAssertion.checksum" -}}
{{- if include "sessions-pipeline.upstreamAssertion.on" . }}{{ .Values.global.relaygate.upstreamAuth.verify | toJson | sha256sum }}{{ end -}}
{{- end }}
