#!/usr/bin/env bash
set -Eeuo pipefail

# =========================
# Args
# =========================
if [[ $# -lt 1 ]]; then
  echo "❌ Укажите номер воркера (например: 01, 02, 03)"
  exit 1
fi

WORKER_SUFFIX="$1"
if ! [[ "$WORKER_SUFFIX" =~ ^[0-9]{1,3}$ ]]; then
  echo "❌ Номер воркера должен быть числом (например: 01, 2, 003)"
  exit 1
fi

WORKER_NAME="v0$WORKER_SUFFIX"

# =========================
# Const
# =========================
WORKDIR="$HOME/work"
GPU_WORKERDIR="$WORKDIR/gpu"
CPU_WORKERDIR="$WORKDIR/cpu"
RESTART_DELAY=15

mkdir -p "$WORKDIR" "$GPU_WORKERDIR" "$CPU_WORKERDIR"

# =========================
# Config: GPU
# =========================
GPU_MINER_URL="https://dl.jetskipool.ai/vecnoskiminerv4-hive.tar.gz"
GPU_ARCHIVE="$GPU_WORKERDIR/vecnoskiminerv4-hive.tar.gz"
GPU_PUBKEY="vecno:qpdenm809vmq54r0vlcsxcqwd7ttgyqzawwd0xcnfz0ugsf6gpp45qywtr2hf"
GPU_STRATUM_SERVER="vecnopool.de"
GPU_STRATUM_PORT="6969"

# =========================
# Config: CPU
# =========================
CPU_MINER_URL="https://github.com/doktor83/SRBMiner-Multi/releases/download/3.1.1/SRBMiner-Multi-3-1-1-Linux.tar.gz"
CPU_ARCHIVE="$CPU_WORKERDIR/SRBMiner-Multi-3-1-1-Linux.tar.gz"
CPU_PUBKEY="0x4f752c9f474da78330b7c92e45217f0234004862"
CPU_POOL="eu.0xpool.io:3333"   # SRBMiner ожидает host:port
CPU_ALGO="randomx"

# =========================
# Helpers
# =========================
log() { echo -e "[$(date '+%H:%M:%S')] $*"; }

download_if_needed() {
  local url="$1"
  local out="$2"
  if [[ -s "$out" ]]; then
    log "✔ Archive already exists: $out"
  else
    log "⬇ Download: $url"
    wget -q --show-progress -O "$out" "$url"
  fi
}

extract_clean() {
  local archive="$1"
  local dest="$2"
  rm -rf "$dest/extract"
  mkdir -p "$dest/extract"
  tar -xzf "$archive" -C "$dest/extract"
}

find_executable() {
  local root="$1"
  local name="$2"
  # Ищем файл по имени и берем первый совпавший
  local bin
  bin="$(find "$root" -type f -name "$name" -print -quit || true)"
  if [[ -z "${bin:-}" ]]; then
    return 1
  fi
  chmod +x "$bin"
  echo "$bin"
}

prefix_logs() {
  local tag="$1"
  # line-buffered вывод, чтобы логи шли ровно в реальном времени
  stdbuf -oL -eL awk -v t="$tag" '{ print "[" t "] " $0 }'
}

# =========================
# Install / Prepare GPU
# =========================
download_if_needed "$GPU_MINER_URL" "$GPU_ARCHIVE"
extract_clean "$GPU_ARCHIVE" "$GPU_WORKERDIR"

# Внутри архива имя бинарника может отличаться; ты ожидал "vecnoski-miner".
# Попробуем найти именно его. Если не найден — покажем содержимое и упадём.
GPU_BIN="$(find_executable "$GPU_WORKERDIR/extract" "vecnoski-miner" || true)"
if [[ -z "${GPU_BIN:-}" ]]; then
  log "❌ Не найден GPU бинарник 'vecnoski-miner' в архиве. Список файлов:"
  find "$GPU_WORKERDIR/extract" -maxdepth 4 -type f | sed 's/^/  - /'
  exit 1
fi
log "✔ GPU bin: $GPU_BIN"

# =========================
# Install / Prepare CPU
# =========================
download_if_needed "$CPU_MINER_URL" "$CPU_ARCHIVE"
extract_clean "$CPU_ARCHIVE" "$CPU_WORKERDIR"

# SRBMiner обычно лежит как SRBMiner-MULTI
CPU_BIN="$(find_executable "$CPU_WORKERDIR/extract" "SRBMiner-MULTI" || true)"
if [[ -z "${CPU_BIN:-}" ]]; then
  log "❌ Не найден CPU бинарник 'SRBMiner-MULTI' в архиве. Список файлов:"
  find "$CPU_WORKERDIR/extract" -maxdepth 4 -type f | sed 's/^/  - /'
  exit 1
fi
log "✔ CPU bin: $CPU_BIN"

# =========================
# Run loops
# =========================
GPU_PID=""
CPU_PID=""

cleanup() {
  log "🛑 Stopping miners..."
  [[ -n "${GPU_PID:-}" ]] && kill "$GPU_PID" 2>/dev/null || true
  [[ -n "${CPU_PID:-}" ]] && kill "$CPU_PID" 2>/dev/null || true
  wait 2>/dev/null || true
  log "✅ Stopped."
}
trap cleanup INT TERM EXIT

run_gpu() {
  while true; do
    log "🚀 GPU miner start worker $WORKER_NAME"
    set +e
    "$GPU_BIN" \
      --mining-address "$GPU_PUBKEY" \
      --stratum-server "$GPU_STRATUM_SERVER" \
      --stratum-port "$GPU_STRATUM_PORT" \
      --stratum-worker "$WORKER_NAME" 2>&1 | prefix_logs "GPU"
    EXIT_CODE=${PIPESTATUS[0]}
    set -e
    log "⚠ GPU miner exited code=$EXIT_CODE. Restart in ${RESTART_DELAY}s..."
    sleep "$RESTART_DELAY"
  done
}

run_cpu() {
  while true; do
    log "🚀 CPU miner start worker $WORKER_NAME"
    set +e
    "$CPU_BIN" \
      --algorithm "$CPU_ALGO" \
      --pool "$CPU_POOL" \
      --wallet "$CPU_PUBKEY" \
      --worker "$WORKER_NAME" 2>&1 | prefix_logs "CPU"
    EXIT_CODE=${PIPESTATUS[0]}
    set -e
    log "⚠ CPU miner exited code=$EXIT_CODE. Restart in ${RESTART_DELAY}s..."
    sleep "$RESTART_DELAY"
  done
}

log "▶ Starting both miners..."
run_gpu & GPU_PID=$!
run_cpu & CPU_PID=$!

log "✅ Done! GPU_PID=$GPU_PID CPU_PID=$CPU_PID"
wait