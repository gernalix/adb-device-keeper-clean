#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BIN_SRC="$ROOT/bin/adb-device-keeper"
UNIT_SRC="$ROOT/systemd/user/adb-device-keeper.service"
BIN_DST="$HOME/.local/bin/adb-device-keeper"
UNIT_DST="$HOME/.config/systemd/user/adb-device-keeper.service"
CONFIG_DST="$HOME/.config/codex/secrets/adb-device-keeper/config"
RUNTIME_CHECK="$ROOT/scripts/runtime-check.sh"

git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    echo "Deploy requires a Git checkout: $ROOT" >&2
    exit 1
}
[[ -z $(git -C "$ROOT" status --porcelain) ]] || { echo "Refusing deploy from dirty checkout" >&2; exit 1; }
bash -n "$BIN_SRC"
bash -n "$RUNTIME_CHECK"
[[ -r "$CONFIG_DST" ]] || { echo "Missing runtime config: $CONFIG_DST" >&2; exit 1; }

install -D -m 0755 "$BIN_SRC" "$BIN_DST"
install -D -m 0644 "$UNIT_SRC" "$UNIT_DST"
systemctl --user daemon-reload
systemctl --user enable adb-device-keeper.service >/dev/null
systemctl --user restart adb-device-keeper.service

printf 'DEPLOY=PASS commit=%s\n' "$(git -C "$ROOT" rev-parse HEAD)"
# Optional arguments are intentionally forwarded to the canonical runtime gate,
# e.g. --reconnect-model Example_A --timeout 90.
bash "$RUNTIME_CHECK" "$@"
