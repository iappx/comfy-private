#!/bin/sh
set -eu

RAM_ROOT=${COMFY_RAM_ROOT:-/dev/shm/comfy}
DATA_ROOT=${COMFY_DATA_ROOT:-/comfy}
VENV=${VIRTUAL_ENV:-/opt/venv}

export HOME=/root
export PATH="$VENV/bin:$PATH"
export XDG_CACHE_HOME="$RAM_ROOT/cache"
export MPLCONFIGDIR="$RAM_ROOT/cache/matplotlib"
export HF_HOME="${HF_HOME:-$DATA_ROOT/huggingface}"
export TORCH_HOME="${TORCH_HOME:-$DATA_ROOT/torch}"
export HF_HUB_DISABLE_TELEMETRY=1
export DO_NOT_TRACK=1
export PYTHONDONTWRITEBYTECODE=1

install -d -m 700 "$RAM_ROOT"
install -d -m 700 \
    "$RAM_ROOT/output" \
    "$RAM_ROOT/input" \
    "$RAM_ROOT/temp" \
    "$RAM_ROOT/user" \
    "$XDG_CACHE_HOME" \
    "$MPLCONFIGDIR"

if [ "${COMFY_ALLOW_CUSTOM_NODES:-1}" != "1" ]; then
    set -- --disable-all-custom-nodes "$@"
fi

cd "${COMFY_HOME:-/opt/comfyui}"

exec "$VENV/bin/python" main.py \
    --listen 127.0.0.1 \
    --port "${COMFY_PORT:-8188}" \
    --base-directory "$DATA_ROOT" \
    --output-directory "$RAM_ROOT/output" \
    --input-directory "$RAM_ROOT/input" \
    --temp-directory "$RAM_ROOT/temp" \
    --user-directory "$RAM_ROOT/user" \
    --database-url sqlite:///:memory: \
    --disable-metadata \
    --disable-api-nodes \
    --dont-print-server \
    "$@"
