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

{{/*
Optional container resources.limits block, rendered under an already-open
"resources:" key alongside the existing hardcoded "requests:" block.

Every deploy template already renders requests unconditionally; limits were
present in values.yaml for some roles (e.g. web) but never actually
templated, so they were silently ignored and every container ran with no
memory/CPU ceiling. This renders limits only when
.Values.<role>.container.resources.limits is set, so it's opt-in and
doesn't change behavior for anyone not setting it.

Usage (inside a container's already-open "resources:" block, after "requests:"):
  {{- include "openstudio.resourceLimits" .Values.web.container.resources.limits | nindent 12 }}
*/}}
{{- define "openstudio.resourceLimits" -}}
{{- if . }}
limits:
{{- if .cpu }}
  cpu: {{ .cpu }}
{{- end }}
{{- if .memory }}
  memory: {{ .memory }}
{{- end }}
{{- end }}
{{- end -}}

{{/*
Calculate web-background Resque worker count based on memory limit.

Logic:
  - Parse web_background.container.resources.limits.memory (e.g., "32Gi") to MiB
  - workers = floor(limit_mib / worker_memory_mib)
  - If no limit set or parsing fails: fall back to rserve.number_of_workers
  - Minimum 1 worker

Usage:
  {{- include "openstudio.webBackgroundWorkers" . | quote }}

Returns: integer as string
*/}}
{{- define "openstudio.parseMemoryToMiB" -}}
{{- $mem := . -}}
{{- if hasSuffix "Gi" $mem -}}
  {{- mul (int (trimSuffix "Gi" $mem)) 1024 -}}
{{- else if hasSuffix "Mi" $mem -}}
  {{- int (trimSuffix "Mi" $mem) -}}
{{- else if hasSuffix "G" $mem -}}
  {{- mul (int (trimSuffix "G" $mem)) 1000 -}}
{{- else if hasSuffix "M" $mem -}}
  {{- int (trimSuffix "M" $mem) -}}
{{- else -}}
  0
{{- end -}}
{{- end -}}

{{/*
Resolve a container image reference with an optional private registry prefix.

A reference is considered already-qualified (used as-is) when its first
path segment contains a "." or ":" — i.e. it has an explicit registry host
such as "registry.k8s.io/kubectl:v1.34.9" or
"mirror.example.com/my-prefix/nrel/openstudio-server:3.8.0-1".
A plain Docker Hub-style reference such as "bitnami/kubectl:latest" (first
segment "bitnami" has no "." or ":") is NOT qualified and gets the registry
prefix applied. Without this distinction the registry/repositoryPrefix would
be prepended unconditionally and produce broken double-prefixed references
such as:

  mirror.example.com/my-prefix/registry.k8s.io/kubectl:v1.34.9

Call with the root chart context so the helper can read the registry settings:

  {{- include "openstudio.imageWithRegistry" (dict "root" . "image" .Values.hooks.preDeleteCleanup.image) | quote }}
*/}}
{{- define "openstudio.imageWithRegistry" -}}
{{- $image := .image -}}
{{- $root := .root -}}
{{- $shouldRewrite := include "openstudio.localRegistryShouldRewrite" $root -}}
{{- $registry := $root.Values.global.images.registry -}}
{{- $prefix := $root.Values.global.images.repositoryPrefix -}}

{{- if eq $shouldRewrite "true" -}}
  {{- $localHost := include "openstudio.localRegistryHost" $root -}}
  {{- $hasRegistry := regexMatch "^[^/]+[.:][^/]*/.+" $image -}}
  {{- if $hasRegistry -}}
    {{- $image -}}
  {{- else -}}
    {{- printf "%s/%s" $localHost $image -}}
  {{- end -}}
{{- else if or (not $registry) (not $prefix) -}}
  {{- $image -}}
{{- else -}}
  {{- $hasRegistry := regexMatch "^[^/]+[.:][^/]*/.+" $image -}}
  {{- if $hasRegistry -}}
    {{- $image -}}
  {{- else -}}
    {{- printf "%s/%s/%s" $registry $prefix $image -}}
  {{- end -}}
{{- end -}}
{{- end -}}

{{/*
Check if local registry is enabled
*/}}
{{- define "openstudio.localRegistryEnabled" -}}
{{- $enabled := .Values.localRegistry.enabled -}}
{{- if kindIs "string" $enabled -}}
  {{- eq $enabled "true" -}}
{{- else -}}
  {{- $enabled -}}
{{- end -}}
{{- end -}}

{{/*
Check if local registry rewrite should happen (local registry enabled OR external hostname provided)
*/}}
{{- define "openstudio.localRegistryShouldRewrite" -}}
{{- $rewrite := .Values.localRegistry.rewriteImages -}}
{{- $rewriteBool := false -}}
{{- if kindIs "string" $rewrite -}}
  {{- $rewriteBool = eq $rewrite "true" -}}
{{- else -}}
  {{- $rewriteBool = $rewrite -}}
{{- end -}}
{{- if not $rewriteBool -}}
  false
{{- else -}}
  {{- $enabled := .Values.localRegistry.enabled -}}
  {{- $enabledBool := false -}}
  {{- if kindIs "string" $enabled -}}
    {{- $enabledBool = eq $enabled "true" -}}
  {{- else -}}
    {{- $enabledBool = $enabled -}}
  {{- end -}}
  {{- $hostname := .Values.localRegistry.hostname -}}
  {{- if or $enabledBool (and $hostname (ne $hostname "")) -}}
    true
  {{- else -}}
    false
  {{- end -}}
{{- end -}}
{{- end -}}

{{/*
Get the local registry host:port
*/}}
{{- define "openstudio.localRegistryHost" -}}
{{- $port := int .Values.localRegistry.port -}}
{{- if .Values.localRegistry.hostname -}}
{{- printf "%s:%d" .Values.localRegistry.hostname $port -}}
{{- else -}}
{{- printf "%s-localRegistry:%d" .Release.Name $port -}}
{{- end -}}
{{- end -}}

{{- define "openstudio.webBackgroundWorkers" -}}
{{- $wb := .Values.web_background -}}
{{- $rserve := .Values.rserve -}}
{{- $limits := $wb.container.resources.limits -}}
{{- if $limits.memory -}}
  {{- $limitMiB := include "openstudio.parseMemoryToMiB" $limits.memory -}}
  {{- if gt (int $limitMiB) 0 -}}
    {{- $workers := div (int $limitMiB) (int $wb.worker_memory_mib) -}}
    {{- if lt $workers 1 -}}1{{- else -}}{{ $workers }}{{- end -}}
  {{- else -}}
    {{ $rserve.number_of_workers }}
  {{- end -}}
{{- else -}}
  {{ $rserve.number_of_workers }}
{{- end -}}
{{- end -}}