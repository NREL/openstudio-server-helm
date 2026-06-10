{{- define "openstudio.appSecretName" -}}
{{- $secrets := default (dict) .Values.secrets -}}
{{- $existingSecret := default "" (get $secrets "existingSecret") -}}
{{- if ne $existingSecret "" -}}
{{- $existingSecret -}}
{{- else -}}
{{- $secretNameOverride := default "" (get $secrets "nameOverride") -}}
{{- default (printf "%s-app-secrets" .Release.Name) $secretNameOverride -}}
{{- end -}}
{{- end -}}

{{- define "openstudio.appSecretKey.dbUsername" -}}
{{- $secrets := default (dict) .Values.secrets -}}
{{- $keys := default (dict) (get $secrets "keys") -}}
{{- default "db-username" (get $keys "dbUsername") -}}
{{- end -}}

{{- define "openstudio.appSecretKey.dbPassword" -}}
{{- $secrets := default (dict) .Values.secrets -}}
{{- $keys := default (dict) (get $secrets "keys") -}}
{{- default "db-password" (get $keys "dbPassword") -}}
{{- end -}}

{{- define "openstudio.appSecretKey.redisPassword" -}}
{{- $secrets := default (dict) .Values.secrets -}}
{{- $keys := default (dict) (get $secrets "keys") -}}
{{- default "redis-password" (get $keys "redisPassword") -}}
{{- end -}}

{{- define "openstudio.appSecretKey.webSecret" -}}
{{- $secrets := default (dict) .Values.secrets -}}
{{- $keys := default (dict) (get $secrets "keys") -}}
{{- default "web-secret-key" (get $keys "webSecret") -}}
{{- end -}}
