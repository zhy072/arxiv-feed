#!/usr/bin/env bash
# Install the arxiv-feed backend as a per-user launchd agent on this Mac (loopback only).
# Re-run any time: it recreates the venv if missing, reinstalls deps, and restarts the agent.
# Overrides (env): PYTHON=<interpreter>  ARXIV_PORT=<port, first install only>  ARXIV_LAUNCHD_LABEL=<label>
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PY="${PYTHON:-python3}"
LABEL="${ARXIV_LAUNCHD_LABEL:-local.arxivfeed.api}"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
CODEX_DEFAULT=/Applications/ChatGPT.app/Contents/Resources/codex

cd "$ROOT"
if ! command -v "$PY" >/dev/null 2>&1; then
    echo "需要 python3（macOS 自带的也行：运行 xcode-select --install 装 Command Line Tools）" >&2
    exit 1
fi
echo "python: $("$PY" -c 'import sys; print(sys.executable, sys.version.split()[0])')"
[ -x venv/bin/python ] || "$PY" -m venv venv
venv/bin/pip install -q --upgrade pip
venv/bin/pip install -q -r requirements.txt

if [ ! -f .env ]; then
    cp .env.example .env
    # First install: pick up the port override and the model this ChatGPT account actually uses.
    if [ -n "${ARXIV_PORT:-}" ]; then
        sed -i '' "s|^API_PORT=.*|API_PORT=$ARXIV_PORT|" .env
    fi
    if [ -f "$HOME/.codex/config.toml" ]; then
        MODEL="$(grep -E '^model *= *"' "$HOME/.codex/config.toml" | head -1 | sed -E 's/.*"([^"]+)".*/\1/')"
        if [ -n "$MODEL" ]; then
            sed -i '' "s|^CODEX_MODEL=.*|CODEX_MODEL=$MODEL|" .env
            echo "codex model: $MODEL (from ~/.codex/config.toml; edit CODEX_MODEL in .env to change)"
        fi
    fi
fi
CODEX_BIN="$(grep -E '^CODEX_BIN=' .env | cut -d= -f2- | tr -d '[:space:]')"
CODEX_BIN="${CODEX_BIN:-$CODEX_DEFAULT}"
if [ ! -x "$CODEX_BIN" ]; then
    echo "⚠️  没找到 Codex CLI（$CODEX_BIN）。请安装 ChatGPT 桌面版并登录；没有它只能抓论文，生成不了速览。" >&2
elif [ ! -f "$HOME/.codex/auth.json" ]; then
    echo "⚠️  Codex 还没登录（缺 ~/.codex/auth.json）。打开 ChatGPT.app 登录一次，或在终端运行：$CODEX_BIN login" >&2
fi
mkdir -p data logs "$HOME/Library/LaunchAgents"

PORT="$(grep -E '^API_PORT=' .env | cut -d= -f2 | tr -d '[:space:]')"
PORT="${PORT:-8787}"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$ROOT/venv/bin/uvicorn</string>
        <string>app.main:app</string>
        <string>--host</string><string>127.0.0.1</string>
        <string>--port</string><string>$PORT</string>
    </array>
    <key>WorkingDirectory</key><string>$ROOT</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key><string>/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin</string>
        <key>HOME</key><string>$HOME</string>
        <key>PYTHONUNBUFFERED</key><string>1</string>
    </dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>$ROOT/logs/api.log</string>
    <key>StandardErrorPath</key><string>$ROOT/logs/api.log</string>
</dict>
</plist>
EOF

UID_="$(id -u)"
launchctl bootout "gui/$UID_/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$UID_" "$PLIST"
launchctl kickstart -k "gui/$UID_/$LABEL"

for _ in $(seq 1 30); do
    if curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
        echo "arxiv-feed backend running at http://127.0.0.1:$PORT (launchd: $LABEL, log: logs/api.log)"
        exit 0
    fi
    sleep 0.5
done
echo "backend did not come up — check $ROOT/logs/api.log" >&2
exit 1
