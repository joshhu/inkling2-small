#!/usr/bin/env bash
cd "$(dirname "$0")"; source cluster.env
pkill -x llama-server && echo "llama-server stopped"
for pair in $RPC_NODES; do ssh -o BatchMode=yes "${pair%%=*}" "pkill -x ggml-rpc-server && echo rpc-server stopped on \$(hostname)"; done
