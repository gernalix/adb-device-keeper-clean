#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
KEEPER="$ROOT/bin/adb-device-keeper"
DEPLOY="$ROOT/scripts/deploy.sh"
RUNTIME_CHECK="$ROOT/scripts/runtime-check.sh"
UNIT="$ROOT/systemd/user/adb-device-keeper.service"
CONFIG_EXAMPLE="$ROOT/config/config.example"

bash -n "$KEEPER"
bash -n "$DEPLOY"
bash -n "$RUNTIME_CHECK"
! grep -qi 'whatsapp' "$KEEPER"
! grep -Eq '([0-9]{1,3}\.){3}[0-9]{1,3}' "$CONFIG_EXAMPLE"
grep -Fq 'ExecStart=%h/.local/bin/adb-device-keeper --daemon' "$UNIT"
grep -Fq 'Restart=always' "$UNIT"
grep -Fq 'RestartSec=30' "$UNIT"
grep -Fq 'systemctl --user restart adb-device-keeper.service' "$DEPLOY"
! grep -Fq 'enable --now' "$DEPLOY"
grep -Fq 'rev-parse --is-inside-work-tree' "$DEPLOY"
grep -Fq 'bash "$RUNTIME_CHECK" "$@"' "$DEPLOY"
[[ $(bash "$RUNTIME_CHECK" --classify-transport '100.64.0.1:37123') == tailscale ]]
[[ $(bash "$RUNTIME_CHECK" --classify-transport '100.127.255.254:65535') == tailscale ]]
[[ $(bash "$RUNTIME_CHECK" --classify-transport '192.168.1.37:41619') == lan ]]
[[ $(bash "$RUNTIME_CHECK" --classify-transport 'adb-SERIAL-abc._adb-tls-connect._tcp') == mdns ]]
[[ $(bash "$RUNTIME_CHECK" --classify-transport '203.0.113.7:5555') == other ]]

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/state"
cat > "$tmp/tailscale" <<'EOF'
#!/usr/bin/env bash
if [[ ${1:-} == status ]]; then
  printf '%s\n' \
    '100.70.1.10 example-a user@ linux -' \
    '100.70.1.20 example-b user@ linux -'
fi
EOF
chmod +x "$tmp/tailscale"

ADB_DEVICE_KEEPER_ADB=/bin/true \
ADB_DEVICE_KEEPER_TAILSCALE="$tmp/tailscale" \
ADB_DEVICE_KEEPER_CONFIG="$CONFIG_EXAMPLE" \
ADB_DEVICE_KEEPER_STATE_DIR="$tmp/state" \
source "$KEEPER"

DEVICE_NAME=(Example_A Example_B)
HARDWARE_SERIAL=(EXAMPLE_A_SERIAL EXAMPLE_B_SERIAL)
MDNS_PREFIX=(adb-EXAMPLE_A_SERIAL- adb-EXAMPLE_B_SERIAL-)
DEVICE_COUNT=2

is_tailscale_endpoint '100.64.0.1:37123'
is_tailscale_endpoint '100.127.255.254:65535'
! is_tailscale_endpoint '100.128.0.1:37123'
! is_tailscale_endpoint '100.70.1.10:0'
[[ $(tailscale_ip_for_device 0) == '100.70.1.10' ]]
[[ $(tailscale_ip_for_device 1) == '100.70.1.20' ]]
[[ $(tailscale_endpoint_for 0 '192.168.1.5:37123') == '100.70.1.10:37123' ]]
[[ $(tailscale_endpoint_for 1 '192.168.1.6:41234') == '100.70.1.20:41234' ]]
transport_is_candidate 0 '100.70.1.10:37123'
! transport_is_candidate 1 '100.70.1.10:37123'
transport_is_candidate 1 '100.70.1.20:41234'
! transport_is_candidate 0 '100.70.1.20:41234'

DISCOVERED_ENDPOINT=('192.168.1.5:41234' '')
write_state 0 endpoint '100.70.1.10:5555'
[[ $(select_endpoint 0) == '100.70.1.10:5555' ]]
remember_tailscale_endpoint 0 '100.70.1.10:5555'
write_state 0 endpoint '192.168.1.5:41234'
[[ $(preferred_tailscale_endpoint 0) == '100.70.1.10:5555' ]]
[[ $(select_endpoint 0) == '100.70.1.10:5555' ]]
[[ $(select_commit_endpoint '100.70.1.10:5555' '192.168.1.5:41234') == '100.70.1.10:5555' ]]
[[ $(select_commit_endpoint 'EXAMPLE_A_SERIAL' '192.168.1.5:41234') == '192.168.1.5:41234' ]]
rm -f "$(state_file 0 tailscale_endpoint)"
write_state 0 endpoint '100.70.1.10:5555'
commit_endpoint 0 '192.168.1.5:41234'
[[ $(preferred_tailscale_endpoint 0) == '100.70.1.10:5555' ]]
rm -f "$(state_file 0 tailscale_endpoint)"
write_state 0 endpoint '100.70.1.99:5555'
[[ $(select_endpoint 0) == '192.168.1.5:41234' ]]
DISCOVERED_ENDPOINT=("" "")
! select_endpoint 0 >/dev/null
DISCOVERED_ENDPOINT=('192.168.1.5:41234' '')
write_state 0 endpoint '192.168.1.6:30000'
[[ $(select_endpoint 0) == '192.168.1.5:41234' ]]
DISCOVERED_ENDPOINT=("" "")
[[ $(select_endpoint 0) == '192.168.1.6:30000' ]]

echo 'TESTS=PASS'
