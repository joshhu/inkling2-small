#!/usr/bin/env bash
# Run on the head (JoshDGX). Starts rpc servers on the two workers, then llama-server.
set -euo pipefail
cd "$(dirname "$0")"; source cluster.env; mkdir -p logs
log(){ printf '\033[1;36m[inkling]\033[0m %s\n' "$*"; }

for pair in $RPC_NODES; do
  h=${pair%%=*}; ip=${pair##*=}
  ssh -o BatchMode=yes "$h" "pkill -x ggml-rpc-server; sleep 1; mkdir -p ~/logs; nohup $LLAMA_DIR/build/bin/ggml-rpc-server -H $ip -p $RPC_PORT -c > ~/logs/rpc-server.log 2>&1 < /dev/null &"
  log "rpc-server on $h bound to $ip:$RPC_PORT"
done
sleep 3
RPC=$(for pair in $RPC_NODES; do printf '%s:%s,' "${pair##*=}" "$RPC_PORT"; done); RPC=${RPC%,}

pkill -x llama-server || true; sleep 1
log "llama-server --rpc $RPC  (log: logs/server.log)"
nohup "$LLAMA_DIR/build/bin/llama-server" -m "$MODEL" --alias "$ALIAS" \
  --rpc "$RPC" -ngl 999 -sm layer --fit on -c "$CTX" -ub "$UBATCH" -ts "$TENSOR_SPLIT" -np "$PARALLEL" -fa on -lm dio -lv 4 \
  --jinja --host "$API_HOST" --port "$API_PORT" > logs/server.log 2>&1 < /dev/null &

log "Waiting for /health (reads 322 GB and ships ~2/3 of it over RDMA)…"
for i in $(seq 1 180); do
  curl -fsS -o /dev/null "http://127.0.0.1:$API_PORT/health" && { log "Ready after ~$((i*10))s: http://192.168.1.112:$API_PORT/v1  model=$ALIAS"; exit 0; }
  pgrep -x llama-server >/dev/null || { tail -40 logs/server.log; log "llama-server exited"; exit 1; }
  sleep 10
done
log "Timed out; see logs/server.log"; exit 1
