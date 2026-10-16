#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ADB=${ADB_DEVICE_KEEPER_ADB:-$HOME/Android/Sdk/platform-tools/adb}
BIN_DST=${ADB_DEVICE_KEEPER_BIN_DST:-$HOME/.local/bin/adb-device-keeper}
UNIT_DST=${ADB_DEVICE_KEEPER_UNIT_DST:-$HOME/.config/systemd/user/adb-device-keeper.service}
CONFIG_DST=${ADB_DEVICE_KEEPER_CONFIG:-$HOME/.config/codex/secrets/adb-device-keeper/config}
SERVICE=${ADB_DEVICE_KEEPER_SERVICE:-adb-device-keeper.service}
RECONNECT_MODEL=''
RECONNECT_TIMEOUT=90

usage() {
    cat <<'EOF'
Usage: runtime-check.sh [--reconnect-model MODEL] [--timeout SECONDS]

Verifies the deployed adb-device-keeper runtime. With --reconnect-model it performs
one controlled adb disconnect and waits for that model to return as device.
EOF
}

fail() {
    printf 'RUNTIME=FAIL reason=%s\n' "$1" >&2
    if command -v journalctl >/dev/null 2>&1; then
        journalctl --user -u "$SERVICE" -n 30 --no-pager >&2 || true
    fi
    exit 1
}

classify_transport() {
    local transport=$1 host first second

    [[ $transport == adb-*._adb-tls-connect._tcp ]] && { printf 'mdns\n'; return; }
    [[ $transport == *:* ]] || { printf 'other\n'; return; }
    host=${transport%:*}

    if [[ $host =~ ^100\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
        first=${BASH_REMATCH[1]}
        ((first >= 64 && first <= 127)) && { printf 'tailscale\n'; return; }
    fi
    [[ $host == *.ts.net || $host =~ ^\[(fd7a|fd7b)[0-9A-Fa-f:%.]+\]$ ]] && { printf 'tailscale\n'; return; }

    if [[ $host =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
        first=${BASH_REMATCH[1]}
        second=${BASH_REMATCH[2]}
        if ((first == 10 || (first == 172 && second >= 16 && second <= 31) || (first == 192 && second == 168) || (first == 169 && second == 254))); then
            printf 'lan\n'
            return
        fi
    fi

    printf 'other\n'
}

while (($#)); do
    case $1 in
        --reconnect-model)
            (($# >= 2)) || { usage >&2; exit 2; }
            RECONNECT_MODEL=$2
            shift 2
            ;;
        --timeout)
            (($# >= 2)) || { usage >&2; exit 2; }
            RECONNECT_TIMEOUT=$2
            shift 2
            ;;
        --classify-transport)
            (($# == 2)) || { usage >&2; exit 2; }
            classify_transport "$2"
            exit 0
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            exit 2
            ;;
    esac
done

[[ $RECONNECT_TIMEOUT =~ ^[0-9]+$ && $RECONNECT_TIMEOUT -ge 5 && $RECONNECT_TIMEOUT -le 300 ]] || {
    printf 'invalid timeout: %s\n' "$RECONNECT_TIMEOUT" >&2
    exit 2
}

[[ -x $ADB ]] || fail "adb-not-executable"
[[ -r $CONFIG_DST ]] || fail "config-not-readable"
[[ -x $BIN_DST ]] || fail "deployed-binary-missing"
[[ -r $UNIT_DST ]] || fail "deployed-unit-missing"
cmp -s "$ROOT/bin/adb-device-keeper" "$BIN_DST" || fail "deployed-binary-drift"
cmp -s "$ROOT/systemd/user/adb-device-keeper.service" "$UNIT_DST" || fail "deployed-unit-drift"

[[ $(systemctl --user is-enabled "$SERVICE" 2>/dev/null) == enabled ]] || fail "service-not-enabled"
[[ $(systemctl --user is-active "$SERVICE" 2>/dev/null) == active ]] || fail "service-not-active"

props=$(systemctl --user show "$SERVICE" -p ExecStart -p Restart -p RestartUSec 2>/dev/null) || fail "systemd-show-failed"
grep -Fq "path=$BIN_DST" <<< "$props" || fail "unexpected-execstart"
grep -Fq 'Restart=always' <<< "$props" || fail "unexpected-restart-policy"
grep -Fq 'RestartUSec=30s' <<< "$props" || fail "unexpected-restart-delay"

if [[ -z $RECONNECT_MODEL ]]; then
    printf 'RUNTIME=PASS reconnect=not-requested\n'
    exit 0
fi

before=$($ADB devices -l) || fail "adb-devices-failed"
mapfile -t candidates < <(awk -v model="model:$RECONNECT_MODEL" '$2=="device" && index($0, model) {print $1}' <<< "$before")
((${#candidates[@]} == 1)) || fail "reconnect-model-not-unique-or-unavailable"
transport=${candidates[0]}
$ADB disconnect "$transport" >/dev/null || fail "adb-disconnect-failed"

deadline=$((SECONDS + RECONNECT_TIMEOUT))
found=''
while ((SECONDS < deadline)); do
    current=$($ADB devices -l 2>/dev/null || true)
    found=$(awk -v model="model:$RECONNECT_MODEL" '$2=="device" && index($0, model) {print $1; exit}' <<< "$current")
    [[ -n $found ]] && break
    sleep 5
done

[[ -n $found ]] || fail "reconnect-timeout"
path=$(classify_transport "$found")
printf 'RUNTIME=PASS model=%s reconnect_transport=%s reconnect_path=%s\n' "$RECONNECT_MODEL" "$found" "$path"
