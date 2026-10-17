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
