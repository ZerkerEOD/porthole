#!/usr/bin/env bash
# Local end-to-end smoke test: builds the daemon, runs it with an isolated
# state dir on port 7434, starts a Claude Code session inside tmux, pairs a
# dev client, subscribes, types /help, and lists skills. Nothing touches your
# real ~/.config/porthole or ~/.local/state/porthole.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=${WORK:-$(mktemp -d)}
export XDG_CONFIG_HOME=$WORK/config XDG_STATE_HOME=$WORK/state XDG_RUNTIME_DIR=/tmp/porthole-smoke-$UID
mkdir -p "$XDG_CONFIG_HOME/porthole" "$XDG_STATE_HOME" "$XDG_RUNTIME_DIR"
cat > "$XDG_CONFIG_HOME/porthole/config.toml" <<CFG
name = "smoke"
port = 7434
workspaces = ["$ROOT/.."]
CFG
(cd "$ROOT/daemon" && go build -o "$WORK/porthole" ./cmd/porthole)
"$WORK/porthole" serve --log-level info >"$WORK/daemon.log" 2>&1 &
DPID=$!
# TWO=1 starts a second daemon ("laptop", port 7435) with its own state so the
# app can pair two machines; kill it to see the quiet offline state.
LPID=""
if [ "${TWO:-}" = "1" ]; then
  mkdir -p "$WORK/laptop/config/porthole" "$WORK/laptop/state" "$WORK/laptop/run"
  printf 'name = "laptop"\nport = 7435\nworkspaces = ["%s"]\n' "$ROOT/.." > "$WORK/laptop/config/porthole/config.toml"
  XDG_CONFIG_HOME=$WORK/laptop/config XDG_STATE_HOME=$WORK/laptop/state XDG_RUNTIME_DIR=/tmp/porthole-smoke-laptop-$UID \
    "$WORK/porthole" serve --log-level info >"$WORK/laptop.log" 2>&1 &
  LPID=$!
  echo "second daemon 'laptop' pid $LPID on :7435 (pair file: XDG_RUNTIME_DIR=/tmp/porthole-smoke-laptop-$UID $WORK/porthole pair --json)"
fi
trap 'kill $DPID $LPID 2>/dev/null; tmux kill-session -t ph-smoke 2>/dev/null; echo "logs: $WORK/daemon.log"' EXIT
sleep 4
"$WORK/porthole" status
tmux new-session -d -s ph-smoke -c "$ROOT" -- claude
sleep 5
"$WORK/porthole" sessions | head -5
PAIR=$("$WORK/porthole" pair --json)
CODE=$(echo "$PAIR" | python3 -c 'import json,sys;print(json.load(sys.stdin)["code"])')
FP=$(echo "$PAIR" | python3 -c 'import json,sys;print(json.load(sys.stdin)["fp"])')
KEY=$("$WORK/porthole" sessions --json | python3 -c 'import json,sys;print([s["key"] for s in json.load(sys.stdin) if s.get("tmux_session")=="ph-smoke"][0])')
"$WORK/porthole" client --port 7434 --fp "$FP" --code "$CODE" --seconds 6 \
  pane.subscribe "{\"key\":\"$KEY\"}" \
  session.input "{\"key\":\"$KEY\",\"text\":\"/help\",\"enter\":true}" \
  skills.list '{"provider":"claude"}' | cut -c1-200
echo "smoke OK"
