#!/bin/sh
# Entrypoint for the self-hosted kernel NFS server image (see Dockerfile).
# Mirrors the behavior the chart expects from gists/nfs-server: read
# /etc/exports (ConfigMap-mounted), start rpcbind -> statd -> mountd ->
# nfsd, stay in foreground, tear everything down cleanly on SIGTERM.
set -eu

THREADS="${NFS_SERVER_THREAD_COUNT:-8}"
MOUNTD_PORT="${NFS_PORT_MOUNTD:-20048}"
STATD_IN="${NFS_PORT_STATD_IN:-662}"
STATD_OUT="${NFS_PORT_STATD_OUT:-662}"

log() { echo "[nfs-server] $*"; }

# --- kernel prerequisites ---------------------------------------------------
modprobe nfsd 2>/dev/null || true
modprobe lockd nlm_tcpport=32803 nlm_udpport=32803 2>/dev/null || true
sysctl -w fs.nfs.nlm_tcpport=32803 >/dev/null 2>&1 || true
sysctl -w fs.nfs.nlm_udpport=32803 >/dev/null 2>&1 || true

mkdir -p /proc/fs/nfsd
if ! mountpoint -q /proc/fs/nfsd; then
    mount -t nfsd nfsd /proc/fs/nfsd
fi

mkdir -p /var/lib/nfs/sm /var/lib/nfs/sm.bak
touch /var/lib/nfs/state /var/lib/nfs/etab /var/lib/nfs/rmtab

# --- daemons ----------------------------------------------------------------
PIDS=""

cleanup() {
    log "shutting down"
    for p in $PIDS; do kill "$p" 2>/dev/null || true; done
    rpc.nfsd 0 2>/dev/null || true
    exit 0
}
trap cleanup TERM INT

log "starting rpcbind"
rpcbind -w

log "starting rpc.statd (in=$STATD_IN out=$STATD_OUT)"
rpc.statd --no-notify -p "$STATD_IN" -o "$STATD_OUT" & PIDS="$PIDS $!"

exportfs -ra

log "starting rpc.mountd on port $MOUNTD_PORT"
rpc.mountd -F -p "$MOUNTD_PORT" & PIDS="$PIDS $!"

if [ "${NFS_VERSION:-3}" = "3" ]; then
    V4_FLAGS="-N 4 -N 4.1 -N 4.2"
else
    V4_FLAGS=""
fi

log "starting rpc.nfsd with $THREADS threads (v3-only flags: $V4_FLAGS)"
rpc.nfsd $V4_FLAGS "$THREADS"

log "ready: exports:"
exportfs -v

# Stay alive as supervisor; kernel nfsd threads keep serving while we run.
while sleep 5; do
    :
done
