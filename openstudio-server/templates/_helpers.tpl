{{/*
Node-group scheduling affinity, shared by web-role (web, web-background, db,
redis, rserve) and worker-role deployments.

Defaults match this chart's original hardcoded behavior exactly (label key
"nodegroup", values "web-group"/"worker-group", required affinity) so
existing AWS/GCP/Azure installs are unaffected. Override via .Values.node_group
for environments with different native node labels (e.g. Azimuth/Cluster API
clusters label nodes "capi.stackhpc.com/node-group: web|worker" instead) or
that need "preferred" instead of "required" affinity, e.g. because
autoscaled nodes may take a moment to receive their label after joining.

Usage:
  affinity:
    {{- include "openstudio.nodeGroupAffinity" (dict "root" . "role" "web") | nindent 4 }}
*/}}
{{- define "openstudio.nodeGroupAffinity" -}}
{{- $root := .root -}}
{{- $nodeGroup := default (dict) $root.Values.node_group -}}
{{- $labelKey := default "nodegroup" (get $nodeGroup "label_key") -}}
{{- $defaultValueKey := printf "%s_value" .role -}}
{{- $defaultValue := printf "%s-group" .role -}}
{{- $value := default $defaultValue (get $nodeGroup $defaultValueKey) -}}
{{- $mode := default "required" (get $nodeGroup "affinity_mode") -}}
nodeAffinity:
{{- if eq $mode "preferred" }}
  preferredDuringSchedulingIgnoredDuringExecution:
    - weight: 100
      preference:
        matchExpressions:
          - key: {{ $labelKey }}
            operator: In
            values:
              - {{ $value }}
{{- else }}
  requiredDuringSchedulingIgnoredDuringExecution:
    nodeSelectorTerms:
      - matchExpressions:
          - key: {{ $labelKey }}
            operator: In
            values:
              - {{ $value }}
{{- end }}
{{- end -}}
