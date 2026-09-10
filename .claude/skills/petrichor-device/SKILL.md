---
name: petrichor-device
description: Build, refresh developer signing, install and launch PetrichoriOS on the physical iPhone, or copy music into its container. Use for "обнови подпись", device deployment and on-device playback checks.
---

# Petrichor on iPhone

## Deploy or refresh signing

Run from the repository root:

```bash
.claude/skills/petrichor-device/scripts/deploy.sh
```

Resolves the phone, builds with `-allowProvisioningUpdates`, installs and launches.
Flags: `--release`, `--no-launch`, `--console` (stays attached).

Xcode 26.6 lacks the Developer Disk Image for iOS 27 beta: use the script's
`generic/platform=iOS` + `devicectl` route, not a device build destination.
Do not repair the DDI. Debugging/device tests need matching Xcode; use simulator
tests and `--console` for device logs.

Reinstall the same `org.Petrichor.ios` bundle; never delete the app to refresh
signing. Reinstallation preserves its data; deletion removes the music library.

## Verify and recover

- For signing refreshes, read `CreationDate` and `ExpirationDate` with
  `security cms -D -i <app-path>/embedded.mobileprovision`; report actual expiry
  in the user's timezone. The install command prints the app path.
- If signing fails or the profile was not renewed, run:
  `xcodebuild -scheme PetrichoriOS -destination 'generic/platform=iOS' -configuration Debug -allowProvisioningUpdates clean build`
  (Release if requested). If it still reuses the old profile, move only the
  matching `.mobileprovision` from
  `~/Library/Developer/Xcode/UserData/Provisioning Profiles/` to a temporary backup
  and repeat once. Preserve other profiles; report failure if renewal still fails.
- If installation loses the CoreDevice connection, retry the printed install
  command once without rebuilding. If it fails again, report the error.
- After manual installation, launch with:
  `xcrun devicectl device process launch --device <device-id> --terminate-existing org.Petrichor.ios`.
  Require `App installed` and, unless `--no-launch` was requested, `Launched application`.
- For a signature/entitlements/trust launch error, check profile dates and
  `codesign --verify --deep --strict <app-path>`. If valid, ask the user to check
  developer trust in **Настройки → Основные → VPN и управление устройством**,
  then retry launch. These checks alone do not prove trust is the cause.

Report installation and launch separately; neither verifies playback or UI.

## Music and container files

```bash
.claude/skills/petrichor-device/scripts/push-music.sh <local-folder> [remote-subpath]
```

Default destination: `Documents/<folder-name>`. To read back a file:

```bash
xcrun devicectl device copy from --device "$(.claude/skills/petrichor-device/scripts/device-id.sh)" \
  --domain-type appDataContainer --domain-identifier org.Petrichor.ios \
  --source Documents/<path> --destination ./<local-path>
```

`devicectl` can copy but cannot delete individual container files. Never point
`copy to --remove-existing-content` at `Documents`: it wipes the destination.
