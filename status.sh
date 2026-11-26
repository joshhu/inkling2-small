#!/usr/bin/env bash
# Memory per node + rpc-server tail + server tail. Run on the head.
cd "$(dirname "$0")"; source cluster.env
printf '%-9s %s GiB used\n' "$(hostname)" "$(free -g | awk '/Mem/{print $3}')"
for pair in $RPC_NODES; do
  ssh -o BatchMode=yes "${pair%%=*}" 'printf "%-9s %s GiB used\n" "$(hostname)" "$(free -g | awk "/Mem/{print \$3}")"; tail -2 ~/logs/rpc-server.log | cut -c1-160'
done
echo "--- server"; tail -4 logs/server.log | cut -c1-200
curl -s -o /dev/null -w "health=%{http_code}\n" "http://127.0.0.1:$API_PORT/health"
