#!/bin/bash
# Live view of batch-run scaling health. Refreshes every N seconds (default 10).
#
# Shows: worker pods by phase, worker nodes, HPA desired/current, and the
# per-analysis job backlog signal via web log tail (upload/extract errors).
#
# Usage: scripts/watch-scale.sh [interval_sec]

INTERVAL="${1:-10}"
NS="openstudio-server"

while true; do
  clear 2>/dev/null || printf '\033[2J\033[H'
  echo "=== $(date '+%H:%M:%S')  openstudio-server scale monitor (ctrl-c to exit) ==="

  echo "--- worker pods by phase ---"
  kubectl get pods -n "$NS" -l app=worker --no-headers 2>/dev/null \
    | awk '{c[$3]++} END {for (k in c) printf "  %-18s %d\n", k, c[k]}'

  echo "--- nodes (worker group) ---"
  kubectl get nodes --no-headers 2>/dev/null \
    | awk '{r=($2=="Ready")?"ready":"NOT-READY"; c[r]++} END {for (k in c) printf "  %-12s %d\n", k, c[k]}'

  echo "--- HPA ---"
  kubectl get hpa worker-hpa -n "$NS" --no-headers 2>/dev/null \
    | awk '{printf "  targets=%s  min=%s  max=%s  replicas=%s\n", $2, $3, $4, $5}'

  echo "--- recent scheduler failures (last 5) ---"
  kubectl get events -n "$NS" --field-selector reason=FailedScheduling \
    --sort-by=.lastTimestamp 2>/dev/null | tail -5 | awk '{printf "  %s %s\n", $1, $NF}' | cut -c1-140

  echo "--- web: recent 5xx (API health) ---"
  WPOD=$(kubectl get pods -n "$NS" -l app=web -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  if [ -n "$WPOD" ]; then
    kubectl logs -n "$NS" "$WPOD" --since=60s 2>/dev/null \
      | grep -oE '" (5[0-9][0-9]) ' | sort | uniq -c | awk '{printf "  %s x%s (last 60s)\n", $2, $1}' || true
    [ -z "$(kubectl logs -n "$NS" "$WPOD" --since=60s 2>/dev/null | grep -oE '\" 5[0-9][0-9] \"')" ] \
      && echo "  none in last 60s"
  fi

  sleep "$INTERVAL"
done
