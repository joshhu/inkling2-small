#!/usr/bin/env bash
# One-time, run from the Mac for each new Spark: authorize your SSH public key(s)
# and enable passwordless sudo (setup-cluster.sh and start.sh need both).
# Usage: scripts/bootstrap-node.sh <user@host> [pubkey files...]   (asks for the password twice)
set -euo pipefail
TARGET=$1; shift
KEYS=${*:-$HOME/.ssh/id_ed25519.pub}
PUB=$(cat $KEYS)
ssh -t -o StrictHostKeyChecking=accept-new "$TARGET" "
  set -e; mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
  while read -r k; do [ -n \"\$k\" ] && { grep -qF \"\$k\" ~/.ssh/authorized_keys || echo \"\$k\" >> ~/.ssh/authorized_keys; }; done <<'KEYS'
$PUB
KEYS
  echo \"\$USER ALL=(ALL) NOPASSWD:ALL\" | sudo tee /etc/sudoers.d/\$USER >/dev/null
  sudo chmod 440 /etc/sudoers.d/\$USER && sudo visudo -cf /etc/sudoers.d/\$USER
  echo \"DONE on \$(hostname)\""
