{{/*
Render the /etc/exports body for the kernel NFS server (see
templates/nfs/nfs-kernel-configmap.yaml). Kept here so the export options
have exactly one home next to their rationale.

Usage:
  {{ include "openstudio.nfsKernelExports" . }}
*/}}
{{- define "openstudio.nfsKernelExports" -}}
/export *(rw,async,insecure,no_subtree_check,no_root_squash)
{{- end -}}

{{/*
Render the nfsd supervisor script for the kernel NFS server (mounted from
the exports ConfigMap and started via the container's `command:` override --
the pinned image's stock entrypoint hardcodes v4-only/8 threads).

Fixed ports mirror the legacy Ganesha Service contract:
  2049 nfsd | 111 rpcbind | 662 statd slot (unused; no rpc.statd in image,
  NSM notify is superseded by the recycle-clients-after-restart runbook
  rule) | 20048 mountd | 32803 nlockmgr (kernel-side, pinned by the init
  container).

Usage:
  {{ include "openstudio.nfsKernelStartScript" . }}
*/}}
{{- define "openstudio.nfsKernelStartScript" -}}
#!/bin/sh
set -eu

THREADS="{{ .Values.nfsKernelServer.threads }}"

log() { echo "[nfsd] $*"; }

log "ensuring nfsd filesystem is mounted"
mkdir -p /proc/fs/nfsd
if ! grep -q 'nfsd /proc/fs/nfsd' /proc/mounts 2>/dev/null; then
    mount -t nfsd nfsd /proc/fs/nfsd
fi

# hostNetwork mode only: the node may already run its own rpcbind/statd
# (Ubuntu nfs-common defaults). A foreign rpcbind on :111 makes our mountd's
# registrations invisible to clients (or fails outright). Stop the node's
# copies -- on a k8s worker nothing else uses them.
if [ -d /host/systemd ] || nsenter -t 1 -m -u -i -n true 2>/dev/null; then
    log "stopping node-level rpcbind/statd (conflict with NFS stack)"
    for unit in rpcbind.socket rpcbind rpc-statd rpc-statd-notify; do
        nsenter -t 1 -m -u -i -n systemctl stop "$unit" 2>/dev/null || true
        nsenter -t 1 -m -u -i -n systemctl disable "$unit" 2>/dev/null || true
    done
fi

mkdir -p /var/lib/nfs/sm /var/lib/nfs/sm.bak
# Some images ship these as pre-existing FILES (gists 2.6.4 does), which would
# make plain `mkdir -p` fail fatally -- tolerate both forms.
[ -d /var/lib/nfs/state ] || touch /var/lib/nfs/state
[ -f /var/lib/nfs/etab ] || touch /var/lib/nfs/etab
[ -f /var/lib/nfs/rmtab ] || touch /var/lib/nfs/rmtab

PIDS=""
on_term() {
    log "shutting down"
    /usr/sbin/rpc.nfsd 0 2>/dev/null || true
    for p in $PIDS; do kill "$p" 2>/dev/null || true; done
    exit 0
}
trap on_term TERM INT HUP

log "starting rpcbind"
/sbin/rpcbind -w

# THE LOCKD REGISTRATION FIX (2026-08-23 fleet-wide wedge): the init
# container modprobes lockd BEFORE this script's rpcbind exists, so lockd
# registers nlockmgr(100021) with whichever rpcbind is live at that instant
# -- the node's own (stopped two steps above) or nothing. Our fresh rpcbind
# therefore has NO nlockmgr entry: clients' GETPORT(100021) finds nothing and
# every flock()/fcntl() over NFS hangs forever in rpc_wait_bit_killable,
# which froze the whole worker fleet mid-benchmark (sims run fine until their
# completion path takes its first file lock, ~1h in -- looks like a hang, not
# an error). Fix: reload the module NOW, with our rpcbind listening, so the
# registration lands where clients can find it. On a clean boot no mount
# exists yet, so the unload always succeeds; if clients are already attached
# and the unload fails, fail loudly and let k8s restart us instead of
# silently wedging every workload again.
# NOTE: this image ships rpcinfo at /sbin/rpcinfo (NOT /usr/sbin).
RPCINFO="$(command -v rpcinfo || echo /sbin/rpcinfo)"
if ! "$RPCINFO" -p 127.0.0.1 | grep -q '100021'; then
    log "re-registering lockd against our rpcbind (nlm ports 32803)"
    if modprobe -r lockd 2>/dev/null; then
        modprobe lockd nlm_tcpport=32803 nlm_udpport=32803 || true
    fi
fi
if ! "$RPCINFO" -p 127.0.0.1 | grep -q '100021'; then
    # lockd could not be reloaded (builtin kernel, or refcounted by live NFS
    # mounts on this node). Inject the six PMAP entries directly -- the same
    # table rows kernel lockd would have created at first load.
    log "lockd reload unavailable; injecting nlockmgr rpcbind entries via pmap-set helper"
    python3 /scripts/pmap-set-nlm.py || true
fi
if ! "$RPCINFO" -p 127.0.0.1 | grep -q '100021'; then
    log "FATAL: nlockmgr still not registered -- refusing to serve NLM-less NFS"
    exit 1
fi
log "nlockmgr registered: $("$RPCINFO" -p 127.0.0.1 | grep 100021 | tr -s ' ' | tr '\n' ';')"

# Node-level statd was stopped above; NLM lock RECOVERY (SM_NOTIFY after a
# server/client crash) needs one running against OUR rpcbind. --no-notify
# skips the startup notification storm (clients are recycled after every
# server restart per the storage contract anyway).
log "starting rpc.statd"
/usr/sbin/rpc.statd --no-notify &
PIDS="$PIDS $!"

log "re-reading /etc/exports"
/usr/sbin/exportfs -r

log "starting rpc.mountd on 20048"
/usr/sbin/rpc.mountd -F -p 20048 &
PIDS="$!"

log "starting rpc.nfsd: v3-only, ${THREADS} threads"
# NOTE: no "-N 2" -- some nfs-utils builds (incl. this image) don't compile
# NFSv2 at all and abort with "Unsupported version" on -N 2.
/usr/sbin/rpc.nfsd -N 4 -N 4.1 -N 4.2 "$THREADS"

log "ready; active exports:"
/usr/sbin/exportfs -v

# Supervise until signalled; kernel nfsd threads keep serving while we live.
# If rpc.mountd ever dies, take the whole pod down so probes/k8s restart us.
while :; do
    sleep 5
    kill -0 "$PIDS" 2>/dev/null || { log "rpc.mountd died; exiting"; exit 1; }
done
{{- end -}}

{{/*
Full name of the kernel-NFS-server Deployment/Service/PVC/PV family
(templates/nfs/nfs-kernel-*.yaml), rendered only when provider.name ==
"openstack" AND .Values.nfsKernelServer.enabled -- see values.yaml.

Usage:
  {{ include "openstudio.nfsKernelFullname" . }}
*/}}
{{- define "openstudio.nfsKernelFullname" -}}
{{- printf "%s-%s" .Release.Name (default "nfs-kernel" .Values.nfsKernelServer.nameSuffix) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

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
{{- printf "%s-local-registry:%d" .Release.Name $port -}}
{{- end -}}
{{- end -}}

{{/*
Check if the containerd node-level registry config DaemonSet should be
deployed. Auto-enabled whenever the local registry rewrite is active (so
enabling localRegistry "just works" without a second flag to remember), but
can also be forced on/off explicitly via containerdRegistryConfig.enabled
for cases with only extraMirrors and no local registry.
*/}}
{{- define "openstudio.containerdRegistryConfigEnabled" -}}
{{- $explicit := .Values.containerdRegistryConfig.enabled -}}
{{- $explicitBool := false -}}
{{- if kindIs "string" $explicit -}}
  {{- $explicitBool = eq $explicit "true" -}}
{{- else -}}
  {{- $explicitBool = $explicit -}}
{{- end -}}
{{- $rewrite := include "openstudio.localRegistryShouldRewrite" . -}}
{{- if or $explicitBool (eq $rewrite "true") -}}
true
{{- else -}}
false
{{- end -}}
{{- end -}}

{{/*
Render the shell commands that write each containerd certs.d/hosts.toml
entry this DaemonSet is responsible for: the auto-derived local-registry
entry (from openstudio.localRegistryHost -- the exact same
localRegistry.hostname/port values imageWithRegistry already uses, so the
IP/host is never configured twice) plus any user-supplied
containerdRegistryConfig.extraMirrors entries.

Intentionally emits plain shell text (not a data structure round-tripped
through YAML) since the entries are static at Helm render time -- simplest
thing that works.

Usage (inside a shell script body):
  {{- include "openstudio.containerdRegistryConfigScript" . }}
*/}}
{{- define "openstudio.containerdRegistryConfigScript" -}}
{{- $root := . -}}
{{- $shouldRewrite := include "openstudio.localRegistryShouldRewrite" $root -}}
{{- if eq $shouldRewrite "true" -}}
{{- $localHost := include "openstudio.localRegistryHost" $root }}
D="/host/etc/containerd/certs.d/{{ $localHost }}"
mkdir -p "$D"
cat > "$D/hosts.toml" <<'HT'
server = "http://{{ $localHost }}"

[host."http://{{ $localHost }}"]
  capabilities = ["pull", "resolve", "push"]
  skip_verify = true
HT
{{ end -}}
{{- range $root.Values.containerdRegistryConfig.extraMirrors }}
{{- $caps := default (list "pull" "resolve") .capabilities }}
D="/host/etc/containerd/certs.d/{{ .host }}"
mkdir -p "$D"
cat > "$D/hosts.toml" <<'HT'
server = "{{ .server }}"

[host."{{ .mirror }}"]
  capabilities = [{{ range $i, $c := $caps }}{{ if $i }}, {{ end }}"{{ $c }}"{{ end }}]
{{- if .skip_verify }}
  skip_verify = true
{{- end }}
HT
{{ end -}}
{{- end -}}

{{/*
Compute the deduplicated list of fully-resolved (registry-rewritten) images
that this release's own workloads will pull on web/worker nodes: db, redis,
rserve, web, web_background, worker, plus any
containerdRegistryConfig.prewarmImages.extraImages. Reuses
openstudio.imageWithRegistry so this list is always consistent with what
each Deployment template actually renders as its image -- no separate list
to keep in sync by hand.

Usage:
  {{- include "openstudio.prewarmImageList" . }}
Returns one image ref per line.
*/}}
{{- define "openstudio.prewarmImageList" -}}
{{- $root := . -}}
{{- $images := list -}}
{{- $images = append $images (include "openstudio.imageWithRegistry" (dict "root" $root "image" $root.Values.db.container.image)) -}}
{{- $images = append $images (include "openstudio.imageWithRegistry" (dict "root" $root "image" $root.Values.redis.container.image)) -}}
{{- $images = append $images (include "openstudio.imageWithRegistry" (dict "root" $root "image" $root.Values.rserve.container.image)) -}}
{{- $images = append $images (include "openstudio.imageWithRegistry" (dict "root" $root "image" $root.Values.web.container.image)) -}}
{{- $images = append $images (include "openstudio.imageWithRegistry" (dict "root" $root "image" $root.Values.web_background.container.image)) -}}
{{- $images = append $images (include "openstudio.imageWithRegistry" (dict "root" $root "image" $root.Values.worker.container.image)) -}}
{{- range $root.Values.containerdRegistryConfig.prewarmImages.extraImages -}}
  {{- $images = append $images . -}}
{{- end -}}
{{- range ($images | uniq) }}
{{ . }}
{{- end -}}
{{- end -}}

{{/*
Render the shell commands that pre-pull (warm) every image from
openstudio.prewarmImageList directly into containerd's content store via
`ctr`, bypassing kubelet's image manager (and its
registryPullQPS/registryBurst/serializeImagePulls throttling) entirely --
see the long comment on containerdRegistryConfig.prewarmImages in
values.yaml for why that throttle matters.

Usage (inside a shell script body):
  {{- include "openstudio.prewarmImagesScript" . }}
*/}}
{{- define "openstudio.prewarmImagesScript" -}}
{{- $root := . -}}
{{- $sock := $root.Values.containerdRegistryConfig.prewarmImages.containerdSockPath -}}
{{- $ctr := $root.Values.containerdRegistryConfig.prewarmImages.ctrBinaryPath -}}
{{- $region := $root.Values.containerdRegistryConfig.prewarmImages.ecrRegion | default "us-west-2" -}}
{{/*
2026-08-19: previously invoked /host/usr/bin/aws and /host<ctr> directly via
ld-linux with --library-path /host/lib64. On AL2023 nodes /usr/bin/aws is an
*absolute* symlink (-> /usr/local/aws-cli/v2/current/bin/aws), which resolves
against the container's own root, not /host, when accessed as
/host/usr/bin/aws -- producing "cannot open shared object file" and silently
falling through to unauthenticated pulls (which then 403 on ECR's private
repos: "no basic auth credentials"). `chroot /host <path>` makes the target
binary resolve symlinks against /host as its root, exactly like the running
node would, without needing to fight relocated dynamic linker paths.
*/}}
CTR="chroot /host {{ $ctr }} --address {{ $sock }} -n k8s.io"
echo "Obtaining ECR auth token..."
ECR_PASSWORD=$(chroot /host /usr/bin/aws ecr get-login-password --region {{ $region }} 2>&1) && ECR_OK=1 || { echo "WARNING: failed to get ECR token ($ECR_PASSWORD), trying without auth"; ECR_PASSWORD=""; ECR_OK=0; }
{{- range (include "openstudio.prewarmImageList" $root | trim | splitList "\n") }}
{{- if . }}
echo "pre-warming image {{ . }}"
if [ "$ECR_OK" = "1" ]; then
  $CTR images pull --user "AWS:$ECR_PASSWORD" {{ . }} || echo "WARNING: pre-warm failed for {{ . }} (non-fatal, kubelet will still pull normally)"
else
  $CTR images pull {{ . }} || echo "WARNING: pre-warm failed for {{ . }} (non-fatal, kubelet will still pull normally)"
fi
{{- end }}
{{- end }}
{{- end -}}

{{/*
Check if image pre-warming (direct-to-containerd ctr pull, bypassing
kubelet's pull throttle) should be enabled. Requires both the containerd
registry config DaemonSet itself being enabled (prewarming needs somewhere
to run) and containerdRegistryConfig.prewarmImages.enabled being true.
*/}}
{{- define "openstudio.prewarmImagesEnabled" -}}
{{- $dsEnabled := include "openstudio.containerdRegistryConfigEnabled" . -}}
{{- $explicit := .Values.containerdRegistryConfig.prewarmImages.enabled -}}
{{- $explicitBool := false -}}
{{- if kindIs "string" $explicit -}}
  {{- $explicitBool = eq $explicit "true" -}}
{{- else -}}
  {{- $explicitBool = $explicit -}}
{{- end -}}
{{- if and (eq $dsEnabled "true") $explicitBool -}}
true
{{- else -}}
false
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