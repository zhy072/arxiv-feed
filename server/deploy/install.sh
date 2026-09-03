#!/usr/bin/env bash
# Run ON the server, after the code has been rsynced to /opt/arxiv. Idempotent.
set -euo pipefail

APP_DIR=/opt/arxiv
mkdir -p "$APP_DIR/data" "$APP_DIR/logs"

if ! dpkg -s python3-venv >/dev/null 2>&1; then
    apt-get update -qq
    apt-get install -y -qq python3-venv >/dev/null
fi

if [ ! -x "$APP_DIR/venv/bin/pip" ]; then
    python3 -m venv "$APP_DIR/venv"
fi
"$APP_DIR/venv/bin/pip" install --quiet --upgrade pip
"$APP_DIR/venv/bin/pip" install --quiet -r "$APP_DIR/requirements.txt"

if [ ! -f "$APP_DIR/.env" ]; then
    TOKEN=$(openssl rand -hex 24)
    cat > "$APP_DIR/.env" <<EOF
OPENAI_API_KEY=
API_TOKEN=$TOKEN
ARXIV_CATEGORIES=cs.CV,cs.LG,cs.CL,cs.AI,cs.MM,cs.SD,eess.AS,eess.IV
SUMMARIZE_MODEL=gpt-5-mini
INTERPRET_MODEL=gpt-5
EMBED_MODEL=text-embedding-3-small
API_PORT=8787
EOF
    chmod 600 "$APP_DIR/.env"
    echo "[install] created $APP_DIR/.env with a fresh API_TOKEN"
fi

cp "$APP_DIR/deploy/arxiv-api.service" /etc/systemd/system/arxiv-api.service
systemctl daemon-reload
systemctl enable arxiv-api >/dev/null 2>&1
systemctl restart arxiv-api

install -m 644 "$APP_DIR/deploy/arxiv-cron" /etc/cron.d/arxiv

echo "[install] done. API on port 8787, daily pipeline at 09:30."
