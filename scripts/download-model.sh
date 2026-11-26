#!/usr/bin/env bash
# Run on the head only. 322 GB of GGUF (9 shards). Workers never need the file:
# llama-server ships their layers over RPC and they cache them in ~/.cache/llama.cpp/rpc (-c).
# Uses any image that has huggingface_hub so the host stays clean.
set -euo pipefail
OUT=${OUT:-$HOME/models/Inkling-2-Small-IQ4_XS}
IMAGE=${IMAGE:-ghcr.io/anemll/dspark-vllm-gx10:0.1.1}
mkdir -p "$OUT" ~/logs
docker run --rm -v "$OUT":/out ${HF_TOKEN:+-e HF_TOKEN} --entrypoint python3 "$IMAGE" -c \
  'from huggingface_hub import snapshot_download; snapshot_download("bartowski/Inkling-2-Small-GGUF", allow_patterns=["Inkling-2-Small-IQ4_XS/*"], local_dir="/out", max_workers=8)'
du -sh "$OUT"
