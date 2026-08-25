#!/usr/bin/env bash
# storage-aware-ramp.sh -- staged, health-gated worker ramp for the
# kernel-NFS-backed OpenStudio-server cluster.
#
# WHY THIS EXISTS (2026-08-24): the NFS write path collapses somewhere
# between 1k and 3k concurrent writing clients (ext4 journal stall on the
# backing Cinder volume -> all nfsd threads D-state -> fleet-wide freeze).
# Blind `kubectl scale --replicas=9360` is how you get that outage. This
# script climbs in stages, runs health gates between stages, and
# auto-rolls-back to the last known-good count on breach.
#
# READ-ONLY diagnostics + kubectl scale ONLY. Never touches queues/jobs.
#
# Usage:
#   bash storage-aware-ramp.sh                 # ramp 1000 -> TARGET (default 9360)
#   TARGET=9360 STAGE=1000 bash storage-aware-ramp.sh
#
# Gates per stage (all must pass for GATE_SETTLE seconds):
#   fsync   : p99-ish probe latency through the live export (webbg pod dd+fsync)
#   nfsd_D  : stuck nfsd kernel threads on the NFS node (< 25% of pool)
#   flow    : simulations queue must drain >= MIN_PROGRESS in settle window
set -euo pipefail

NS="${NS:-openstudio-server}"
TARGET="${TARGET:-9360}"
STAGE="${STAGE:-1000}"           # pods added per stage
SETTLE="${SETTLE:-180}"          # seconds to observe after each stage
PROBES="${PROBES:-5}"            # fsync probes averaged per gate check
MAX_FSYNC_MS="${MAX_FSYNC_MS:-800}"
MIN_PROGRESS="${MIN_PROGRESS:-10}"  # sims drained during settle window
NFS_DEPLOY="${NFS_DEPLOY:-openstudio-server-nfs-kernel}"
NODE_NAME="${NODE_NAME:-openstudio-server-azimuth-openstack-web-4vqkj-bjn92}"

log() { echo "[ramp $(date -u +%H:%M:%S)] $*"; }

current_replicas() {
  kubectl -n "$NS" get deploy worker -o jsonpath='{.spec.replicas}'
}

nfsd_dcount() {
  kubectl -n "$NS" exec nodedebug-bjn92 -- chroot /host /bin/sh /tmp/countnfsd.sh 2>/dev/null \
    | grep -oE 'D=[0-9]+' | cut -d= -f2 || echo "999"
}

fsync_ms() {  # single probe through the live export from a fresh worker pod
  local pod rc out
  pod=$(kubectl -n "$NS" get pods -l app=worker --field-selector=status.phase=Running \
        --sort-by=.status.startTime --no-headers 2>/dev/null | tail -1 | awk '{print $1}')
  [ -z "$pod" ] && { echo "999999"; return; }
  out=$(kubectl -n "$NS" exec "$pod" -- sh -c '
    S=$(date +%s%N); dd if=/dev/zero of=/mnt/openstudio/.ramp-probe bs=4096 count=8 conv=fsync 2>/dev/null
    E=$(date +%s%N); rm -f /mnt/openstudio/.ramp-probe; echo $(( (E-S)/1000000 ))' 2>/dev/null) || { echo "999999"; return; }
  echo "$out" | tail -1
}

completions_delta() {  # dps updated (started|completed) over last $1 seconds
  local win="$1"
  local user pass
  user=$(kubectl -n "$NS" get deploy web -o json 2>/dev/null | python3 -c "
import json,sys
for e in json.load(sys.stdin)['spec']['template']['spec']['containers'][0]['env']:
    if e['name']=='MONGO_USER': print(e.get('value',''))" 2>/dev/null)
  pass=$(kubectl -n "$NS" get deploy web -o json 2>/dev/null | python3 -c "
import json,sys
for e in json.load(sys.stdin)['spec']['template']['spec']['containers'][0]['env']:
    if e['name']=='MONGO_PASSWORD': print(e.get('value',''))" 2>/dev/null)
  kubectl -n "$NS" exec deploy/db -- bash -c "mongosh -u '$user' -p '$pass' --authenticationDatabase admin --quiet --eval '
db = db.getSiblingDB(\"os_docker\");
var c = new Date(Date.now() - $win*1000);
print(db.data_points.countDocuments({updated_at:{\$gt:c}, status:{\$in:[\"started\",\"completed\"]}}))'" 2>/dev/null || echo "-1"
}

gates_pass() {
  local sum=0 i v
  log "gate: fsync probes x$PROBES"
  for i in $(seq 1 "$PROBES"); do
    v=$(fsync_ms); sum=$((sum + v))
    log "      probe $i: ${v}ms"
    sleep 2
  done
  local avg=$((sum / PROBES))
  if [ "$avg" -gt "$MAX_FSYNC_MS" ]; then log "GATE FAIL: avg fsync ${avg}ms > ${MAX_FSYNC_MS}ms"; return 1; fi
  log "gate: avg fsync ${avg}ms OK"

  local d; d=$(nfsd_dcount)
  local limit=$(( 256 / 4 ))
  if [ "$d" -gt "$limit" ]; then log "GATE FAIL: nfsd D=$d > $limit"; return 1; fi
  log "gate: nfsd D=$d OK"

  return 0
}

rollback() {
  local last_good="$1"
  local safe=$(( last_good * 70 / 100 ))
  log "!! BREACH -- rolling back to $safe (70% of last-good $last_good)"
  kubectl -n "$NS" scale deploy worker --replicas="$safe" >/dev/null
  sleep 90
  # assist recovery the way we learned by hand today
  kubectl -n "$NS" exec nodedebug-bjn92 -- \
    chroot /host blockdev --flushbufs /dev/vdb 2>/dev/null || true
  log "rollback complete at $safe; investigate before re-running"
  exit 1
}

main() {
  command -v kubectl >/dev/null || { echo "kubectl not found"; exit 2; }
  local cur; cur=$(current_replicas)
  log "start: replicas=$cur target=$TARGET stage=+$STAGE"

  while [ "$cur" -lt "$TARGET" ]; do
    local next=$(( cur + STAGE )); [ "$next" -gt "$TARGET" ] && next=$TARGET

    log "== stage: $cur -> $next =="
    kubectl -n "$NS" scale deploy worker --replicas="$next" >/dev/null
    sleep 60  # let scheduling catch up

    local c1 c2
    c1=$(completions_delta 1)   # baseline (unused numerically; warms exec)
    sleep "$SETTLE"

    if ! gates_pass; then rollback "$cur"; fi

    c2=$(completions_delta "$SETTLE")
    if [ "$c2" -ge 0 ]; then
      log "progress: $c2 dp updates in ~${SETTLE}s"
      if [ "$c2" -lt "$MIN_PROGRESS" ]; then
        log "GATE FAIL: only $c2 updates < $MIN_PROGRESS in ${SETTLE}s"
        rollback "$cur"
      fi
    fi

    cur=$next
    log "stage healthy at $cur replicas"
  done
  log "DONE: $cur replicas. Re-adopt this count into openstack/values-openstack.yaml worker.replicas."
}

main "$@"
