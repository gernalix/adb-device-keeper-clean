# adb-device-keeper

User systemd service that keeps allowlisted Android devices reachable through ADB wireless debugging on Fedora.

The keeper uses LAN/mDNS discovery for Android Wi-Fi debugging. Once a Tailscale ADB TCP endpoint is verified, it prefers that saved endpoint over stale Wi-Fi mDNS and falls back to LAN discovery if TCP reconnect fails. If the LAN path is not reachable and Tailscale already exposes the Android peer, it retries the discovered ADB port through the **matching device's** Tailscale IP and verifies Android identity before marking the device connected.

Without root, using ADB across mobile data first requires an authorized USB session and `adb tcpip 5555`; Tailscale itself does not start the Android ADB listener. Android normally resets this TCP mode after reboot. TCP port 5555 is not restricted to Tailscale, so avoid connecting to untrusted Wi-Fi while it is enabled.

## Assisted recovery after reboot

Stock Android does not let an ordinary app or Termux restore `adb tcpip 5555`
after a cold reboot. The keeper therefore provides a bounded USB recovery path
instead of claiming autonomous recovery:

1. Let Android finish booting, perform the first unlock, and make sure Tailscale
   is connected.
2. Connect the allowlisted phone by USB and accept its existing ADB host key if
   Android asks.
3. Run `adb-device-keeper --recover-usb DEVICE_NAME`, using the name from the
   private keeper config.
4. Disconnect USB only after `RECOVERY=PASS` reports the verified Tailscale
   endpoint.

The command accepts only one physical USB transport whose complete configured
identity matches the requested device. It starts TCP port 5555 through that USB
session, then reports success only after reconnecting through the matching
Tailscale peer and re-verifying the device identity. It does not install an
Android app, persist an unlock secret, change VPN settings, or make the listener
survive another reboot.

## Non-invasive operating runbook

Use the shell path first. It can inspect system state without changing the app
currently in the foreground. Every physical-device session must begin with the
MegaVault identity gate and the keeper's non-destructive runtime check:

```bash
ADB="$HOME/Android/Sdk/platform-tools/adb"
SERIAL='TAILSCALE_IP:5555'
python3 /home/daniele/MegaVault/tools/adb_device_gate.py \
  --target pixel --serial "$SERIAL"
bash scripts/runtime-check.sh
```

After both checks pass, passive commands such as `getprop`, `dumpsys power`,
`dumpsys display`, `dumpsys deviceidle`, and `dumpsys connectivity` are allowed
while the user is using another app. They must not launch an activity, send an
input event, wake or lock the display, or capture screen contents. Re-run the
identity gate before a later, separate device operation; do not treat an IP
address or a remembered ADB serial as identity.

The following require explicit user consent for the specific operation because
they can expose screen contents, take focus, or change connectivity: `scrcpy`,
screenshots or screen recording, UI Automator inspection/action, `adb shell
input`, `am start`, display wake/lock, changing Wi-Fi or Tailscale, and reboot.
Check display and keyguard state immediately before any approved UI operation.
Never automate or retain a PIN, password, fingerprint, or unlock pattern.

### Operating envelope and recovery

| State | Safe capability | Boundary or recovery |
| --- | --- | --- |
| Home Wi-Fi with Tailscale connected | Passive ADB shell and keeper checks | UI interaction still requires consent and an unlocked display. |
| Mobile data with Wi-Fi disabled | Passive ADB shell can work through the verified Tailscale endpoint while `adbd` still listens on TCP | Confirm Wi-Fi is really off and the VPN transport is cellular; no result from Wi-Fi proves this case. |
| Screen on with another app in front | Passive shell only | Do not open a window, inject input, inspect the UI tree, or capture the screen. |
| Screen off or Doze | Shell may remain available while Tailscale and `adbd` remain alive | Expect battery/network delay. Do not wake the display without consent. |
| Keyguard/PIN showing | Passive shell may remain available | Stop before GUI interaction; the user must unlock physically. |
| Tailscale interrupted | The Fedora keeper retries known, identity-verified endpoints | If the Android VPN is down, ADB cannot restore it. Ask the user to reconnect Tailscale; do not change VPN settings implicitly. |
| After Android reboot | No autonomous TCP recovery is promised | After boot, first physical unlock, and Tailscale reconnect, attach USB and run `adb-device-keeper --recover-usb DEVICE_NAME`. |
| Fedora suspended, powered off, or offline | None: the user service and remote-command bridge are unavailable | Resume or power on Fedora first. There is no phone-side replacement daemon. |

[ADB shell](https://developer.android.com/tools/adb) is the existing control
plane. [AndroidX UI Automator](https://developer.android.com/training/testing/other-components/ui-automator)
remains suitable for an explicitly authorized UI test, but it is not a passive
remote-control channel. [`scrcpy`](https://github.com/Genymobile/scrcpy) is a
maintained upstream option for a visible, consented session, not a background
automation mechanism; it was not installed as part of this workflow. Remote
Desktop Commander reaches the Fedora host, so it inherits the same host-awake
and ADB/[Tailscale](https://tailscale.com/docs/install/android) limits rather
than bypassing them.

### Live acceptance snapshot (2026-10-17)

The allowlisted Pixel 8a identity gate passed over the Tailscale ADB endpoint.
On the observed home-Wi-Fi state, Android reported boot complete, TCP port 5555,
Tailscale validated, screen on, and keyguard not showing. Five passive `adb shell
true` samples completed in 47--68 ms. The Fedora user service was active with no
restart and `scripts/runtime-check.sh` passed. The same observation did **not**
prove Wi-Fi-off mobile data, screen-off/Doze, a real Tailscale interruption, or
post-reboot recovery; those cases require a changed physical state or explicit
consent and must remain reported as untested until then.

## Runtime paths

- Script: `$HOME/.local/bin/adb-device-keeper`
- User unit: `$HOME/.config/systemd/user/adb-device-keeper.service`
- Config: `$HOME/.config/codex/secrets/adb-device-keeper/config`
- State: `$HOME/.local/state/adb-device-keeper/`

This repository is prepared as the canonical source of the ADB device keeper. Original authorship and development history are preserved privately; public commit attribution is explicitly redacted. Runtime activation follows a separate owner-controlled cutover. Runtime config remains local and is never committed.

## Config format

Copy `config/config.example` to `$HOME/.config/codex/secrets/adb-device-keeper/config` and fill one allowlisted device per line:

```text
name|manufacturer|model|product_device|hardware_serial|mdns_instance_prefix
```

`mdns_instance_prefix` must be `adb-<hardware_serial>-`.

## Deterministic verification

```bash
bash tests/test_keeper.sh
```

CI runs the same test. It covers shell syntax, Tailscale CGNAT endpoint validation, device-specific Tailscale peer mapping, preservation of the discovered ADB port during fallback, cross-device candidate rejection, sanitized example config, systemd restart settings, deploy restart semantics, runtime-path classification, and absence of unrelated WhatsApp logic.

## Deploy

From a clean checkout:

```bash
bash scripts/deploy.sh
```

The deploy helper installs only the versioned script and user unit, preserves the local secret/config file, reloads user systemd, enables the service, **restarts it even when it was already active**, and then runs the bounded runtime verifier. This ensures the live process is started from the newly deployed canonical source rather than merely leaving an older active process in memory.

## Runtime verification

For a non-destructive runtime check:

```bash
bash scripts/runtime-check.sh
```

It verifies that the deployed binary and unit exactly match the checkout, the config is readable, and the user service is enabled/active with the expected `ExecStart` and restart policy. The journal is printed only on failure, avoiding stale/noisy history during healthy checks.

For one controlled disconnect/reconnect smoke of an example device:

```bash
bash scripts/runtime-check.sh --reconnect-model Example_A
```

The final line reports the actual reconnect transport and classifies it as `lan`, `tailscale`, `mdns`, or `other`, so a normal LAN recovery is not mistakenly reported as proof of a Tailscale fallback. A real reconnect smoke remains intentionally local because it requires the physical Android device, live ADB pairing state, and the Fedora/Tailscale runtime.

## Version and local command integration

`NV.txt` retains the existing project version. Ordinary commits do not increment it. Local command bindings and host identities are managed privately by the integration owner; runtime configuration and those bindings are never published in this repository.

Canonical integrations retain the tested commit bytes through fast-forward updates.
