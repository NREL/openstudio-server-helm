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
Parse a Kubernetes resource quantity string (e.g. "51396492Ki", "97Gi",
"4", "3800m", a plain byte count) into a float64 number of GiB.

Only handles the forms Node.status.allocatable actually reports in
practice for cpu/ephemeral-storage (bare integers, "m" millicores, and
binary Ki/Mi/Gi/Ti suffixes) -- not a general-purpose quantity parser
(no decimal K/M/G/T, no Pi/Ei, no negative/exponent forms).
*/}}
{{- define "openstudio.quantityToGi" -}}
{{- $q := trim (toString .) -}}
{{- $num := float64 (regexFind "^[0-9.]+" $q) -}}
{{- $unit := regexFind "[A-Za-z]+$" $q -}}
{{- if eq $unit "Ki" -}}
{{- divf $num 1048576.0 -}}
{{- else if eq $unit "Mi" -}}
{{- divf $num 1024.0 -}}
{{- else if eq $unit "Gi" -}}
{{- $num -}}
{{- else if eq $unit "Ti" -}}
{{- mulf $num 1024.0 -}}
{{- else if eq $unit "m" -}}
{{- divf $num 1000.0 -}}
{{- else -}}
{{- divf $num 1073741824.0 -}}
{{- end -}}
{{- end -}}

{{/*
Parse a Kubernetes CPU quantity string (e.g. "4", "3800m") into cores as a
float64.
*/}}
{{- define "openstudio.cpuToCores" -}}
{{- $q := trim (toString .) -}}
{{- if hasSuffix "m" $q -}}
{{- divf (float64 (trimSuffix "m" $q)) 1000.0 -}}
{{- else -}}
{{- float64 $q -}}
{{- end -}}
{{- end -}}

{{/*
Auto-computed per-worker emptyDir sizeLimit for the /mnt/openstudio scratch
mount, based on live cluster state read via `lookup` at the moment
"helm install"/"helm upgrade" runs against a real cluster.

IMPORTANT CAVEATS (read before enabling):
  - `lookup` only works when Helm is talking to a live cluster (a real
    install/upgrade). It returns nothing under "helm template" or "helm
    lint", so those always take the fallback path -- expected and safe,
    but means this can't be dry-run-verified without a live cluster.
  - This is a snapshot taken once per install/upgrade, not continuously
    recalculated. Resizing nodes or changing worker CPU requests only
    takes effect on your next "helm upgrade".
  - Assumes CPU requests are the binding constraint on how many workers
    the scheduler packs onto a node (true for this chart's worker sizing,
    but not a hard guarantee if other large pods share worker nodes).
  - Takes the minimum across all currently-labeled worker nodes, so mixed
    node sizes are handled safely (sized for your smallest worker node)
    but a first install before any worker nodes exist yet falls back too.

Formula per matching node:
  maxWorkersOnNode = max(1, floor(node allocatable cpu / worker cpu request))
  perWorkerGi      = (node allocatable ephemeral-storage * (1 - margin/100)) / maxWorkersOnNode

Only triggers when worker.container.emptyDirSizeLimit == "auto"; any other
value (including "", the default) is returned unchanged -- fully backward
compatible / opt-in.
*/}}
{{- define "openstudio.workerEmptyDirSizeLimit" -}}
{{- $configured := .Values.worker.container.emptyDirSizeLimit -}}
{{- if ne $configured "auto" -}}
{{- $configured -}}
{{- else -}}
{{- $fallback := default "8Gi" .Values.worker.container.emptyDirAutoFallback -}}
{{- $marginPercent := default 15.0 (float64 .Values.worker.container.emptyDirAutoMarginPercent) -}}
{{- $nodeGroup := default (dict) .Values.node_group -}}
{{- $labelKey := default "nodegroup" (get $nodeGroup "label_key") -}}
{{- $workerValue := default "worker-group" (get $nodeGroup "worker_value") -}}
{{- $cpuRequestCores := include "openstudio.cpuToCores" .Values.worker.container.resources.requests.cpu | float64 -}}
{{- $nodes := (lookup "v1" "Node" "" "") -}}
{{- $items := default list (default (dict) $nodes).items -}}
{{- $state := dict "minGi" 0.0 -}}
{{- range $node := $items -}}
{{- $labels := default (dict) $node.metadata.labels -}}
{{- if eq (get $labels $labelKey) $workerValue -}}
{{- $allocatable := default (dict) $node.status.allocatable -}}
{{- $diskQty := get $allocatable "ephemeral-storage" -}}
{{- $cpuQty := get $allocatable "cpu" -}}
{{- if and $diskQty $cpuQty (gt $cpuRequestCores 0.0) -}}
{{- $diskGi := include "openstudio.quantityToGi" $diskQty | float64 -}}
{{- $nodeCores := include "openstudio.cpuToCores" $cpuQty | float64 -}}
{{- $maxWorkers := max 1 (int (floor (divf $nodeCores $cpuRequestCores))) -}}
{{- $usableGi := mulf $diskGi (subf 1.0 (divf $marginPercent 100.0)) -}}
{{- $perWorkerGi := divf $usableGi (float64 $maxWorkers) -}}
{{- if or (eq $state.minGi 0.0) (lt $perWorkerGi $state.minGi) -}}
{{- $_ := set $state "minGi" $perWorkerGi -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- if eq $state.minGi 0.0 -}}
{{- $fallback -}}
{{- else -}}
{{- printf "%.0fGi" (floor $state.minGi) -}}
{{- end -}}
{{- end -}}
{{- end -}}
