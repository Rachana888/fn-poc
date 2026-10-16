#!/usr/bin/env bash
# P50/P99 cold + warm sampling for functions-mvm-invoker (Shraman's method).
#
#   Warm: continuous invokes, back to back.
#   Cold: a gap before EVERY invoke so the execution idles out (default 300s).
#
# Usage:
#   export AUTH='uuid:secret'          # DEMO_API_KEY
#   ./test-invoker-percentiles.sh [N_WARM] [N_COLD] [GAP_SECONDS]
#
# Defaults: 10 warm, 10 cold, 300s gap (~50 min for 10 cold samples).
# Server-side metric: microvmRunMs from the activation annotations.

set -u

N_WARM="${1:-10}"
N_COLD="${2:-10}"
GAP="${3:-300}"
BASE="${BASE:-https://functions-mvm-invoker.serverless.svc.nova.sfo2.internal.digitalocean.com}"
NS="${NS:-mvm-poc}"
ACTION="${ACTION:-hello}"
CERT="${CERT:-$HOME/.ssh/staff.crt}"
KEY="${KEY:-$HOME/.ssh/staff.key}"
MAX_RETRY="${MAX_RETRY:-10}"   # cold attempts can 502 until a good HV placement

if [ -z "${AUTH:-}" ]; then
  echo "Set AUTH to the invoker DEMO_API_KEY (uuid:secret)" >&2
  exit 1
fi

OUT_CSV="/tmp/invoker-samples-$(date +%Y%m%d-%H%M%S).csv"
echo "type,i,attempt,http_code,microvm_run_ms,functions_ms,execution_id,curl_total_s" > "$OUT_CSV"

invoke_once() {
  # prints: http_code|microvm_run_ms|functions_ms|execution_id|curl_total
  local body code total
  body=$(mktemp)
  code=$(curl -sS -o "$body" -w '%{http_code}|%{time_total}' \
    --cert "$CERT" --key "$KEY" \
    -u "$AUTH" -X POST \
    "$BASE/api/v1/namespaces/$NS/actions/$ACTION?blocking=true" \
    -H 'Content-Type: application/json' \
    -d '{"name":"percentile-test"}' 2>/dev/null)
  total="${code#*|}"
  code="${code%%|*}"
  if [ "$code" = "200" ]; then
    local run fn ex
    run=$(python3 -c "import json,sys; a=json.load(open('$body'))['annotations']; print(next(x['value'] for x in a if x['key']=='microvmRunMs'))" 2>/dev/null || echo "")
    fn=$(python3 -c "import json,sys; a=json.load(open('$body'))['annotations']; print(next(x['value'] for x in a if x['key']=='functionsMs'))" 2>/dev/null || echo "")
    ex=$(python3 -c "import json,sys; a=json.load(open('$body'))['annotations']; print(next(x['value'] for x in a if x['key']=='executionId'))" 2>/dev/null || echo "")
    echo "$code|$run|$fn|$ex|$total"
  else
    echo "$code||||$total"
  fi
  rm -f "$body"
}

sample() {
  # $1 = type (warm|cold), $2 = index. Retries non-200 up to MAX_RETRY.
  local typ="$1" idx="$2" attempt=1 line code
  while [ "$attempt" -le "$MAX_RETRY" ]; do
    line=$(invoke_once)
    code="${line%%|*}"
    IFS='|' read -r code run fn ex total <<< "$line"
    echo "$typ,$idx,$attempt,$code,$run,$fn,$ex,$total" >> "$OUT_CSV"
    if [ "$code" = "200" ]; then
      echo "  $typ #$idx attempt $attempt: http=200 microvmRunMs=$run exec=${ex:0:8}…"
      return 0
    fi
    echo "  $typ #$idx attempt $attempt: http=$code (retrying)"
    attempt=$((attempt + 1))
    sleep 2
  done
  echo "  $typ #$idx: FAILED after $MAX_RETRY attempts"
  return 1
}

echo "== invoker percentile run: $N_WARM warm (continuous) + $N_COLD cold (gap ${GAP}s) =="
echo "CSV: $OUT_CSV"
echo

echo "-- priming invoke (ensures a live warm slot; not counted) --"
sample prime 0 || { echo "priming failed; cell unhealthy?"; exit 1; }
echo

echo "-- warm phase: $N_WARM continuous invokes --"
for i in $(seq 1 "$N_WARM"); do
  sample warm "$i"
done
echo

echo "-- cold phase: $N_COLD invokes, ${GAP}s idle gap before each --"
for i in $(seq 1 "$N_COLD"); do
  echo "  waiting ${GAP}s so the execution idles out..."
  sleep "$GAP"
  sample cold "$i"
done
echo

echo "== summary (microvmRunMs, HTTP 200 only) =="
python3 - "$OUT_CSV" <<'EOF'
import csv, sys

rows = list(csv.DictReader(open(sys.argv[1])))

def pct(vals, p):
    vals = sorted(vals)
    if not vals:
        return None
    k = max(0, min(len(vals) - 1, round(p / 100 * (len(vals) - 1))))
    return vals[k]

for typ in ("cold", "warm"):
    ok_rows = [r for r in rows
               if r["type"] == typ and r["http_code"] == "200" and r["microvm_run_ms"]]
    ok = [int(r["microvm_run_ms"]) for r in ok_rows]
    fails = sum(1 for r in rows if r["type"] == typ and r["http_code"] != "200")
    if not ok:
        print(f"{typ}: no successful samples ({fails} failed attempts)")
        continue
    print(f"{typ}: n={len(ok)}  min={min(ok)}  P50={pct(ok,50)}  P99={pct(ok,99)}  "
          f"max={max(ok)}  avg={sum(ok)//len(ok)}  (failed attempts: {fails})")
    if typ == "cold":
        exs = [r["execution_id"] for r in ok_rows if r.get("execution_id")]
        uniq = len(set(exs))
        print(f"      unique execution_ids: {uniq}/{len(exs)}")
EOF

echo
echo "Raw samples: $OUT_CSV"
