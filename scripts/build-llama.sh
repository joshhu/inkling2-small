#!/usr/bin/env bash
# Run on EVERY node (same commit everywhere). Builds llama.cpp with CUDA (SM121) + RPC.
# RDMA transport for ggml-rpc is detected and enabled automatically when rdma-core is present.
set -euo pipefail
LLAMA_DIR=${LLAMA_DIR:-$HOME/workspace/llama.cpp}
COMMIT=${COMMIT:-beb9d49}
[ -d "$LLAMA_DIR" ] || git clone https://github.com/ggml-org/llama.cpp "$LLAMA_DIR"
cd "$LLAMA_DIR" && git fetch -q && git checkout -q "$COMMIT"
export PATH=/usr/local/cuda/bin:$PATH
cmake -B build -DGGML_CUDA=ON -DGGML_RPC=ON -DCMAKE_CUDA_ARCHITECTURES=121 \
      -DCMAKE_BUILD_TYPE=Release -DLLAMA_CURL=OFF > build-cmake.log 2>&1
cmake --build build -j "$(nproc)" --target llama-server ggml-rpc-server llama-bench llama-cli > build-make.log 2>&1
echo "BUILD_OK $(hostname) $(./build/bin/llama-server --version 2>&1 | grep -m1 version)"
