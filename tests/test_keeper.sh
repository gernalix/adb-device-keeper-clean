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
is_usb_transport 'EXAMPLE_A_SERIAL'
! is_usb_transport '100.70.1.10:5555'
! is_usb_transport 'emulator-5554'
! is_usb_transport 'adb-EXAMPLE_A_SERIAL-abc._adb-tls-connect._tcp'

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

mkdir -p "$tmp/recovery-state"
cat > "$tmp/recovery-config" <<'EOF'
Example_A|ExampleVendor|Example Model A|example_a|EXAMPLE_A_SERIAL|adb-EXAMPLE_A_SERIAL-
Example_B|ExampleVendor|Example Model B|example_b|EXAMPLE_B_SERIAL|adb-EXAMPLE_B_SERIAL-
EOF
cat > "$tmp/adb" <<'EOF'
#!/usr/bin/env bash
args="$*"
case "$args" in
  'start-server') exit 0 ;;
  'devices') printf 'List of devices attached\nUSB_TRANSPORT device\n' ;;
  '-s USB_TRANSPORT shell getprop ro.product.manufacturer') printf 'ExampleVendor\n' ;;
  '-s USB_TRANSPORT shell getprop ro.product.model') printf 'Example Model A\n' ;;
  '-s USB_TRANSPORT shell getprop ro.product.device') printf 'example_a\n' ;;
  '-s USB_TRANSPORT shell getprop ro.serialno') printf 'EXAMPLE_A_SERIAL\n' ;;
  '-s USB_TRANSPORT tcpip 5555') printf 'restarting in TCP mode port: 5555\n' ;;
  'connect 100.70.1.10:5555') printf 'connected to 100.70.1.10:5555\n' ;;
  '-s 100.70.1.10:5555 shell getprop ro.product.manufacturer') printf 'ExampleVendor\n' ;;
  '-s 100.70.1.10:5555 shell getprop ro.product.model') printf 'Example Model A\n' ;;
  '-s 100.70.1.10:5555 shell getprop ro.product.device') printf 'example_a\n' ;;
  '-s 100.70.1.10:5555 shell getprop ro.serialno') printf 'EXAMPLE_A_SERIAL\n' ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$tmp/adb"
recovery_output=$(ADB_DEVICE_KEEPER_ADB="$tmp/adb" \
  ADB_DEVICE_KEEPER_TAILSCALE="$tmp/tailscale" \
  ADB_DEVICE_KEEPER_CONFIG="$tmp/recovery-config" \
  ADB_DEVICE_KEEPER_STATE_DIR="$tmp/recovery-state" \
  "$KEEPER" --recover-usb Example_A)
grep -Fq 'RECOVERY=PASS device=Example_A transport=100.70.1.10:5555' <<< "$recovery_output"

echo 'TESTS=PASS'
