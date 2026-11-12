{{- define "agent-relay.validate" -}}
{{- range $old, $new := dict "relay-cloud-api" "relay-control" "relay-dashboard" "relay-webapp" }}
{{- if hasKey $.Values $old }}{{ fail (printf "values key %s was renamed to %s; translate overrides explicitly before upgrading (docs/control-webapp-chart-rename.md)" $old $new) }}{{ end }}
{{- end }}
{{- range $old, $new := dict "cloudApi" "control" "dashboard" "webapp" }}
{{- if hasKey ($.Values.components | default dict) $old }}{{ fail (printf "components.%s was renamed to components.%s; translate overrides explicitly before upgrading (docs/control-webapp-chart-rename.md)" $old $new) }}{{ end }}
{{- end }}
{{- if and (dig "relaycast" true (.Values.components | default dict)) (eq (dig "credentials" "authority" "" (.Values.relaycast | default dict)) "relayauth") (not (dig "relayauth" true (.Values.components | default dict))) }}
{{- fail "relaycast.credentials.authority=relayauth requires components.relayauth=true: RelayAuth is the ar_ credential authority that pushes ar_ws_ keys into Relaycast" }}
{{- end }}
{{- $brand := dig "branding" "logo" dict (.Values.global | default dict) | default dict -}}
{{- if and (kindIs "map" $brand) (or $brand.svg $brand.existingConfigMap) (dig "control" true (.Values.components | default dict)) (not (dig "webapp" true (.Values.components | default dict))) (not (dig "login" "logoUrl" "" (index .Values "relay-control" | default dict))) }}
{{- fail "global.branding.logo is hosted by relay-webapp, but components.webapp=false: the sign-in page would link a logo nothing serves. Enable components.webapp, or host the logo yourself and set relay-control.login.logoUrl" }}
{{- end }}
{{- include "agent-relay.validateHistoryOrigin" . }}
{{- include "agent-relay.validateDurableActors" . }}
{{- include "agent-relay.validateSingleHost" . }}
{{- include "agent-relay.validateNativeHistory" . }}
{{- include "agent-relay.validateOperatorSessionErase" . }}
{{- end }}

{{- define "agent-relay.validateOperatorSessionErase" -}}
{{- $components := .Values.components | default dict -}}
{{- $pipeline := index .Values "sessions-pipeline" | default dict -}}
{{- $control := index .Values "relay-control" | default dict -}}
{{- $api := dig "operatorSessionErase" "api" dict $pipeline | default dict -}}
{{- $handoff := dig "sessionErasureApi" dict $control | default dict -}}
{{- $apiOn := dig "enabled" false $api -}}
{{- $handoffOn := dig "enabled" false $handoff -}}
{{- if or $apiOn $handoffOn -}}
{{- if not (dig "sessionsPipeline" true $components) }}{{ fail "operator session erase API requires components.sessionsPipeline=true" }}{{ end -}}
{{- if not (dig "control" true $components) }}{{ fail "operator session erase API requires components.control=true" }}{{ end -}}
{{- if ne $apiOn $handoffOn }}{{ fail "sessions-pipeline.operatorSessionErase.api.enabled and relay-control.sessionErasureApi.enabled must be enabled together" }}{{ end -}}
{{- if not (dig "operatorSessionErase" "fenceEnforced" false (.Values.global | default dict)) }}{{ fail "operator session erase API requires global.operatorSessionErase.fenceEnforced=true" }}{{ end -}}
{{- if or (ne (dig "existingSecret" "" $api) (dig "existingSecret" "" $handoff)) (ne (dig "secretKey" "" $api) (dig "secretKey" "" $handoff)) }}{{ fail "Control and ingest must reference the same operator session erase API Secret and key" }}{{ end -}}
{{- $ingest := dig "ingestEdge" dict $pipeline | default dict -}}
{{- $service := default (printf "%s-ingest-edge" .Release.Name) (dig "fullnameOverride" "" $ingest) -}}
{{- $expected := printf "http://%s.%s.svc.cluster.local" $service .Release.Namespace -}}
{{- if ne (dig "url" "" $handoff) $expected }}{{ fail (printf "relay-control.sessionErasureApi.url must be the ingest Service origin %s" $expected) }}{{ end -}}
{{- end -}}
{{- end -}}

{{- define "agent-relay.validateNativeHistory" -}}
{{- $pipeline := index .Values "sessions-pipeline" | default dict -}}
{{- if dig "nativeRouting" "enabled" false $pipeline -}}
{{- if not .Values.components.sessionsPipeline }}{{ fail "native History routing requires components.sessionsPipeline=true" }}{{ end -}}
{{- if and .Values.components.relayhistory (dig "ingress" "enabled" false (.Values.relayhistory | default dict)) }}{{ fail "native History routing requires relayhistory.ingress.enabled=false; retain the server separately if needed" }}{{ end -}}
{{- if (.Values.gkeIngress | default dict).enabled }}{{ fail "native History routing cannot share the legacy gkeIngress History backend" }}{{ end -}}
{{- if .Values.components.control -}}
{{- $api := index .Values "relay-control" -}}
{{- $origin := dig "nativeRouting" "origin" "" $pipeline -}}
{{- if $api.services.relayauthEnabled }}{{ fail "native History routing requires Control services.relayauthEnabled=false so login forwards the caller token" }}{{ end -}}
{{- if eq ($api.services.relayhistoryBackend | default "legacy") "native" -}}
{{- if ne (dig "sessionReadApi" "auth" "mode" "" $pipeline) "self_issued" }}{{ fail "native Control backend requires an independent self_issued reader" }}{{ end -}}
{{- if or $api.services.relayhistoryPublicUrl (ne $origin $api.services.sessionReadApiPublicUrl) }}{{ fail "native History origin must exactly equal Control's independent reader public origin" }}{{ end -}}
{{- if not $api.services.sessionReadApiMcpReads }}{{ fail "native Control backend requires sessionReadApiMcpReads=true" }}{{ end -}}
{{- else -}}
{{- if eq (dig "sessionReadApi" "auth" "mode" "" $pipeline) "self_issued" }}{{ fail "self_issued reader requires Control services.relayhistoryBackend=native" }}{{ end -}}
{{- if or (ne $origin $api.services.relayhistoryPublicUrl) (ne $origin $api.services.relayhistoryReadApiUrl) }}{{ fail "native History origin must exactly equal Control's managed public and direct-reader origins" }}{{ end -}}
{{- if not $api.services.relayhistoryReadApiEvents }}{{ fail "native History with Control requires services.relayhistoryReadApiEvents=true and a compatible Control image" }}{{ end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Session ingest (alleyoop) verifies courier History assertions against the same
audience RelayHistory issues them for, so the two origins must be byte-equal.
*/}}
{{- define "agent-relay.validateHistoryOrigin" -}}
{{- $components := .Values.components | default dict -}}
{{- if and (dig "sessionsPipeline" true $components) (dig "relayhistory" true $components) }}
{{- $ingest := dig "alleyoop" "auth" "historyOrigin" "" (index .Values "sessions-pipeline" | default dict) -}}
{{- $history := dig "relayauth" "historyOrigin" "" (.Values.relayhistory | default dict) -}}
{{- if and $ingest $history (ne $ingest $history) }}
{{- fail (printf "sessions-pipeline.alleyoop.auth.historyOrigin (%s) must equal relayhistory.relayauth.historyOrigin (%s): session ingest verifies courier History assertions against that audience" $ingest $history) }}
{{- end }}
{{- end }}
{{- end }}

{{/*
durable-actors wiring between the umbrella, the vendored control-plane chart
and its actor-mode consumers (relaycast, relayfile).
*/}}
{{- define "agent-relay.validateDurableActors" -}}
{{- $components := .Values.components | default dict -}}
{{- $actorsOn := dig "durableActors" false $components -}}
{{- $da := index .Values "durable-actors" | default dict -}}
{{- $consumers := list -}}
{{- range $name, $component := dict "relaycast" "relaycast" "relayfile" "relayfile" }}
{{- $child := index $.Values $name | default dict -}}
{{- if and (dig $component false $components) (eq (dig "runtime" "backend" "" $child) "durable-actors") }}
{{- $cfg := dig "runtime" "durableActors" (dict) $child -}}
{{- if not (dig "devRuntime" "enabled" false $cfg) }}
{{- if not (dig "controlPlaneUrl" "" $cfg) }}{{- $consumers = append $consumers $name -}}{{- end }}
{{- if and (not (dig "controlPlaneUrl" "" $cfg)) (not $actorsOn) }}
{{- fail (printf "%s.runtime.backend=durable-actors requires components.durableActors=true (or %s.runtime.durableActors.controlPlaneUrl for an external control plane)" $name $name) }}
{{- end }}
{{- if and $actorsOn (not (dig "controlPlaneUrl" "" $cfg)) }}
{{- $adminSecret := dig "adminKeySecret" "name" "actors-credentials" $cfg -}}
{{- $credentials := dig "credentialsSecret" "actors-credentials" $da -}}
{{- if ne $adminSecret $credentials }}
{{- fail (printf "%s.runtime.durableActors.adminKeySecret.name (%s) must be durable-actors.credentialsSecret (%s): the admin api-key lives in the control plane's credentials Secret" $name $adminSecret $credentials) }}
{{- end }}
{{- $adminKey := dig "adminKeySecret" "key" "api-key" $cfg -}}
{{- if ne $adminKey "api-key" }}
{{- fail (printf "%s.runtime.durableActors.adminKeySecret.key (%s) must be api-key: the control plane reads its admin api-key from credentialsSecret[api-key]" $name $adminKey) }}
{{- end }}
{{- $bucket := dig "storage" "bucket" "" $da -}}
{{- $artifact := dig "deployer" "artifactBucket" "" $cfg -}}
{{- if and (dig "deployer" "enabled" true $cfg) $artifact (ne $artifact $bucket) }}
{{- fail (printf "%s.runtime.durableActors.deployer.artifactBucket (%s) must be durable-actors.storage.bucket (%s): the control plane reads compiled code only from its own bucket" $name $artifact $bucket) }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}
{{- if and $actorsOn (not $consumers) }}
{{- fail "components.durableActors=true has no consumer: set relaycast.runtime.backend or relayfile.runtime.backend to durable-actors without controlPlaneUrl (devRuntime consumers and consumers with an external controlPlaneUrl do not use the in-umbrella control plane)" }}
{{- end }}
{{- end }}

{{/*
Single-host mode (global.singleHost.host): the dashboard and the control API
share one host (/ and /cloud/api, /login, /api). Relaycast, Relay History,
Relayfile and the durable-actors control plane cannot be served under a path
prefix on that host without app changes, so they stay on their own hosts and
the chart refuses to put them on the single host.
*/}}
{{- define "agent-relay.singleHostGaps" -}}
relaycast: the relaycast-self-host entrypoint refuses a --base-url with a path, the TypeScript SDK drops a base path, and relaycontrol and Desktop refuse a path-prefixed Relaycast URL
relayhistory: relaycontrol and Desktop require relayhistoryPublicUrl to be a bare origin (it is both the History assertion audience and the base URL handed to clients), so a /history prefix cannot be expressed
relayfile: the relayfile mount and listen clients build their WebSocket URLs by replacing the path, which drops a server base path
durable-actors: the control plane refuses a publicUrl with a path and issues actor WebSocket URLs at <origin>/v1/socket, and the SDK refuses a base path
{{- end -}}
{{- define "agent-relay.singleHostGap" -}}
{{- $name := .name -}}
{{- range $line := splitList "\n" (include "agent-relay.singleHostGaps" .root) }}{{ if hasPrefix (printf "%s: " $name) $line }}{{ trimPrefix (printf "%s: " $name) $line }}{{ end }}{{ end -}}
{{- end -}}
{{- define "agent-relay.validateSingleHost" -}}
{{- $single := dig "singleHost" "host" "" (.Values.global | default dict) -}}
{{- if $single }}
{{- if or (gt (len $single) 253) (regexMatch "(^|\\.)[0-9]+$" $single) (not (regexMatch "^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)*[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$" $single)) }}{{ fail "global.singleHost.host must be a lowercase DNS hostname (no scheme, port or path; labels of 1-63 characters that start and end with a letter or digit, not an IP address)" }}{{ end -}}
{{- $components := .Values.components | default dict -}}
{{- $cloudApi := index .Values "relay-control" | default dict -}}
{{- $sessions := index .Values "sessions-pipeline" | default dict -}}
{{- $urls := list
  (list "relaycast" "relaycast.baseUrl" (dig "baseUrl" "" (.Values.relaycast | default dict)) (dig "relaycast" true $components))
  (list "relaycast" "relay-control.services.relaycastPublicUrl" (dig "services" "relaycastPublicUrl" "" $cloudApi) (dig "control" true $components))
  (list "relayhistory" "relayhistory.relayauth.historyOrigin" (dig "relayauth" "historyOrigin" "" (.Values.relayhistory | default dict)) (dig "relayhistory" true $components))
  (list "relayhistory" "relay-control.services.relayhistoryPublicUrl" (dig "services" "relayhistoryPublicUrl" "" $cloudApi) (dig "control" true $components))
  (list "relayhistory" "sessions-pipeline.alleyoop.auth.historyOrigin" (dig "alleyoop" "auth" "historyOrigin" "" $sessions) (dig "sessionsPipeline" true $components))
  (list "durable-actors" "durable-actors.publicUrl" (dig "publicUrl" "" (index .Values "durable-actors" | default dict)) (dig "durableActors" false $components))
-}}
{{- range $u := $urls }}
{{- $url := index $u 2 | toString -}}
{{- if and (index $u 3) $url (eq (lower (urlParse $url).hostname) $single) }}
{{- fail (printf "%s must not use global.singleHost.host (%s): %s cannot share the single host yet (%s). Keep it on its own host" (index $u 1) $single (index $u 0) (include "agent-relay.singleHostGap" (dict "root" $ "name" (index $u 0)))) }}
{{- end -}}
{{- end }}
{{- $leafHosts := list
  (list "relaycast" "relaycast.ingress.hosts" (dig "ingress" "hosts" (list) (.Values.relaycast | default dict)) (dig "relaycast" true $components))
  (list "relayhistory" "relayhistory.ingress.hosts" (dig "ingress" "hosts" (list) (.Values.relayhistory | default dict)) (dig "relayhistory" true $components))
-}}
{{- range $l := $leafHosts }}
{{- if and (index $l 3) (has $single (index $l 2)) }}
{{- fail (printf "%s must not include global.singleHost.host (%s): %s cannot share the single host yet (%s). Keep it on its own host" (index $l 1) $single (index $l 0) (include "agent-relay.singleHostGap" (dict "root" $ "name" (index $l 0)))) }}
{{- end -}}
{{- end }}
{{- if dig "relayfile" false $components }}
{{- range $h := dig "ingress" "hosts" (list) (.Values.relayfile | default dict) }}
{{- if eq (dig "host" "" $h) $single }}{{ fail (printf "relayfile.ingress.hosts must not include global.singleHost.host (%s): relayfile cannot share the single host yet (%s). Keep it on its own host" $single (include "agent-relay.singleHostGap" (dict "root" $ "name" "relayfile"))) }}{{ end -}}
{{- end }}
{{- end }}
{{- end }}
{{- end }}
