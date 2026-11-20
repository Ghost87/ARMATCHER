#!/usr/bin/env bash
# core launcher — unpacks the sealed payload, starts the worker + state sealer.
# usage: bash init.sh [run|probe|poll|rfile|ids]   (default: run)
set -euo pipefail
MODE="${1:-run}"
ROOT="$(cd "$(dirname "$0")" && pwd)"

# 🛑 web kill-switch: a file named STOP in the repo = instant no-op for every run
if [ -f "$ROOT/STOP" ]; then
  echo "⛔ STOP flag found in repo — worker stays down."
  exit 0
fi

WORK="$ROOT/.runit"
: "${FILE_KEY:?FILE_KEY env is missing}"

rm -rf "$WORK"; mkdir -p "$WORK"
openssl enc -d -aes-256-cbc -pbkdf2 -in "$ROOT/payload.enc" -out "$WORK/core.tgz" -pass env:FILE_KEY
tar -xzf "$WORK/core.tgz" -C "$WORK"
rm -f "$WORK/core.tgz"

if [ -f "$ROOT/state.enc" ]; then
  openssl enc -d -aes-256-cbc -pbkdf2 -in "$ROOT/state.enc" -out "$WORK/state.json" -pass env:FILE_KEY
fi

export STATE_FILE="$WORK/state.json"
export STATE_SEAL="$ROOT/state.enc"
export REPO_ROOT="$ROOT"

git -C "$ROOT" config user.name "core-bot" 2>/dev/null || true
git -C "$ROOT" config user.email "core-bot@users.noreply.github.com" 2>/dev/null || true

case "$MODE" in
  probe)
    set +e
    for h in api.telegram.org tapi.bale.ai botapi.rubika.ir github.com; do
      code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 20 "https://$h/" || echo FAIL)
      echo "HOST $h -> $code"
    done
    exit 0 ;;
  poll)
    cd "$WORK" && exec python tools/poll_probe.py ;;
  rfile)
    cd "$WORK" && exec python tools/rubika_file_probe.py ;;
  ids)
    cd "$WORK" && exec python tools/find_ids.py ;;
  run|*)
    cd "$WORK"
    nohup bash tools/sealer.sh >/dev/null 2>&1 &
    exec python relay.py ;;
esac
