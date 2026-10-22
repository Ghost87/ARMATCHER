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

# 🌉 v5.4 local Bot API bridge (activation: TG_LOCAL_API=1 + TELEGRAM_API_ID/HASH).
# Runs the official telegram-bot-api daemon beside the worker; downloads become
# local disk reads and the hard 20MB cloud wall lifts to the destinations' 50MB.
# v5.4.1: sealed creds (payload/tgapp.env) auto-activate the bridge when the workflow
# left TG_LOCAL_API unset entirely; an explicit 1/0 from the env always wins.
if [ -z "${TG_LOCAL_API+x}" ] && [ -f "$WORK/tgapp.env" ]; then
  echo "🌉 sealed bridge creds found — auto-activating local Bot API bridge"
  set -a; . "$WORK/tgapp.env"; set +a
  export TG_LOCAL_API=1
fi
if [ "${TG_LOCAL_API:-0}" = "1" ]; then
  echo "🌉 TG_LOCAL_API=1 — starting local Bot API bridge…"
  : "${TELEGRAM_API_ID:?TELEGRAM_API_ID missing (from my.telegram.org)}"
  : "${TELEGRAM_API_HASH:?TELEGRAM_API_HASH missing}"
  mkdir -p "$WORK/tgbapi"
  docker rm -f tgbapi >/dev/null 2>&1 || true
  docker run -d --name tgbapi --restart no \
    -e TELEGRAM_API_ID -e TELEGRAM_API_HASH \
    -v "$WORK/tgbapi:/var/lib/telegram-bot-api" \
    -p 127.0.0.1:8081:8081 \
    aiogram/telegram-bot-api:latest --local
  if [ -z "${TELEGRAM_BOT_TOKEN:-}" ]; then
    echo "🌉⚠️ no bot token for the bridge probe — staying on cloud API (20MB ceiling)"
    export TG_LOCAL_API=0
  else
    ok=""
    # v5.4.2: a HEALTHY daemon answers 404 on / — probing the root was the v5.4.1 bug.
    # The only honest gate: the bridge itself answering the bot's own getMe
    # (this also proves the token migrated cloud→local).
    for i in $(seq 1 60); do
      body="$(curl -s --max-time 4 "http://127.0.0.1:8081/bot${TELEGRAM_BOT_TOKEN}/getMe" 2>/dev/null || true)"
      case "$body" in *'"ok":true'*) ok=1; break;; esac
      sleep 1
    done
    if [ -n "$ok" ]; then
      export TG_API_BASE="${TG_API_BASE:-http://127.0.0.1:8081}"
      export TG_LOCAL_DIR="$WORK/tgbapi"
      echo "🌉 bridge healthy at ${TG_API_BASE} (getMe verified — 50MB lane open)"
    else
      docker logs --tail 5 tgbapi 2>/dev/null || true
      # Bridge failed to come up — stay on the cloud path (service never goes dark).
      export TG_LOCAL_API=0
      echo "🌉⚠️ bridge failed to start — staying on cloud API (20MB ceiling)"
    fi
  fi
fi

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
