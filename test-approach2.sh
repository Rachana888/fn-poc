#!/bin/bash
# Approach 2 sample run: N cold invokes (fresh execution-id each time),
# then N warm invokes on the last successful cold execution.
# Records per-sample timing breakdown:
#   tls_s    = time to finish TLS handshake (laptop network overhead)
#   server_s = first-byte time minus TLS time (real platform-side invoke cost)
#   total_s  = end-to-end as seen by the client
# Usage: ./test-approach2.sh [cold_count] [warm_count] [output_csv] [function_name]
# Env required: ACT, CERT, KEY (source ~/mvm.env first)
# The template ID is read from the register (~/fn-poc/data/mappings.json),
# keyed by function_name (default: mvm-poc/hello) — same lookup the real
# Functions invoker will do. Set FN explicitly to override.
set -u

COLD_N=${1:-10}
WARM_N=${2:-10}
OUT=${3:-/tmp/mvm-results.csv}
FN_NAME=${4:-mvm-poc/hello}
REGISTER="$HOME/fn-poc/data/mappings.json"

if [ -z "${FN:-}" ]; then
  FN=$(python3 -c "import json,sys;print(json.load(open('$REGISTER'))['$FN_NAME']['microvm_id'])") \
    || { echo "lookup of '$FN_NAME' in $REGISTER failed"; exit 1; }
  echo "register lookup: $FN_NAME -> $FN"
fi

: "${ACT:?run: source ~/mvm.env}"
: "${CERT:?run: source ~/mvm.env}"
: "${KEY:?run: source ~/mvm.env}"

echo "fn=$FN" | tee "$OUT"
echo "type,i,execution_id,http_code,tls_s,server_s,total_s" | tee -a "$OUT"

invoke() { # $1=exec_id $2=payload_name -> "code tls server total"
  local R
  R=$(curl -sS -o /dev/null \
    -w "%{http_code} %{time_appconnect} %{time_starttransfer} %{time_total}" \
    --cert "$CERT" --key "$KEY" \
    -H "region: sfo3" -H "cell: staging" \
    -H "x-microvm-id: $FN" -H "x-execution-id: $1" \
    -H 'Content-Type: application/json' -d "{\"value\":{\"name\":\"$2\"}}" \
    "$ACT/run" 2>/dev/null || echo "000 0 0 0")
  echo "$R" | awk '{printf "%s %.3f %.3f %.3f", $1, $2, ($3-$2), $4}'
}

LAST_GOOD=""
COLD_OK=0
COLD_FAIL=0

for i in $(seq 1 "$COLD_N"); do
  E=$(uuidgen | tr 'A-Z' 'a-z')
  read -r CODE TLS SRV TOT <<< "$(invoke "$E" cold)"
  echo "cold,$i,$E,$CODE,$TLS,$SRV,$TOT" | tee -a "$OUT"
  if [ "$CODE" = "200" ]; then
    COLD_OK=$((COLD_OK+1))
    LAST_GOOD=$E
  else
    COLD_FAIL=$((COLD_FAIL+1))
  fi
  sleep 1
done

echo "cold_ok=$COLD_OK cold_fail=$COLD_FAIL last_good=$LAST_GOOD" | tee -a "$OUT"

if [ -z "$LAST_GOOD" ]; then
  echo "No successful cold invoke, skipping warm test (TSC issue)."
  exit 0
fi

echo "Warming on $LAST_GOOD ..."
for i in $(seq 1 "$WARM_N"); do
  read -r CODE TLS SRV TOT <<< "$(invoke "$LAST_GOOD" warm)"
  echo "warm,$i,$LAST_GOOD,$CODE,$TLS,$SRV,$TOT" | tee -a "$OUT"
  sleep 1
done

echo ""
echo "===== SUMMARY (HTTP 200 only, server-side seconds) ====="
for T in cold warm; do
  awk -F, -v t="$T" '$1 == t && $4 == 200 { print $6 }' "$OUT" | sort -n | awk -v t="$T" '
    { a[NR] = $1; s += $1 }
    END {
      if (NR == 0) { printf "%-5s no successful samples\n", t; exit }
      med = (NR % 2) ? a[(NR+1)/2] : (a[NR/2] + a[NR/2+1]) / 2
      printf "%-5s n=%d  min=%.3f  median=%.3f  avg=%.3f  max=%.3f\n", t, NR, a[1], med, s/NR, a[NR]
    }'
done

echo "Done. Results in $OUT"
