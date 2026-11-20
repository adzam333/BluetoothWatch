# Bluetooth Watch

A local-only Mac menu-bar app that watches for newly discoverable Bluetooth
devices, with **Pair** and **Ignore** actions.

## Install on your Mac

Requires **macOS 26 or newer** and Xcode or Apple's Command Line Tools.
If you do not have the tools, run `xcode-select --install` first.
Copy this project folder to your Mac, open Terminal in it, and run:

```sh
bash scripts/build-app.sh --install
```

This builds the native app, signs it locally, installs it in
`~/Applications/Bluetooth Watch.app`, and opens it. Allow Bluetooth and
notifications when macOS asks. The app lives in the menu bar, not the Dock.
Enable **Launch at login** in its menu or window if desired; macOS may also
require approval under System Settings > General > Login Items & Extensions.
Keep the app at its installed path after registering launch at login.

Without `--install`, the script only creates `build/Bluetooth Watch.app`.
`CODE_SIGN_IDENTITY` optionally selects your own signing identity; the default
is ad-hoc signing for a local build. This is not a notarized public release.
No administrator access, cloud service, or third-party packages are needed.

## How it behaves

- The first **10 seconds of active discovery** are silent. Devices found during
  that interval stay excluded from notifications for the entire run, even if
  they disappear and return.
- A device first observed after the baseline triggers at most one alert per
  identity per run. Expand the macOS notification to reveal **Pair** and
  **Ignore**; those buttons are also in **Show Devices**.
- **Pair** attempts public-API pairing for supported Bluetooth Classic devices.
  Complete any PIN/passkey or confirmation prompt. Bluetooth LE and unsupported
  devices open Bluetooth settings instead. The app selects the corresponding
  row in its own list and shows the name/identifier; **Copy Name** helps you find
  it in Settings. It cannot reliably highlight a device inside Apple's Settings.
- **Ignore** dismisses the alert and moves the device to Ignored until restart.
  **Undo Ignore** restores its row without sending another alert. Neither
  ignoring nor scanning pairs or connects to a device.
- **Pause** stops discovery. **Resume** preserves history and finishes any
  remaining startup scan time. Devices that appeared while paused may be
  discovered after resuming. **Scan Now** requests discovery without resetting
  the baseline/history.
- Sleep, Bluetooth interruptions, and recovery require another quiet baseline;
  previously seen identities remain excluded. Errors and permissions are shown
  in the window rather than silently pretending to scan.
- Device observations and ignored identities are in memory only. Restarting
  clears them and begins another 10-second baseline. No discovery telemetry or
  device list is uploaded or written to disk by this app.

## Important limits

Discovery is **not proof that a device just entered pairing mode**. A device
already nearby might advertise late and trigger an alert after the short
baseline. Some devices are not observable, advertise no useful name, or require
vendor-specific setup. Bluetooth Classic inquiry repeats periodically, so
detection is not instant.

BLE identifiers can change, and dual-mode devices can appear once per transport.
Names are not used to merge devices: two different mice can have the same name.
An observation can also become stale before you press Pair; errors are shown
and Bluetooth Settings remains available. Opening Settings or establishing a
connection is never reported as successful pairing.

Notification delivery depends on macOS permissions, notification style, and
Focus. If no alerts appear, check System Settings > Notifications > Bluetooth
Watch; the device list remains available. For Bluetooth permission, check
System Settings > Privacy & Security > Bluetooth. Quit from the app's menu to
stop it completely, and turn off Launch at login before removing the app.

## Development

The app is a dependency-free Swift package. `open Package.swift` opens its
source in Xcode. Use the build script to run the real **app bundle**, rather
than `swift run`: notifications, privacy permissions, and login registration
depend on the app's identity and bundle metadata.

```sh
swift test
bash scripts/build-app.sh
open "build/Bluetooth Watch.app"
```

The portable XCTest target covers the ten-second boundary, startup exclusion,
deduplication, pause/resume, ignore/undo/restart, interrupted observation, direct
pairing decisions, settings fallback, outcomes, and cancellation.
It can run on Linux with Swift installed. The native executable is included
only on macOS. A GitHub Actions workflow builds/tests on `macos-latest` and
archives an app when this project is hosted in a GitHub repository.

**Verification status:** portable logic can be tested independently, but native
compilation and real Bluetooth/notification/login behavior must be verified on
a Mac. A Linux test run is not evidence that the macOS app compiles or that a
particular peripheral supports direct pairing.

Before relying on it, check on your Mac:

1. Launch with a discoverable device already nearby; it should be listed as a
   startup device without an alert, including when it returns later.
2. After the countdown, make a different device discoverable; confirm one alert,
   Pair/Ignore actions, correct device routing, and no repeated alert.
3. Exercise Classic pairing, any PIN/passkey prompts, cancellation, and a device
   disappearing mid-attempt. Check the BLE Settings handoff separately.
4. Ignore, undo, pause/resume, sleep/wake, and toggle Bluetooth off/on.
5. Deny/re-enable permissions, check Focus suppression, then enable launch at
   login and verify after logging back in.
