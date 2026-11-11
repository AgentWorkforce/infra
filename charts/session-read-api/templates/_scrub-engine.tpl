{{/* Shared scrub-engine contract inherited from the umbrella's global values. */}}
{{- define "session-read-api.scrubEngine" -}}
{{- $global := .root.Values.global | default dict -}}
{{- $s := dict -}}
{{- if hasKey $global "scrubEngine" }}{{ $s = get $global "scrubEngine" }}{{ end -}}
{{- if not (kindIs "map" $s) }}{{ fail "global.scrubEngine must be an object" }}{{ end -}}
{{- $engine := get $s "engine" -}}
{{- $required := get $s "required" -}}
{{- $reader := get $s "readerMaxRuleset" -}}
{{- if or (not (kindIs "string" $engine)) (not (has $engine (list "" "wasm-bindgen"))) }}{{ fail "global.scrubEngine.engine must be empty or wasm-bindgen" }}{{ end -}}
{{- if or (not (kindIs "string" $required)) (not (has $required (list "" "wasm-bindgen"))) }}{{ fail "global.scrubEngine.required must be empty or wasm-bindgen" }}{{ end -}}
{{- if or (not (kindIs "string" $reader)) (not (has $reader (list "" "8" "9" "10"))) }}{{ fail "global.scrubEngine.readerMaxRuleset must be empty or the string 8, 9, or 10" }}{{ end -}}
{{- if and $required (ne $required $engine) }}{{ fail "global.scrubEngine.required must be empty or equal global.scrubEngine.engine" }}{{ end -}}
{{- if and (eq $engine "wasm-bindgen") (ne $reader "10") }}{{ fail "global.scrubEngine.engine=wasm-bindgen requires global.scrubEngine.readerMaxRuleset=\"10\"" }}{{ end -}}
{{- $local := .localReader -}}
{{- if not (kindIs "invalid" $local) -}}
{{- if not (has (toString $local) (list "8" "9" "10")) }}{{ fail (printf "%s must be one of 8, 9, or 10" .localName) }}{{ end -}}
{{- if and $reader (ne $reader (toString $local)) }}{{ fail (printf "%s must equal global.scrubEngine.readerMaxRuleset when both are set" .localName) }}{{ end -}}
{{- end -}}
{{- $effectiveReader := $reader -}}
{{- if and (not $effectiveReader) (not (kindIs "invalid" $local)) }}{{ $effectiveReader = toString $local }}{{ end -}}
{{- if $engine }}
- { name: SCRUB_ENGINE, value: {{ $engine | quote }} }
{{- end }}
{{- if $required }}
- { name: SCRUB_ENGINE_REQUIRED, value: {{ $required | quote }} }
{{- end }}
{{- if $effectiveReader }}
- { name: READER_MAX_RULESET, value: {{ $effectiveReader | quote }} }
{{- end }}
{{- end -}}
