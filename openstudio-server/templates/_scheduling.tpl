{{- define "openstudio.providerName" -}}
{{- default "" .Values.global.provider.name -}}
{{- end -}}

{{- define "openstudio.nodeGroupLabelKey" -}}
{{- $nodeGroups := default (dict) .Values.global.nodeGroups -}}
{{- $labelKey := default "" (get $nodeGroups "labelKey") -}}
{{- if ne $labelKey "" -}}
{{- $labelKey -}}
{{- else if eq (include "openstudio.providerName" .) "openstack" -}}
{{- "capi.stackhpc.com/node-group" -}}
{{- else -}}
{{- "nodegroup" -}}
{{- end -}}
{{- end -}}

{{- define "openstudio.webNodeGroupValue" -}}
{{- $nodeGroups := default (dict) .Values.global.nodeGroups -}}
{{- $web := default "" (get $nodeGroups "web") -}}
{{- if ne $web "" -}}
{{- $web -}}
{{- else if eq (include "openstudio.providerName" .) "openstack" -}}
{{- "web" -}}
{{- else -}}
{{- "web-group" -}}
{{- end -}}
{{- end -}}

{{- define "openstudio.workerNodeGroupValue" -}}
{{- $nodeGroups := default (dict) .Values.global.nodeGroups -}}
{{- $worker := default "" (get $nodeGroups "worker") -}}
{{- if ne $worker "" -}}
{{- $worker -}}
{{- else if eq (include "openstudio.providerName" .) "openstack" -}}
{{- "worker" -}}
{{- else -}}
{{- "worker-group" -}}
{{- end -}}
{{- end -}}

{{- define "openstudio.nodeGroupValueForRole" -}}
{{- if eq .role "worker" -}}
{{- include "openstudio.workerNodeGroupValue" .root -}}
{{- else -}}
{{- include "openstudio.webNodeGroupValue" .root -}}
{{- end -}}
{{- end -}}

{{- define "openstudio.affinityForRole" -}}
affinity:
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
        - matchExpressions:
            - key: {{ include "openstudio.nodeGroupLabelKey" .root }}
              operator: In
              values:
                - {{ include "openstudio.nodeGroupValueForRole" . }}
{{- end -}}

{{- define "openstudio.defaultAppPersistenceStorageClass" -}}
{{- if eq (include "openstudio.providerName" .) "openstack" -}}
{{- "nfs" -}}
{{- else -}}
{{- "ssd" -}}
{{- end -}}
{{- end -}}

{{- define "openstudio.defaultLoadBalancerExternalTrafficPolicy" -}}
{{- if eq (include "openstudio.providerName" .) "openstack" -}}
{{- "Cluster" -}}
{{- else -}}
{{- "Local" -}}
{{- end -}}
{{- end -}}

{{- define "openstudio.redisUrl" -}}
{{- printf "redis://:%s@queue:6379" .Values.redis.password -}}
{{- end -}}

{{- define "openstudio.serverImage" -}}
{{- $images := (get .Values.global "images") | default (dict) -}}
{{- $org := default "nrel" (get $images "org") -}}
{{- $repo := default "openstudio-server" (get $images "serverRepository") -}}
{{- $tag := default "latest" (get $images "tag") -}}
{{- printf "%s/%s:%s" $org $repo $tag -}}
{{- end -}}

{{- define "openstudio.rserveImage" -}}
{{- $images := (get .Values.global "images") | default (dict) -}}
{{- $org := default "nrel" (get $images "org") -}}
{{- $repo := default "openstudio-rserve" (get $images "rserveRepository") -}}
{{- $tag := default "latest" (get $images "tag") -}}
{{- printf "%s/%s:%s" $org $repo $tag -}}
{{- end -}}