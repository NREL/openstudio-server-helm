{{/*
Return provider name with global-first precedence.
*/}}
{{- define "openstudio.providerName" -}}
{{- $globalValues := (get .Values "global" | default dict) -}}
{{- $globalProviderValues := (get $globalValues "provider" | default dict) -}}
{{- $globalProvider := (get $globalProviderValues "name" | default "") -}}
{{- if $globalProvider -}}
{{- $globalProvider -}}
{{- else -}}
{{- $providerValues := (get .Values "provider" | default dict) -}}
{{- get $providerValues "name" | default "" -}}
{{- end -}}
{{- end -}}
