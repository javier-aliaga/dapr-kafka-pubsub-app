#!/usr/bin/env bash
set -euo pipefail

PUB=${PUB:-publisher}
SUB=${SUB:-subscriber}
NS=${NS:-default}

tmp=$(mktemp -d)
trap "rm -rf $tmp" EXIT

kubectl logs -n "$NS" deploy/"$PUB" -c "$PUB" --tail=-1 2>/dev/null \
  | grep -oE "sent topic=[^ ]+ seq=[0-9]+" \
  | sort -u > "$tmp/sent"

{
  kubectl logs -n "$NS" deploy/"$SUB" -c "$SUB" --tail=-1 2>/dev/null || true
  kubectl logs -n "$NS" --previous deploy/"$SUB" -c "$SUB" --tail=-1 2>/dev/null || true
  for p in $(kubectl get pods -n "$NS" -l app="$SUB" -o name 2>/dev/null); do
    kubectl logs -n "$NS" "$p" -c "$SUB" --tail=-1 2>/dev/null || true
    kubectl logs -n "$NS" --previous "$p" -c "$SUB" --tail=-1 2>/dev/null || true
  done
} | grep -oE "done topic=[^ ]+ seq=[0-9]+" > "$tmp/done_raw" || true

sort -u "$tmp/done_raw" > "$tmp/done_unique"

sed 's/^done /sent /' "$tmp/done_unique" > "$tmp/done_norm"
comm -23 "$tmp/sent" "$tmp/done_norm" > "$tmp/missing"

sent=$(wc -l < "$tmp/sent" | tr -d ' ')
done_raw=$(wc -l < "$tmp/done_raw" | tr -d ' ')
done_unique=$(wc -l < "$tmp/done_unique" | tr -d ' ')
missing=$(wc -l < "$tmp/missing" | tr -d ' ')
redelivered=$((done_raw - done_unique))

echo "sent (unique):       $sent"
echo "done (raw lines):    $done_raw"
echo "done (unique):       $done_unique"
echo "redelivered:         $redelivered   (>0 = Kafka rebalance redelivery — usually OK)"
echo "ABANDONED (missing): $missing      (sent but never marked done — the bug)"

if [ "$missing" -gt 0 ]; then
  echo "--- first 30 missing ---"
  head -30 "$tmp/missing"
  if [ "$missing" -gt 30 ]; then
    echo "... ($((missing - 30)) more)"
  fi
fi
