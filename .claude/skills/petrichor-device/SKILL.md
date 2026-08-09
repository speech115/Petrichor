---
name: petrichor-device
description: Build, install, launch and inspect the PetrichoriOS target on the physical iPhone, and push music files into the app's container from the command line. Use this whenever work needs to reach the real device — "поставь на телефон", "run it on my iPhone", "check it on the device", "залей треки", verifying playback, background audio, the lock screen, or anything that a simulator cannot answer. The normal `-destination 'platform=iOS,id=...'` path is broken on this machine and this skill routes around it, so reach for it instead of improvising xcodebuild invocations.
---

# Petrichor on the device

The iPhone runs iOS 27.0 beta; the installed Xcode is 26.6 and has no Developer
Disk Image for it. That single mismatch breaks the ordinary device workflow —
`xcodebuild -destination 'platform=iOS,id=<udid>'`, Xcode's Run button, and the
debugger all fail before they compile anything.

Everything else still works, because signing and installation do not need the
DDI. Build for a *generic* iOS device and hand the resulting `.app` to
`devicectl`. That is what this skill automates.

Do not try to "fix" the destination error by hunting for a matching DDI or by
downgrading the phone. The fix is an Xcode that supports iOS 27; until it ships,
this is the supported path, not a workaround to be replaced.

## Deploy

```bash
.claude/skills/petrichor-device/scripts/deploy.sh
```

Resolves the connected iPhone, builds, installs and launches. Useful flags:

| Flag | Effect |
|---|---|
| `--console` | stay attached and stream the app's stdout/stderr until it exits |
| `--no-launch` | install only |
| `--release` | build the Release configuration instead of Debug |

The script prints each command it runs, so when something breaks you see which
step broke rather than a silent failure.

**Reinstalling does not touch the library.** Same bundle id means `Documents`,
`Application Support` and `UserDefaults` all survive. The 20.9 GB library is
only lost if the app is deleted from the phone by hand. Deploy freely.

**Signing expires after 7 days** — the account is a free Apple ID. When the app
refuses to start with no useful message, that is usually why; deploy again.

## Push music without Finder

```bash
.claude/skills/petrichor-device/scripts/push-music.sh <local-folder> [remote-subpath]
```

Copies a folder into the app's `Documents` (default remote path `Documents/<folder-name>`),
using `devicectl device copy to --domain-type appDataContainer`. This removes the
Finder drag-and-drop dependency entirely — worth knowing, because loading test
material used to be the one manual step nobody could script.

Two things to keep in mind:

- **There is no delete.** `devicectl` can copy in and out, but cannot remove. A
  file pushed by mistake has to be removed through the app or by deleting the
  app — and deleting the app takes the whole library with it. Push deliberately.
- `--remove-existing-content` exists on `copy to` for directories and will wipe
  the destination. Never point it at `Documents`.

## Read back a file

```bash
xcrun devicectl device copy from --device "$(.claude/skills/petrichor-device/scripts/device-id.sh)" \
  --domain-type appDataContainer --domain-identifier org.Petrichor.ios \
  --source Documents/<path> --destination ./<local-path>
```

Useful for pulling the GRDB database off the phone when the on-device library
disagrees with what the code expects.

## What still does not work

- **The debugger.** No DDI means no `lldb` attach, so no breakpoints on device.
  `--console` gives stdout, and that is the whole debugging surface until Xcode
  catches up. Design device checks around printed state, not breakpoints.
- **`xcodebuild test` against the device.** Tests run on the simulator:
  `xcodebuild test -scheme PetrichoriOS -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max'`.

## Facts worth not re-deriving

| | |
|---|---|
| Scheme | `PetrichoriOS` |
| Bundle id | `org.Petrichor.ios` |
| Product | `Petrichor.app` |
| Team | `DQFRVE6G9U`, `Apple Development: borshov.v@gmail.com` |
| Phone | iPhone 16 Pro Max (iPhone17,2), iOS 27.0 |
| Xcode | 26.6, iOS SDK 26.5 |

The scripts resolve the device id and the built product path at run time rather
than hardcoding them, so a re-pair or a clean DerivedData does not break them.
