#!/usr/bin/env bash
# Run on the head. RDMA write bandwidth on every rail of the 3-node CX7 ring.
set -uo pipefail
gid() { ssh -o BatchMode=yes "$1" "d=/sys/class/infiniband/$2/ports/1; for i in \$(ls \$d/gids | sort -n); do [ \"\$(cat \$d/gid_attrs/types/\$i 2>/dev/null)\" = 'RoCE v2' ] && case \$(cat \$d/gids/\$i) in 0000:0000:0000:0000:0000:ffff:*) echo \$i; exit;; esac; done"; }
# label  serverHost serverDev  serverIP    clientHost clientDev
LINKS=(
 "112<->93  r1 192.168.1.93  rocep1s0f1   10.20.0.12 192.168.1.112 rocep1s0f0"
 "112<->93  r2 192.168.1.93  roceP2p1s0f1 10.20.1.12 192.168.1.112 roceP2p1s0f0"
 "93<->234  r1 192.168.1.234 rocep1s0f1   10.20.2.13 192.168.1.93  rocep1s0f0"
 "93<->234  r2 192.168.1.234 roceP2p1s0f1 10.20.3.13 192.168.1.93  roceP2p1s0f0"
 "234<->112 r1 192.168.1.112 rocep1s0f1   10.20.4.11 192.168.1.234 rocep1s0f0"
 "234<->112 r2 192.168.1.112 roceP2p1s0f1 10.20.5.11 192.168.1.234 roceP2p1s0f0"
)
for l in "${LINKS[@]}"; do
  read -r label rail sh sd sip ch cd <<<"$l"
  gs=$(gid $sh $sd); gc=$(gid $ch $cd)
  ssh $sh "pkill -x ib_write_bw; nohup ib_write_bw -d $sd -x $gs -F --report_gbits -D 4 -p 18600 >/tmp/ibbw.srv 2>&1 &"; sleep 1.5
  bw=$(ssh $ch "ib_write_bw -d $cd -x $gc -F --report_gbits -D 4 -p 18600 $sip 2>&1" | awk '/^ *65536/{print $4}')
  ping=$(ssh $ch "ping -c3 -q $sip | awk -F/ '/rtt/{print \$5}'")
  printf "%-10s %s  %-13s -> %-13s gid %s/%s  RTT %5s ms  BW %s Gb/s\n" "$label" "$rail" "$cd" "$sd" "$gc" "$gs" "$ping" "${bw:-FAIL}"
done
