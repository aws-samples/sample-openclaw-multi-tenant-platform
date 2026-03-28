#!/usr/bin/env bash
set -euo pipefail

# List all openclaw-* namespaces
NAMESPACES=$(kubectl get ns -l app.kubernetes.io/managed-by=Helm -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep '^openclaw-' || true)

if [[ -z "$NAMESPACES" ]]; then
  echo "No tenants found"
  exit 0
fi

# Header
printf "%-20s %-12s %-10s %-12s %s\n" "TENANT" "POD STATUS" "RESTARTS" "PVC USED%" "RECENT EVENT"
printf "%-20s %-12s %-10s %-12s %s\n" "------" "----------" "--------" "---------" "------------"

while read -r NS; do
  TENANT="${NS#openclaw-}"

  # Pod status + restarts
  POD_INFO=$(kubectl get pod -n "$NS" -l "app.kubernetes.io/instance=$NS" -o jsonpath='{.items[0].status.containerStatuses[0].state}|{.items[0].status.containerStatuses[0].restartCount}|{.items[0].status.phase}|{.items[0].metadata.name}' 2>/dev/null || echo "|||")
  IFS='|' read -r STATE RESTARTS PHASE POD_NAME <<< "$POD_INFO"

  if [[ -z "$PHASE" ]]; then
    STATUS="NoPod"
  elif echo "$STATE" | grep -q "waiting.*CrashLoopBackOff" 2>/dev/null; then
    STATUS="CrashLoop"
  else
    STATUS="$PHASE"
  fi
  RESTARTS="${RESTARTS:-0}"

  # PVC usage via df
  PVC_USED="-"
  if [[ -n "$POD_NAME" ]]; then
    PVC_USED=$(kubectl exec -n "$NS" "$POD_NAME" -- df -h /home/node/.openclaw 2>/dev/null | awk 'NR==2{print $5}' || echo "-")
  fi

  # Recent event (last warning, or last event if no warning)
  EVENT=$(kubectl get events -n "$NS" --sort-by='.lastTimestamp' -o custom-columns=TYPE:.type,REASON:.reason,MSG:.message --no-headers 2>/dev/null | awk '/Warning/{last=$0} END{if(last) print last}')
  if [[ -z "$EVENT" ]]; then
    EVENT=$(kubectl get events -n "$NS" --sort-by='.lastTimestamp' -o custom-columns=MSG:.message --no-headers 2>/dev/null | tail -1)
  fi
  EVENT="${EVENT:--}"
  # Truncate long events
  [[ ${#EVENT} -gt 60 ]] && EVENT="${EVENT:0:57}..."

  printf "%-20s %-12s %-10s %-12s %s\n" "$TENANT" "$STATUS" "$RESTARTS" "$PVC_USED" "$EVENT"
done <<< "$NAMESPACES"
