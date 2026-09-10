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

The script resolves the connected phone, builds with `-allowProvisioningUpdates`,
installs and launches. Flags: `--release`, `--no-launch`, `--console` (stays attached).
For «обнови подпись», proceed through launch without extra clarification.

Use `generic/platform=iOS` plus `devicectl`: this machine's Xcode 26.6 lacks the
Developer Disk Image for the phone's iOS 27 beta. Do not use a device UDID as the
build destination or attempt to repair the DDI. Tests run on the simulator.

Reinstall the same `org.Petrichor.ios` bundle; never delete the app to refresh
signing. Reinstallation preserves its data; deletion removes the music library.

## Verify and recover

- After refreshing signing, decode the built app's `embedded.mobileprovision`
  with `security cms -D -i <path>` and inspect `CreationDate` and `ExpirationDate`.
  Report the actual expiry in the user's timezone; free-account profiles usually
  last seven days. Get the app path from the script output or `-showBuildSettings`.
- If the profile is missing or expired after the build, run once:
  `xcodebuild -scheme PetrichoriOS -destination 'generic/platform=iOS' -configuration Debug -allowProvisioningUpdates clean build`.
  Use Release if requested. If Xcode still reuses an expired profile, move only
  that matching `.mobileprovision` from
  `~/Library/Developer/Xcode/UserData/Provisioning Profiles/` to a temporary backup,
  then repeat the clean build. Do not clear other profiles.
- For a connection reset or invalidated CoreDevice channel during installation,
  retry the printed `devicectl device install app` command once. Do not rebuild.
  If the retry fails, report the error and ask for connection/unlock only when
  the device state requires it.
- Installation and launch are separate results. After a recovered installation,
  run `xcrun devicectl device process launch --device <device-id> --terminate-existing org.Petrichor.ios`.
  Success requires both `App installed` and `Launched application`.
- If launch reports invalid signature, inadequate entitlements or an untrusted
  profile, first run `codesign --verify --deep --strict <app-path>` and check the
  profile dates. If valid, ask the user to confirm developer trust at
  **Настройки → Основные → VPN и управление устройством**, then retry launch.
  Report "installed; launch blocked" until launch actually succeeds.

Do not claim playback or UI verification from installation/launch output alone.
The debugger and device tests remain unavailable with this DDI mismatch;
`--console` provides app logs.

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
