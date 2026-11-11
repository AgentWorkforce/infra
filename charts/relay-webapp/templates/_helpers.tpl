{{- define "relay-webapp.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- define "relay-webapp.fullname" -}}
{{- if .Values.fullnameOverride }}{{ .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}{{ else }}{{ printf "%s-%s" .Release.Name (include "relay-webapp.name" .) | trunc 63 | trimSuffix "-" }}{{ end }}
{{- end -}}
{{- define "relay-webapp.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{ include "relay-webapp.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: agent-relay
{{- end -}}
{{- define "relay-webapp.selectorLabels" -}}
app.kubernetes.io/name: {{ include "relay-webapp.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
{{- define "relay-webapp.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}{{ default (include "relay-webapp.fullname" .) .Values.serviceAccount.name }}{{ else }}{{ default "default" .Values.serviceAccount.name }}{{ end }}
{{- end -}}
{{- define "relay-webapp.image" -}}
{{- $digest := required "image.digest is required; relay-webapp images must be pinned by sha256 digest" .Values.image.digest -}}
{{- if not (regexMatch "^sha256:[a-f0-9]{64}$" $digest) }}{{ fail "image.digest must be sha256:<64 lowercase hex characters>" }}{{ end -}}
{{- printf "%s@%s" .Values.image.repository $digest -}}
{{- end -}}
{{- /* Single-host mode (global.singleHost.host, set once on the agent-relay
umbrella): the dashboard and the control API share one host, so
runtime.publicUrl and ingress.host are derived from it, and the leaf Ingress
also routes /api (flows workers and the integrations OAuth callback call
<publicUrl>/api/v1/...) to the API. */ -}}
{{- define "relay-webapp.singleHost" -}}{{ dig "singleHost" "host" "" (.Values.global | default dict) }}{{- end -}}
{{- define "relay-webapp.publicUrl" -}}
{{- $single := include "relay-webapp.singleHost" . -}}
{{- if $single }}{{ printf "https://%s" $single }}{{ else }}{{ .Values.runtime.publicUrl }}{{ end -}}
{{- end -}}
{{- /* global.branding.logo: an operator logo served at <origin>/brand/<file>.
relay-control derives SELFHOST_LOGIN_LOGO_URL from the same value with the
same file name rule, so keep relay-control.brandLogoFile in step. */ -}}
{{- define "relay-webapp.brandLogo" -}}{{ toJson (dig "branding" "logo" dict (.Values.global | default dict) | default dict) }}{{- end -}}
{{- define "relay-webapp.brandLogoFile" -}}
{{- $logo := include "relay-webapp.brandLogo" . | fromJson -}}
{{- if $logo.svg }}logo.svg{{ else if $logo.existingConfigMap }}{{ $logo.key | default "logo.png" }}{{ end -}}
{{- end -}}
{{- define "relay-webapp.brandConfigMap" -}}
{{- $logo := include "relay-webapp.brandLogo" . | fromJson -}}
{{- if $logo.svg }}{{ printf "%s-brand" (include "relay-webapp.fullname" . | trunc 57 | trimSuffix "-") }}{{ else }}{{ $logo.existingConfigMap }}{{ end -}}
{{- end -}}
{{- define "relay-webapp.validateBrandLogo" -}}
{{- $raw := dig "branding" "logo" dict (.Values.global | default dict) -}}
{{- if not (or (kindIs "invalid" $raw) (kindIs "map" $raw)) }}{{ fail "global.branding.logo must be a map with svg, existingConfigMap or key" }}{{ end -}}
{{- $logo := $raw | default dict -}}
{{- range $k, $v := $logo }}{{ if not (has $k (list "svg" "existingConfigMap" "key")) }}{{ fail (printf "global.branding.logo.%s is not a setting (use svg, or existingConfigMap and key)" $k) }}{{ end }}{{ if not (or (kindIs "invalid" $v) (kindIs "string" $v)) }}{{ fail (printf "global.branding.logo.%s must be a string" $k) }}{{ end }}{{ end -}}
{{- if and $logo.svg $logo.existingConfigMap }}{{ fail "global.branding.logo: set svg or existingConfigMap, not both" }}{{ end -}}
{{- if and $logo.key (not $logo.existingConfigMap) }}{{ fail "global.branding.logo.key names a key in existingConfigMap; set existingConfigMap too (an inline svg is always served as logo.svg)" }}{{ end -}}
{{- with $logo.existingConfigMap }}{{ if or (gt (len .) 253) (not (regexMatch "^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$" .)) }}{{ fail "global.branding.logo.existingConfigMap must be a ConfigMap name in the release namespace" }}{{ end }}{{ end -}}
{{- /* existingConfigMap content is not linted, and images before relay-webapp
#132 serve /brand/ without a CSP, so a ConfigMap SVG could run script on the
dashboard origin when opened directly: only PNG is accepted there (served as
image/png with nosniff); an SVG goes inline, where it is checked. */ -}}
{{- with $logo.key }}{{ if or (gt (len .) 253) (not (regexMatch "^[A-Za-z0-9][A-Za-z0-9._-]*\\.png$" .)) }}{{ fail "global.branding.logo.key must be a file name of [A-Za-z0-9._-] ending in .png (an SVG logo goes inline in global.branding.logo.svg, where it is checked)" }}{{ end }}{{ end -}}
{{- with $logo.svg -}}
{{- if gt (len .) 262144 }}{{ fail "global.branding.logo.svg must be at most 256 KiB; use existingConfigMap for a larger file" }}{{ end -}}
{{- if not (regexMatch "(?i)<([^\\s<>/:]+:)?svg[\\s/>]" .) }}{{ fail "global.branding.logo.svg must be SVG markup (<svg ...>...</svg>)" }}{{ end -}}
{{- /* Browsers drop tabs and newlines inside URLs and decode character
references in attribute values, so match javascript: with whitespace between
its letters, match namespace-prefixed elements (<svg:script>), and refuse
character references and DTDs (entities) outright;
design-tool SVG needs neither. */ -}}
{{- if regexMatch "(?i)<([^\\s<>/:]+:)?(script|foreignobject)|j\\s*a\\s*v\\s*a\\s*s\\s*c\\s*r\\s*i\\s*p\\s*t\\s*:|[\\s/]on[a-z]+\\s*=|&#|<!doctype|<!entity" . }}{{ fail "global.branding.logo.svg must not contain script, event handler attributes, javascript: URLs, foreignObject, character references (&#...;) or a DOCTYPE/ENTITY declaration" }}{{ end -}}
{{- end -}}
{{- end -}}
{{- define "relay-webapp.ingressHost" -}}{{ include "relay-webapp.singleHost" . | default .Values.ingress.host }}{{- end -}}
{{- define "relay-webapp.validate" -}}
{{- $image := include "relay-webapp.image" . -}}
{{- if ne (int .Values.replicaCount) 1 }}{{ fail "replicaCount must be 1: the dashboard image serves one static replica and the chart makes no HA claim" }}{{ end -}}
{{- range $key, $_ := include "relay-webapp.selectorLabels" . | fromYaml }}{{ if hasKey ($.Values.podLabels | default dict) $key }}{{ fail (printf "podLabels must not set selector label %s: the Deployment selector would no longer match its pods" $key) }}{{ end }}{{ end -}}
{{- include "relay-webapp.validateBrandLogo" . -}}
{{- if ne .Values.service.type "ClusterIP" }}{{ fail "service.type must be ClusterIP; expose the dashboard only through ingress" }}{{ end -}}
{{- $single := include "relay-webapp.singleHost" . -}}
{{- if $single }}
{{- if or (gt (len $single) 253) (regexMatch "(^|\\.)[0-9]+$" $single) (not (regexMatch "^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)*[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$" $single)) }}{{ fail "global.singleHost.host must be a lowercase DNS hostname (no scheme, port or path; labels of 1-63 characters that start and end with a letter or digit, not an IP address)" }}{{ end -}}
{{- if and .Values.runtime.publicUrl (ne (trimSuffix "/" .Values.runtime.publicUrl) (printf "https://%s" $single)) }}{{ fail (printf "runtime.publicUrl is derived from global.singleHost.host (https://%s); leave it empty" $single) }}{{ end -}}
{{- if and .Values.ingress.host (ne .Values.ingress.host $single) }}{{ fail (printf "ingress.host is derived from global.singleHost.host (%s); leave it empty" $single) }}{{ end -}}
{{- $singleAppPath := trimSuffix "/" .Values.runtime.appPath -}}
{{- if or (eq $singleAppPath "/api") (hasPrefix "/api/" $singleAppPath) }}{{ fail "runtime.appPath must not be /api or under it in single-host mode: /api routes to the control API" }}{{ end -}}
{{- end -}}
{{- if not (regexMatch "^https://[^/?#]+$" (include "relay-webapp.publicUrl" .)) }}{{ fail "runtime.publicUrl must be an HTTPS origin with no path" }}{{ end -}}
{{- range $name, $path := dict "appPath" .Values.runtime.appPath "apiBasePath" .Values.runtime.apiBasePath "loginPath" .Values.runtime.loginPath }}{{ if not (regexMatch "^/[^?#]*$" $path) }}{{ fail (printf "runtime.%s must be an absolute path without query or fragment" $name) }}{{ end }}{{ end -}}
{{- /* The ingress routes apiBasePath and loginPath to the API and / to the
dashboard: "/" or a shared path would create duplicate Prefix paths with
different backends, which controllers reject or resolve unpredictably. */ -}}
{{- $appPath := trimSuffix "/" .Values.runtime.appPath -}}
{{- $apiPath := trimSuffix "/" .Values.runtime.apiBasePath -}}
{{- $loginPath := trimSuffix "/" .Values.runtime.loginPath -}}
{{- range $name, $path := dict "apiBasePath" $apiPath "loginPath" $loginPath }}{{ if not $path }}{{ fail (printf "runtime.%s must not be /: it would shadow the dashboard route" $name) }}{{ end }}{{ if eq $path $appPath }}{{ fail (printf "runtime.%s must differ from runtime.appPath" $name) }}{{ end }}{{ end -}}
{{- if eq $apiPath $loginPath }}{{ fail "runtime.apiBasePath and runtime.loginPath must differ" }}{{ end -}}
{{- if .Values.ingress.enabled -}}
{{- if not (include "relay-webapp.ingressHost" .) }}{{ fail "ingress.host is required when ingress.enabled=true" }}{{ end -}}
{{- if not (regexMatch "^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$" (include "relay-webapp.ingressHost" .)) }}{{ fail "ingress.host must be a DNS hostname" }}{{ end -}}
{{- if and (not .Values.ingress.externalTls) (empty .Values.ingress.tls) }}{{ fail "ingress.enabled=true requires ingress.tls unless externalTls=true" }}{{ end -}}
{{- if not .Values.api.serviceName }}{{ fail "api.serviceName is required when ingress.enabled=true: set it to the relay-control Service name (its fullname, <release>-relay-control unless fullnameOverride is set)" }}{{ end -}}
{{- if and .Values.networkPolicy.enabled (empty .Values.networkPolicy.ingressFrom) }}{{ fail "ingress with networkPolicy requires networkPolicy.ingressFrom" }}{{ end -}}
{{- end -}}
{{- end -}}
