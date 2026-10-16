# adb-device-keeper

User systemd service that keeps allowlisted Android devices reachable through ADB wireless debugging on Fedora.

The keeper tries the configured LAN/mDNS endpoint first. If the LAN path is not reachable and Tailscale already exposes the Android peer, it retries the same ADB wireless debugging port through the **matching device's** Tailscale IP and verifies Android identity before marking the device connected.

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
