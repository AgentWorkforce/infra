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
{{- if and (eq (dig "enabled" false (.Values.eksIngress | default dict) | toString) "true") (dig "enabled" false (.Values.gkeIngress | default dict)) }}{{ fail "eksIngress.enabled and gkeIngress.enabled are exclusive: an install has one edge" }}{{ end }}
{{- include "agent-relay.validateRemovedHistory" . }}
{{- include "agent-relay.validateDurableActors" . }}
{{- include "agent-relay.validateSingleHost" . }}
{{- include "agent-relay.validateNativeHistory" . }}
{{- include "agent-relay.validateOperatorSessionErase" . }}
{{- include "agent-relay.validateGateOnly" . }}
{{- include "agent-relay.validateControlPolicy" . }}
{{- end }}

{{- define "agent-relay.gateOnly" -}}
{{- if dig "relaygate" "gateOnly" "enabled" false (.Values.global | default dict) }}true{{ end -}}
{{- end }}

{{- /* global.relaygate.gateOnly.scope: "all" (default) gates Relaycast and
Sessions; "sessions" (sessions-only) gates History and leaves Relaycast direct.
agent-relay.gateOnly is "true" for either scope (History is gated);
agent-relay.gateCast only when Relaycast is gated too. */ -}}
{{- define "agent-relay.gateScope" -}}
{{- dig "relaygate" "gateOnly" "scope" "all" (.Values.global | default dict) | default "all" | toString -}}
{{- end }}

{{- define "agent-relay.gateCast" -}}
{{- if and (include "agent-relay.gateOnly" .) (eq (include "agent-relay.gateScope" .) "all") }}true{{ end -}}
{{- end }}

{{- /* The public routes relaygate serves, shared by every edge this chart
renders (gkeIngress, eksIngress, traefikIngress). History: exact and prefix
paths on the history host. Cast (scope all only): the Relaycast allowlist.
Everything else on a gated host is denied at the edge, /internal and /admin
explicitly. Keep in step with sessions-pipeline nativeRouting and the relaycast
chart's gate-only ingress (docs/self-hosted-relaygate.md lists them). */ -}}
{{- define "agent-relay.gate.historyExact" -}}
{{- list "/v1/events" "/v1/ingest" "/v1/auth/token/refresh" "/v1/auth/token/revoke" "/v1/onboarding/heartbeat" "/v1/upload-consent" | toJson -}}
{{- end }}
{{- /* /v1/relayfacts and /v1/coordination only with
global.relaygate.gateOnly.relayfactsRoutes (off by default): they need a
relaygate image that proxies them; older images answer 404
relaygate_route_not_proxied after authentication. */ -}}
{{- define "agent-relay.gate.historyPrefix" -}}
{{- /* /v1/delivery covers batches, limits, admission, sessions/selection and
records; relaygate answers relaygate_route_not_proxied for any other child. */ -}}
{{- $p := list "/v1/sessions" "/v1/delivery" "/v1/digest" -}}
{{- if eq (dig "relaygate" "gateOnly" "relayfactsRoutes" false (.Values.global | default dict) | toString) "true" }}{{ $p = concat $p (list "/v1/relayfacts" "/v1/coordination") }}{{ end -}}
{{- $p | toJson -}}
{{- end }}
{{- define "agent-relay.gate.castExact" -}}
{{- list "/v1/register" "/v1/check" "/v1/whoami" "/v1/agent" "/v1/agent/node-token" "/v1/node/ws" "/v1/search" "/v1/inbox" | toJson -}}
{{- end }}
{{- define "agent-relay.gate.castPrefix" -}}
{{- list "/v1/agents" "/v1/channels" "/v1/messages" "/v1/dm" "/v1/streams" "/v1/deliveries" | toJson -}}
{{- end }}
{{- define "agent-relay.gate.serviceName" -}}
{{- dig "relaygate" "gateOnly" "serviceName" "" (.Values.global | default dict) | default (ternary .Release.Name (printf "%s-relaygate" .Release.Name) (contains "relaygate" .Release.Name)) | trunc 63 | trimSuffix "-" -}}
{{- end }}
{{- define "agent-relay.gate.servicePort" -}}
{{- dig "relaygate" "gateOnly" "servicePort" 8080 (.Values.global | default dict) | int -}}
{{- end }}

{{- /* "true" when url is http(s) to the in-cluster Service svc in this
release's namespace (svc, svc.<ns>, svc.<ns>.svc or svc.<ns>.svc.cluster.local). */ -}}
{{- define "agent-relay.isService" -}}
{{- $u := urlParse (trim (toString .url)) -}}
{{- $host := lower $u.hostname -}}
{{- $ns := .root.Release.Namespace -}}
{{- if and (has $u.scheme (list "http" "https")) (has $host (list .svc (printf "%s.%s" .svc $ns) (printf "%s.%s.svc" .svc $ns) (printf "%s.%s.svc.cluster.local" .svc $ns))) }}true{{ end -}}
{{- end }}

{{- /* Gate-only (global.relaygate.gateOnly.enabled): every chart narrows its
policy from the one switch; this checks the cross-chart values a parent
cannot set for its children, so a half-configured gate fails to render rather
than leaving a direct path open or a client cut off silently. */ -}}
{{- define "agent-relay.validateGateOnly" -}}
{{- if include "agent-relay.gateOnly" . -}}
{{- $components := .Values.components | default dict -}}
{{- $gate := .Values.relaygate | default dict -}}
{{- $pipeline := index .Values "sessions-pipeline" | default dict -}}
{{- $control := index .Values "relay-control" | default dict -}}
{{- $relaycast := .Values.relaycast | default dict -}}
{{- $g := .Values.global.relaygate.gateOnly -}}
{{- $scope := include "agent-relay.gateScope" . -}}
{{- if not (has $scope (list "all" "sessions")) }}{{ fail (printf "global.relaygate.gateOnly.scope must be all (Relaycast and Sessions through relaygate) or sessions (History only; Relaycast stays direct), got %q" $scope) }}{{ end -}}
{{- $gateCast := eq $scope "all" -}}
{{- if not (and (dig "relaygate" false $components) (dig "sessionsPipeline" true $components)) }}{{ fail "global.relaygate.gateOnly.enabled requires components.relaygate and components.sessionsPipeline (relaygate is built in: turn components.relaygate on and set relaygate.image.digest)" }}{{ end -}}
{{- if and $gateCast (not (dig "relaycast" true $components)) }}{{ fail "global.relaygate.gateOnly.scope=all requires components.relaycast (relaygate fronts Relaycast); use scope sessions to gate History only" }}{{ end -}}
{{- if not (and (dig "sessionReadApi" "enabled" false $pipeline) (dig "ingestEdge" "enabled" false $pipeline)) }}{{ fail "global.relaygate.gateOnly.enabled requires sessions-pipeline.sessionReadApi.enabled and ingestEdge.enabled (the native reader and ingest edge relaygate fronts)" }}{{ end -}}
{{- $gateName := dig "fullnameOverride" "" $gate | default (ternary .Release.Name (printf "%s-relaygate" .Release.Name) (contains "relaygate" .Release.Name)) | trunc 63 | trimSuffix "-" -}}
{{- if ne (dig "serviceName" "" $g | default (ternary .Release.Name (printf "%s-relaygate" .Release.Name) (contains "relaygate" .Release.Name)) | trunc 63 | trimSuffix "-") $gateName }}{{ fail (printf "global.relaygate.gateOnly.serviceName must be the relaygate Service %s" $gateName) }}{{ end -}}
{{- $castName := dig "nameOverride" "" $relaycast | default "relaycast" -}}
{{- $castService := dig "fullnameOverride" "" $relaycast | default (ternary .Release.Name (printf "%s-%s" .Release.Name $castName) (contains $castName .Release.Name)) | trunc 63 | trimSuffix "-" -}}
{{- $readService := dig "sessionReadApi" "fullnameOverride" "" $pipeline | default (printf "%s-read-api" .Release.Name) -}}
{{- $ingestService := dig "ingestEdge" "fullnameOverride" "" $pipeline | default (printf "%s-ingest-edge" .Release.Name) -}}
{{- $controlService := dig "fullnameOverride" "" $control | default (printf "%s-%s" .Release.Name (dig "nameOverride" "" $control | default "relay-control")) | trunc 63 | trimSuffix "-" -}}
{{- $proxy := dig "proxy" dict $gate -}}
{{- $upstreams := list (list "sessionsUploadUrl" $ingestService "the ingest edge Service") (list "sessionsReadUrl" $readService "the Sessions reader Service") -}}
{{- /* Sessions-only leaves relaycastUrl optional; when set it must still be the in-cluster Service. */ -}}
{{- if or $gateCast (dig "relaycastUrl" "" $proxy) }}{{ $upstreams = prepend $upstreams (list "relaycastUrl" $castService "the relaycast Service") }}{{ end -}}
{{- range $want := $upstreams }}
{{- $url := dig (index $want 0) "" $proxy -}}
{{- if not (include "agent-relay.isService" (dict "root" $ "url" $url "svc" (index $want 1))) }}{{ fail (printf "global.relaygate.gateOnly.enabled requires relaygate.proxy.%s to be %s (http://%s...), never a public host" (index $want 0) (index $want 2) (index $want 1)) }}{{ end -}}
{{- end }}
{{- $origin := dig "ingestEdge" "origin" "" $pipeline -}}
{{- $historyHosts := list (urlParse $origin).hostname -}}
{{- if dig "enabled" false (.Values.gkeIngress | default dict) }}{{ $historyHosts = append $historyHosts (dig "hosts" "history" "" .Values.gkeIngress) }}{{ end -}}
{{- $historyHosts = concat $historyHosts (include "agent-relay.eksHistoryHosts" . | fromJsonArray) -}}
{{- if dig "enabled" false (.Values.traefikIngress | default dict) }}{{ $historyHosts = append $historyHosts (dig "hosts" "history" "" .Values.traefikIngress) }}{{ end -}}
{{- $listed := dig "sessionsHosts" (list) $proxy -}}
{{- range $h := $historyHosts | uniq }}
{{- if and $h (not (has $h $listed)) }}{{ fail (printf "global.relaygate.gateOnly.enabled routes the history host to relaygate: relaygate.proxy.sessionsHosts must include %s" $h) }}{{ end -}}
{{- end }}
{{- /* relay-control's pod label follows its nameOverride; the peers that admit
Control must select it, or Control loses Sessions (relaygate's internal
listener) and Relaycast under gate-only. */ -}}
{{- $controlName := dig "nameOverride" "" $control | default "relay-control" -}}
{{- $controlPeers := list (list "relaygate.sessionsListener.controlFrom" (dig "sessionsListener" "controlFrom" (list (dict "podSelector" (dict "matchLabels" (dict "app.kubernetes.io/name" "relay-control")))) $gate)) -}}
{{- if $gateCast }}{{ $controlPeers = append $controlPeers (list "relaycast.networkPolicy.gateOnlyFrom" (dig "networkPolicy" "gateOnlyFrom" (list (dict "podSelector" (dict "matchLabels" (dict "app.kubernetes.io/name" "relay-control")))) $relaycast)) }}{{ end -}}
{{- range $want := $controlPeers }}
{{- $found := false -}}
{{- range $peer := index $want 1 }}
{{- if eq (dig "podSelector" "matchLabels" "app.kubernetes.io/name" "" $peer) $controlName }}{{ $found = true }}{{ end -}}
{{- range $e := dig "podSelector" "matchExpressions" (list) $peer }}{{ if and (eq (dig "key" "" $e) "app.kubernetes.io/name") (eq (dig "operator" "" $e) "In") (has $controlName (dig "values" (list) $e)) }}{{ $found = true }}{{ end }}{{ end -}}
{{- end -}}
{{- if not $found }}{{ fail (printf "global.relaygate.gateOnly.enabled: %s must select relay-control's pods (app.kubernetes.io/name %s in podSelector matchLabels, or a matchExpressions In; from relay-control.nameOverride)" (index $want 0) $controlName) }}{{ end -}}
{{- end }}
{{- $cp := dig "control" dict $gate -}}
{{- /* Inline rules matter only when relaygate reads the chart's ConfigMap:
not with existingConfigMap, and not when it pulls its policy from relay-control. */ -}}
{{- $pulls := and (dig "relaygate" "controlPolicy" "enabled" false (.Values.global | default dict)) (dig "relaygate" "controlPolicy" "pull" false (.Values.global | default dict)) -}}
{{- if and (not (dig "existingConfigMap" "" $gate)) (not $pulls) (not (dig "policy" "controlPrincipals" (list) $gate)) }}{{ fail "global.relaygate.gateOnly.enabled requires relaygate.policy.controlPrincipals: relaygate refuses every dashboard and desktop caller no rule maps (docs/self-hosted-relaygate.md, Gate-only)" }}{{ end -}}
{{- $introspect := dig "introspectUrl" "" $cp -}}
{{- if or (not (dig "control" true $components)) (not (include "agent-relay.isService" (dict "root" . "url" $introspect "svc" $controlService))) (not (hasSuffix "/internal/v1/auth/introspect" $introspect)) }}{{ fail (printf "global.relaygate.gateOnly.enabled requires components.control and relaygate.control.introspectUrl=http://%s.%s.svc.cluster.local/internal/v1/auth/introspect (dashboard and desktop callers are mapped through Control)" $controlService .Release.Namespace) }}{{ end -}}
{{- if ne (dig "sessionIngestAudience" "" $cp) $origin }}{{ fail (printf "relaygate.control.sessionIngestAudience must be the ingest origin %s (sessions-pipeline.ingestEdge.origin), the audience of the desktop's upload tokens" $origin) }}{{ end -}}
{{- $want := dig "ingestEdge" "config" dict $pipeline -}}
{{- $have := dig "secrets" "relaycontrolIntrospectSecret" dict $gate -}}
{{- if or (ne (dig "name" "" $have) (dig "existingSecret" "" $want)) (ne (dig "key" "secret" $have) (dig "introspectSecretKey" "introspect-secret" $want)) }}{{ fail (printf "relaygate.secrets.relaycontrolIntrospectSecret must be the ingest edge's Control introspection secret {name: %s, key: %s} (sessions-pipeline.ingestEdge.config)" (dig "existingSecret" "" $want) (dig "introspectSecretKey" "introspect-secret" $want)) }}{{ end -}}
{{- $readerCors := dig "sessionReadApi" "cors" "allowedOrigins" (list) $pipeline -}}
{{- if ne (toJson (dig "sessionsCorsOrigins" (list) $proxy)) (toJson $readerCors) }}{{ fail (printf "relaygate.proxy.sessionsCorsOrigins must equal sessions-pipeline.sessionReadApi.cors.allowedOrigins %s: the dashboard now reads Sessions through relaygate, whose refusals need the same CORS origins" (toJson $readerCors)) }}{{ end -}}
{{- with dig "secrets" "sessionsInternalSecret" "name" "" $gate }}
{{- $reader := dig "sessionReadApi" "auth" "selfIssued" "internalSecret" dict $pipeline -}}
{{- if or (ne . (dig "existingSecret" "" $reader)) (ne (dig "secrets" "sessionsInternalSecret" "key" "secret" $gate) (dig "key" "READ_API_INTERNAL_SECRET" $reader)) }}{{ fail (printf "relaygate.secrets.sessionsInternalSecret must be the read API's internal secret {name: %s, key: %s} (sessions-pipeline.sessionReadApi.auth.selfIssued.internalSecret)" (dig "existingSecret" "" $reader) (dig "key" "READ_API_INTERNAL_SECRET" $reader)) }}{{ end -}}
{{- end }}
{{- with dig "introspection" "audiences" (list) $control }}{{ if not (has $origin .) }}{{ fail (printf "relay-control.introspection.audiences must include %s: relaygate introspects upload tokens for that audience" $origin) }}{{ end }}{{ end -}}
{{- $castPublic := dig "services" "relaycastPublicUrl" "" $control -}}
{{- if and $gateCast (dig "enabled" false (.Values.gkeIngress | default dict)) (ne $castPublic (printf "https://%s" (dig "hosts" "cast" "" .Values.gkeIngress))) }}{{ fail (printf "global.relaygate.gateOnly.enabled requires relay-control.services.relaycastPublicUrl=https://%s: the cast host is relaygate's public origin, and Control also sends it as SELFHOST_RELAYGATE_PUBLIC_URL" (dig "hosts" "cast" "" .Values.gkeIngress)) }}{{ end -}}
{{- if $gateCast }}
{{- range $edge := list (list "eksIngress" (and (eq (dig "enabled" false (.Values.eksIngress | default dict) | toString) "true") (include "agent-relay.eksPrimaryHost" (dict "root" $ "role" "cast")))) (list "traefikIngress" (and (dig "enabled" false (.Values.traefikIngress | default dict)) (dig "hosts" "cast" "" .Values.traefikIngress))) }}
{{- with index $edge 1 }}{{ if ne $castPublic (printf "https://%s" .) }}{{ fail (printf "global.relaygate.gateOnly.scope=all requires relay-control.services.relaycastPublicUrl=https://%s: the %s cast host is relaygate's public origin, and Control also sends it as SELFHOST_RELAYGATE_PUBLIC_URL" . (index $edge 0)) }}{{ end }}{{ end -}}
{{- end }}
{{- end }}
{{- if not (dig "services" "sessionReadApiUrl" "" $control) }}{{ fail "global.relaygate.gateOnly.enabled requires relay-control.services.sessionReadApiUrl (Control's read handoff, then sent through relaygate)" }}{{ end -}}
{{- if and $gateCast (dig "slackRelay" false $components) (not (dig "relaygate" "url" "" (index .Values "slack-relay" | default dict))) }}{{ fail "global.relaygate.gateOnly.enabled requires slack-relay.relaygate.url: Relaycast admits only relaygate, so the Slack app must register through it" }}{{ end -}}
{{- end -}}
{{- end }}

{{- define "agent-relay.validateOperatorSessionErase" -}}
{{- $components := .Values.components | default dict -}}
{{- $pipeline := index .Values "sessions-pipeline" | default dict -}}
{{- $control := index .Values "relay-control" | default dict -}}
{{- $api := dig "operatorSessionErase" "api" dict $pipeline | default dict -}}
{{- $handoff := dig "sessionErasureApi" dict $control | default dict -}}
{{- $apiOn := dig "enabled" false $api -}}
{{- $handoffOn := dig "enabled" false $handoff -}}
{{- $fence := dig "operatorSessionErase" "fenceEnforced" false (.Values.global | default dict) -}}
{{- if and $fence (dig "control" true $components) (ne (dig "historyUpload" "mode" "off" $control) "off") }}{{ fail "operator session erase fencing requires relay-control.historyUpload.mode=off; Control must not issue direct-upload grants without a supported writer-drain protocol" }}{{ end -}}
{{- if or $apiOn $handoffOn -}}
{{- if not (dig "sessionsPipeline" true $components) }}{{ fail "operator session erase API requires components.sessionsPipeline=true" }}{{ end -}}
{{- if not (dig "control" true $components) }}{{ fail "operator session erase API requires components.control=true" }}{{ end -}}
{{- if ne $apiOn $handoffOn }}{{ fail "sessions-pipeline.operatorSessionErase.api.enabled and relay-control.sessionErasureApi.enabled must be enabled together" }}{{ end -}}
{{- if not $fence }}{{ fail "operator session erase API requires global.operatorSessionErase.fenceEnforced=true" }}{{ end -}}
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
{{- if (.Values.gkeIngress | default dict).enabled }}{{ fail "native History routing (sessions-pipeline.nativeRouting) cannot be combined with gkeIngress, which routes the history host itself" }}{{ end -}}
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
The standalone RelayHistory server and its chart were removed: History is the
Sessions read API and ingest edge (relay-control.services.relayhistoryBackend
native). Refuse values that would have deployed it rather than silently
dropping an install's History service on upgrade.
*/}}
{{- define "agent-relay.validateRemovedHistory" -}}
{{- if dig "relayhistory" false (.Values.components | default dict) }}{{ fail "components.relayhistory was removed: the standalone RelayHistory server is no longer part of this chart. History is served by the Sessions read API and ingest edge; see docs/self-hosted-no-relayauth.md" }}{{ end -}}
{{- if .Values.relayhistory }}{{ fail "the relayhistory values block was removed with the standalone RelayHistory server; delete it and configure sessions-pipeline.sessionReadApi and ingestEdge instead (docs/self-hosted-no-relayauth.md)" }}{{ end -}}
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
{{- /* durable-actors storage.artifactBucket (patch 14) overrides storage.bucket for code. */ -}}
{{- $bucket := dig "storage" "artifactBucket" "" $da | default (dig "storage" "bucket" "" $da) -}}
{{- $artifact := dig "deployer" "artifactBucket" "" $cfg -}}
{{- if and (dig "deployer" "enabled" true $cfg) $artifact (ne $artifact $bucket) }}
{{- fail (printf "%s.runtime.durableActors.deployer.artifactBucket (%s) must be durable-actors.storage.artifactBucket, or storage.bucket when unset (%s): the control plane reads compiled code only from that bucket" $name $artifact $bucket) }}
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
share one host (/ and /cloud/api, /login, /relay-node, /api). Relaycast, History,
Relayfile and the durable-actors control plane cannot be served under a path
prefix on that host without app changes, so they stay on their own hosts and
the chart refuses to put them on the single host.
*/}}
{{- define "agent-relay.singleHostGaps" -}}
relaycast: the relaycast-self-host entrypoint refuses a --base-url with a path, the TypeScript SDK drops a base path, and relaycontrol and Desktop refuse a path-prefixed Relaycast URL
history: relay-control and Desktop require the History origin (sessionReadApiPublicUrl) to be a bare origin (it is both the reader token audience and the base URL handed to clients), so a /history prefix cannot be expressed
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
  (list "history" "relay-control.services.relayhistoryPublicUrl" (dig "services" "relayhistoryPublicUrl" "" $cloudApi) (dig "control" true $components))
  (list "history" "relay-control.services.sessionReadApiPublicUrl" (dig "services" "sessionReadApiPublicUrl" "" $cloudApi) (dig "control" true $components))
  (list "history" "sessions-pipeline.alleyoop.auth.historyOrigin" (dig "alleyoop" "auth" "historyOrigin" "" $sessions) (dig "sessionsPipeline" true $components))
  (list "history" "sessions-pipeline.sessionReadApi.origin" (dig "sessionReadApi" "origin" "" $sessions) (and (dig "sessionsPipeline" true $components) (dig "sessionReadApi" "enabled" false $sessions)))
  (list "history" "sessions-pipeline.ingestEdge.origin" (dig "ingestEdge" "origin" "" $sessions) (and (dig "sessionsPipeline" true $components) (dig "ingestEdge" "enabled" false $sessions)))
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

{{- /* Control-owned relaygate policy: relaygate and relay-control read the
shared Secrets from global.relaygate.controlPolicy; this checks what a parent
can't derive for its children: the Control Service relaygate pulls from. */ -}}
{{- define "agent-relay.validateControlPolicy" -}}
{{- $cp := dig "relaygate" "controlPolicy" dict (.Values.global | default dict) | default dict -}}
{{- if dig "enabled" false $cp -}}
{{- if not (include "agent-relay.gateOnly" .) }}{{ fail "global.relaygate.controlPolicy.enabled requires global.relaygate.gateOnly.enabled: relay-control manages relaygate's policy only on gate-only installs" }}{{ end -}}
{{- if not (dig "control" true (.Values.components | default dict)) }}{{ fail "global.relaygate.controlPolicy.enabled requires components.control" }}{{ end -}}
{{- $control := index .Values "relay-control" | default dict -}}
{{- $controlService := dig "fullnameOverride" "" $control | default (printf "%s-%s" .Release.Name (dig "nameOverride" "" $control | default "relay-control")) | trunc 63 | trimSuffix "-" -}}
{{- $want := dig "controlServiceName" "" $cp | default (printf "%s-relay-control" .Release.Name | trunc 63 | trimSuffix "-") -}}
{{- if ne $want $controlService }}{{ fail (printf "global.relaygate.controlPolicy.controlServiceName must be the relay-control Service %s (relaygate pulls the policy from it)" $controlService) }}{{ end -}}
{{- if ne (int (dig "controlServicePort" 80 $cp)) (int (dig "service" "port" 80 $control)) }}{{ fail (printf "global.relaygate.controlPolicy.controlServicePort must equal relay-control.service.port (%v)" (dig "service" "port" 80 $control)) }}{{ end -}}
{{- end -}}
{{- end }}

{{- /* "true" when .name is a lowercase DNS name (RFC 1123 subdomain): at most
.max characters, each dot-separated label 1-63 letters, digits and inner
hyphens, so no empty label ("a..b") and no label starting or ending with "-". */ -}}
{{- define "agent-relay.isDnsName" -}}
{{- $name := toString .name -}}
{{- $ok := and $name (le (len $name) (int .max)) -}}
{{- range $l := splitList "." $name }}
{{- if not (and (le (len $l) 63) (regexMatch "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$" $l)) }}{{ $ok = false }}{{ end -}}
{{- end -}}
{{- if $ok }}true{{ end -}}
{{- end }}

{{- /* Compatibility default for upgrades whose saved values predate eksIngress.
Keep in step with values.yaml; the script/chart equivalence tests exercise both
normal defaults and the missing/null-key fallback, with Chief off and on. */ -}}
{{- define "agent-relay.eksDefaultControlPaths" -}}
{{- list "/cloud/api" "/login" "/relay-node" "/mcp" "/cloud/mcp"
  "/.well-known/oauth-protected-resource"
  "/.well-known/oauth-authorization-server"
  "/.well-known/openid-configuration"
  "/cloud/.well-known" "/cloud/oauth" | toJson -}}
{{- end -}}

{{- /* eksIngress: the primary edge's cast host and every edge's history host
(primary and extraEdges), for the gate checks. */ -}}
{{- define "agent-relay.eksPrimaryHost" -}}
{{- $e := .root.Values.eksIngress | default dict -}}
{{- with dig "domain" "" $e }}{{ ternary . (printf "%s.%s" $.role .) (eq $.role "dashboard") }}{{ else }}{{ dig "hosts" $.role "" $e }}{{ end -}}
{{- end }}

{{- define "agent-relay.eksHistoryHosts" -}}
{{- $e := .Values.eksIngress | default dict -}}
{{- $hosts := list -}}
{{- if and (eq (dig "enabled" false $e | toString) "true") (eq (dig "history" "enabled" false $e | toString) "true") }}
{{- $hosts = append $hosts (include "agent-relay.eksPrimaryHost" (dict "root" . "role" "history")) -}}
{{- range $x := dig "extraEdges" list $e | default list }}{{ if kindIs "map" $x }}{{ $hosts = append $hosts (dig "hosts" "history" "" $x) }}{{ end }}{{ end -}}
{{- end }}
{{- $hosts | toJson -}}
{{- end }}
