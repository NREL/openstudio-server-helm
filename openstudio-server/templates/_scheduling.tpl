{{- define "openstudio.providerName" -}}
{{- $global := default (dict) .Values.global -}}
{{- $globalProvider := default (dict) (get $global "provider") -}}
{{- $legacyProvider := default (dict) .Values.provider -}}
{{- $legacyProviderName := lower (default "" (get $legacyProvider "name")) -}}
{{- $allowLegacyProviderName := default false (get $globalProvider "allowLegacyName") -}}
{{- $provider := lower (default "" (get $globalProvider "name")) -}}
{{- if ne $legacyProviderName "" -}}
{{- if not $allowLegacyProviderName -}}
{{- fail "provider.name is deprecated and disabled by default. Set global.provider.name, or set global.provider.allowLegacyName=true temporarily during migration." -}}
{{- end -}}
{{- if and (ne $provider "") (ne $provider $legacyProviderName) -}}
{{- fail (printf "provider.name=%q conflicts with global.provider.name=%q. Remove provider.name and keep global.provider.name." $legacyProviderName $provider) -}}
{{- end -}}
{{- if eq $provider "" -}}
{{- $provider = $legacyProviderName -}}
{{- end -}}
{{- end -}}
{{- if eq $provider "" -}}
{{- fail "global.provider.name is required. Set one of: aws, google, azure, openstack." -}}
{{- end -}}
{{- if not (has $provider (list "aws" "google" "azure" "openstack")) -}}
{{- fail (printf "global.provider.name=%q is unsupported. Supported values: aws, google, azure, openstack." $provider) -}}
{{- end -}}
{{- $provider -}}
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

{{- define "openstudio.nodeGroupAffinityMode" -}}
{{- $nodeGroups := default (dict) .Values.global.nodeGroups -}}
{{- $mode := lower (default "" (get $nodeGroups "affinityMode")) -}}
{{- if ne $mode "" -}}
{{- if not (has $mode (list "required" "preferred" "disabled")) -}}
{{- fail (printf "global.nodeGroups.affinityMode=%q is unsupported. Supported values: required, preferred, disabled." $mode) -}}
{{- end -}}
{{- $mode -}}
{{- else if eq (include "openstudio.providerName" .) "openstack" -}}
{{- "preferred" -}}
{{- else -}}
{{- "required" -}}
{{- end -}}
{{- end -}}

{{- define "openstudio.nodeGroupAffinityModeForRole" -}}
{{- $nodeGroups := default (dict) .root.Values.global.nodeGroups -}}
{{- $roleKey := printf "%sAffinityMode" .role -}}
{{- $roleMode := lower (default "" (get $nodeGroups $roleKey)) -}}
{{- if ne $roleMode "" -}}
{{- if not (has $roleMode (list "required" "preferred" "disabled")) -}}
{{- fail (printf "global.nodeGroups.%s=%q is unsupported. Supported values: required, preferred, disabled." $roleKey $roleMode) -}}
{{- end -}}
{{- $roleMode -}}
{{- else -}}
{{- include "openstudio.nodeGroupAffinityMode" .root -}}
{{- end -}}
{{- end -}}

{{- define "openstudio.affinityForRole" -}}
{{- $mode := include "openstudio.nodeGroupAffinityModeForRole" . -}}
{{- if ne $mode "disabled" -}}
affinity:
  nodeAffinity:
    {{- if eq $mode "preferred" }}
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        preference:
          matchExpressions:
            - key: {{ include "openstudio.nodeGroupLabelKey" .root }}
              operator: In
              values:
                - {{ include "openstudio.nodeGroupValueForRole" . }}
    {{- else }}
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
        - matchExpressions:
            - key: {{ include "openstudio.nodeGroupLabelKey" .root }}
              operator: In
              values:
                - {{ include "openstudio.nodeGroupValueForRole" . }}
    {{- end }}
{{- end -}}
{{- end -}}

{{- define "openstudio.tolerationsForRole" -}}
{{- $mode := include "openstudio.nodeGroupAffinityModeForRole" . -}}
{{- if ne $mode "disabled" -}}
tolerations:
  - key: {{ include "openstudio.nodeGroupLabelKey" .root | quote }}
    operator: Equal
    value: {{ include "openstudio.nodeGroupValueForRole" . | quote }}
    effect: NoSchedule
{{- end -}}
{{- end -}}

{{- define "openstudio.defaultAppPersistenceStorageClass" -}}
{{- if eq (include "openstudio.providerName" .) "openstack" -}}
{{- "nfs" -}}
{{- else -}}
{{- "ssd" -}}
{{- end -}}
{{- end -}}

{{- define "openstudio.openstackBlockStorageClass" -}}
{{- $global := default (dict) .Values.global -}}
{{- $storageClasses := default (dict) (get $global "storageClasses") -}}
{{- default "csi-cinder" (get $storageClasses "block") -}}
{{- end -}}

{{- define "openstudio.defaultNfsProvisionerBackingStorageClass" -}}
{{- if eq (include "openstudio.providerName" .) "openstack" -}}
{{- include "openstudio.openstackBlockStorageClass" . -}}
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

{{- define "openstudio.dbName" -}}
{{- default "db" .Values.db.name -}}
{{- end -}}

{{- define "openstudio.redisName" -}}
{{- default "redis" .Values.redis.name -}}
{{- end -}}

{{- define "openstudio.nfsPvcName" -}}
{{- $nfsPvc := default (dict) (get .Values "nfs_pvc") -}}
{{- default "nfs-pvc" (get $nfsPvc "name") -}}
{{- end -}}

{{- define "openstudio.redisServiceName" -}}
{{- $redisSvc := default (dict) (get .Values "redis_svc") -}}
{{- default "queue" (get $redisSvc "name") -}}
{{- end -}}

{{- define "openstudio.webName" -}}
{{- default "web" .Values.web.name -}}
{{- end -}}

{{- define "openstudio.webServiceName" -}}
{{- $webSvc := default (dict) (get .Values "web_svc") -}}
{{- default (include "openstudio.webName" .) (get $webSvc "name") -}}
{{- end -}}

{{- define "openstudio.webBackgroundName" -}}
{{- default "web-background" .Values.web_background.name -}}
{{- end -}}

{{- define "openstudio.workerName" -}}
{{- default "worker" .Values.worker.name -}}
{{- end -}}

{{- define "openstudio.rserveName" -}}
{{- default "rserve" .Values.rserve.name -}}
{{- end -}}

{{- define "openstudio.rserveServiceName" -}}
{{- $rserveSvc := default (dict) (get .Values "rserve_svc") -}}
{{- default (include "openstudio.rserveName" .) (get $rserveSvc "name") -}}
{{- end -}}

{{- define "openstudio.webHpaName" -}}
{{- $webHpa := default (dict) (get .Values "web_hpa") -}}
{{- default (include "openstudio.webName" .) (get $webHpa "name") -}}
{{- end -}}

{{- define "openstudio.workerHpaName" -}}
{{- $workerHpa := default (dict) (get .Values "worker_hpa") -}}
{{- default (include "openstudio.workerName" .) (get $workerHpa "name") -}}
{{- end -}}

{{- define "openstudio.secretName" -}}
{{- $secrets := default (dict) .Values.secrets -}}
{{- $existingSecret := default "" (get $secrets "existingSecret") -}}
{{- $create := true -}}
{{- if hasKey $secrets "create" -}}
{{- $create = (get $secrets "create") -}}
{{- end -}}
{{- if and (ne $existingSecret "") $create -}}
{{- fail "secrets.existingSecret and secrets.create=true cannot both be set; choose one secret source" -}}
{{- end -}}
{{- if ne $existingSecret "" -}}
{{- $existingSecret -}}
{{- else -}}
{{- if not $create -}}
{{- fail "Either secrets.existingSecret must be set or secrets.create must be true" -}}
{{- end -}}
{{- default (printf "%s-app-secrets" .Release.Name) (get $secrets "nameOverride") -}}
{{- end -}}
{{- end -}}

{{- define "openstudio.secretKeyDbUsername" -}}
{{- $keys := default (dict) (get (default (dict) .Values.secrets) "keys") -}}
{{- default "db-username" (get $keys "dbUsername") -}}
{{- end -}}

{{- define "openstudio.secretKeyDbPassword" -}}
{{- $keys := default (dict) (get (default (dict) .Values.secrets) "keys") -}}
{{- default "db-password" (get $keys "dbPassword") -}}
{{- end -}}

{{- define "openstudio.secretKeyRedisPassword" -}}
{{- $keys := default (dict) (get (default (dict) .Values.secrets) "keys") -}}
{{- default "redis-password" (get $keys "redisPassword") -}}
{{- end -}}

{{- define "openstudio.secretKeyWebSecret" -}}
{{- $keys := default (dict) (get (default (dict) .Values.secrets) "keys") -}}
{{- default "web-secret-key" (get $keys "webSecret") -}}
{{- end -}}

{{- define "openstudio.serverImage" -}}
{{- $images := (get .Values.global "images") | default (dict) -}}
{{- $registry := include "openstudio.validatedRegistryHost" . -}}
{{- $repositoryPrefix := trimAll "/" (default "" (get $images "repositoryPrefix")) -}}
{{- $org := default "nrel" (get $images "org") -}}
{{- $repo := default "openstudio-server" (get $images "serverRepository") -}}
{{- $tag := default "latest" (get $images "tag") -}}
{{- $pathParts := list -}}
{{- if ne $repositoryPrefix "" -}}
{{- $pathParts = append $pathParts $repositoryPrefix -}}
{{- end -}}
{{- if ne $org "" -}}
{{- $pathParts = append $pathParts $org -}}
{{- end -}}
{{- $pathParts = append $pathParts $repo -}}
{{- $repositoryPath := join "/" $pathParts -}}
{{- if ne $registry "" -}}
{{- printf "%s/%s:%s" $registry $repositoryPath $tag -}}
{{- else -}}
{{- printf "%s:%s" $repositoryPath $tag -}}
{{- end -}}
{{- end -}}

{{- define "openstudio.rserveImage" -}}
{{- $images := (get .Values.global "images") | default (dict) -}}
{{- $registry := include "openstudio.validatedRegistryHost" . -}}
{{- $repositoryPrefix := trimAll "/" (default "" (get $images "repositoryPrefix")) -}}
{{- $org := default "nrel" (get $images "org") -}}
{{- $repo := default "openstudio-rserve" (get $images "rserveRepository") -}}
{{- $tag := default "latest" (get $images "tag") -}}
{{- $pathParts := list -}}
{{- if ne $repositoryPrefix "" -}}
{{- $pathParts = append $pathParts $repositoryPrefix -}}
{{- end -}}
{{- if ne $org "" -}}
{{- $pathParts = append $pathParts $org -}}
{{- end -}}
{{- $pathParts = append $pathParts $repo -}}
{{- $repositoryPath := join "/" $pathParts -}}
{{- if ne $registry "" -}}
{{- printf "%s/%s:%s" $registry $repositoryPath $tag -}}
{{- else -}}
{{- printf "%s:%s" $repositoryPath $tag -}}
{{- end -}}
{{- end -}}

{{- define "openstudio.workloadServiceAccountName" -}}
{{- $serviceAccount := default (dict) .Values.serviceAccount -}}
{{- default (printf "%s-workload" .Release.Name) (get $serviceAccount "name") -}}
{{- end -}}

{{- define "openstudio.validatedRegistryHost" -}}
{{- $images := (get .Values.global "images") | default (dict) -}}
{{- $registry := trimSuffix "/" (default "" (get $images "registry")) -}}
{{- if and (ne $registry "") (not (regexMatch ".*[.:].*" $registry)) -}}
{{- fail (printf "global.images.registry=%q is invalid. Use a registry host[:port] (for example 172.29.166.222:5000), not a bare namespace like 'zot'." $registry) -}}
{{- end -}}
{{- $registry -}}
{{- end -}}

{{- define "openstudio.imageWithRegistry" -}}
{{- $root := .root -}}
{{- $image := default "" .image -}}
{{- $images := (get $root.Values.global "images") | default (dict) -}}
{{- $registry := include "openstudio.validatedRegistryHost" $root -}}
{{- $repositoryPrefix := trimAll "/" (default "" (get $images "repositoryPrefix")) -}}
{{- if or (regexMatch "^(localhost|[^/]+[.:][^/]+)/.+" $image) (eq $registry "") -}}
{{- $image -}}
{{- else -}}
{{- $pathParts := list -}}
{{- if ne $repositoryPrefix "" -}}
{{- $pathParts = append $pathParts $repositoryPrefix -}}
{{- end -}}
{{- $pathParts = append $pathParts $image -}}
{{- printf "%s/%s" $registry (join "/" $pathParts) -}}
{{- end -}}
{{- end -}}

{{- define "openstudio.workloadServiceAccountUse" -}}
{{- $serviceAccount := default (dict) .Values.serviceAccount -}}
{{- if or (default false (get $serviceAccount "create")) (ne (default "" (get $serviceAccount "name")) "") -}}
true
{{- else -}}
false
{{- end -}}
{{- end -}}

{{- define "openstudio.podImagePullSecrets" -}}
{{- $global := default (dict) .Values.global -}}
{{- $imagePullSecrets := default (list) (get $global "imagePullSecrets") -}}
{{- if gt (len $imagePullSecrets) 0 -}}
imagePullSecrets:
{{- range $secretName := $imagePullSecrets }}
  - name: {{ $secretName | quote }}
{{- end }}
{{- end -}}
{{- end -}}

{{- define "openstudio.podHostAliases" -}}
{{- $hostAliases := default (dict) .Values.hostAliases -}}
{{- $enabled := default false (get $hostAliases "enabled") -}}
{{- $entries := default (list) (get $hostAliases "entries") -}}
{{- if and $enabled (gt (len $entries) 0) -}}
hostAliases:
{{- range $entry := $entries }}
  - ip: {{ default "" (get $entry "ip") | quote }}
    hostnames:
{{- range $hostname := default (list) (get $entry "hostnames") }}
      - {{ $hostname | quote }}
{{- end }}
{{- end }}
{{- end -}}
{{- end -}}

{{- define "openstudio.podNodeSelector" -}}
{{- $nodeSelector := default (dict) .nodeSelector -}}
{{- if gt (len $nodeSelector) 0 -}}
nodeSelector:
{{ toYaml $nodeSelector | nindent 2 }}
{{- end -}}
{{- end -}}

{{- define "openstudio.defaultWorkloadImagePullPolicy" -}}
{{- if eq (include "openstudio.providerName" .) "openstack" -}}
IfNotPresent
{{- else -}}
Always
{{- end -}}
{{- end -}}

{{- define "openstudio.workerAutoscalingMode" -}}
{{- $workerAutoscaling := default (dict) .Values.worker_autoscaling -}}
{{- $mode := lower (default "hpa" (get $workerAutoscaling "mode")) -}}
{{- if not (has $mode (list "hpa" "keda-hybrid")) -}}
{{- fail (printf "worker_autoscaling.mode=%q is unsupported. Supported values: hpa, keda-hybrid." $mode) -}}
{{- end -}}
{{- $mode -}}
{{- end -}}
