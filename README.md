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
Click its menu bar icon to see discovered devices. Enable **Launch at login**
there if desired; macOS may also
require approval under System Settings > General > Login Items & Extensions.
Keep the app at its installed path after registering launch at login.

Without `--install`, the script only creates `build/Bluetooth Watch.app`.
`CODE_SIGN_IDENTITY` optionally selects your own signing identity; the default
is ad-hoc signing for a local build. This is not a notarized public release.
Ad-hoc signatures change with every rebuild, so macOS may stop honoring the
previous Bluetooth permission ("Bluetooth access is denied" after a rebuild).
Reset it with `tccutil reset BluetoothAlways local.bluetoothwatch.app` and
approve the prompt again, or sign with a stable `CODE_SIGN_IDENTITY`. Keep only
one installed copy; other copies with the same bundle ID (for example in
`/Applications`) may be launched instead. To receive alerts during a Focus, add
Bluetooth Watch to that Focus's allowed apps; Time Sensitive alerts need an
Apple-provisioned entitlement that local ad-hoc builds cannot use.
No administrator access, cloud service, or third-party packages are needed.

### Stable local signing

To keep macOS permissions associated with one local signing identity across
rebuilds, create a self-signed code-signing certificate in Keychain Access:

1. Open **Keychain Access**, select the **login** keychain, then choose
   **Certificate Assistant > Create a Certificate**.
2. Give it a stable name such as **Bluetooth Watch Local Signing**. Choose
   **Self Signed Root** as the identity type and **Code Signing** as the
   certificate type, then finish the assistant and save it to the login
   keychain.
3. If `security find-identity` reports the certificate as untrusted, export
   its public certificate from Keychain Access (**File > Export Items**) and
   trust it for the code-signing policy only:

   ```sh
   security add-trusted-cert -r trustRoot -p codeSign \
     -k "$HOME/Library/Keychains/login.keychain-db" /path/to/certificate.cer
   ```

4. Confirm that macOS lists a valid code-signing identity:

   ```sh
   security find-identity -v -p codesigning
   ```

5. Build and install using the certificate's exact name:

   ```sh
   CODE_SIGN_IDENTITY="Bluetooth Watch Local Signing" bash scripts/build-app.sh --install
   ```

Use the same identity name for later rebuilds. The build script prints the
identity used and still verifies the resulting signature. A self-signed local
build is not notarized or intended for distribution. If Bluetooth Watch was
previously granted access while ad-hoc signed, macOS may ask once more after
switching identities; allow it, then rebuild with the same identity to check
that the grant persists.

**Verification on this Mac (2026-11-22):** The self-signed
**Bluetooth Watch Local Signing** identity was used for two consecutive
builds/installs. Bluetooth access was approved after the first install; the
second app process started scanning without a Bluetooth-access error or another
permission prompt. `security find-identity -v -p codesigning` reports the
identity as valid. This verifies local permission persistence for this
identity and machine only.

**BLE scan CPU spot check (2026-11-22):** While the app was scanning, five
consecutive `top` samples at five-second intervals ranged from 2.4% to 2.9%
CPU. This is a spot measurement, not an A/B comparison with duplicate reports
disabled; battery impact was not separately measured.

## How it behaves

- The first **10 seconds of active discovery** are silent. Devices found during
  that interval stay excluded from notifications for the entire run, even if
  they disappear and return.
- A device first observed after the baseline triggers at most one alert per
  identity per run. macOS controls notification layout; **Pair** and
  **Ignore** may be behind **Options** or require expanding the notification.
  Clicking the alert opens the menu bar list at that device if it has a name,
  with the same buttons.
- The list shows only devices with nonempty names, including in the Ignored
  section. Unnamed devices remain in the discovery history and appear if a
  name is subsequently reported.
- **Hide baseline devices** hides devices first observed during a quiet
  discovery baseline, including a recovery baseline after sleep or a scanner
  interruption. This display-only checkbox is saved across launches; it does
  not change alerts, discovery history, or ignored state. Explicitly selecting
  a hidden device temporarily reveals its row, and turning the checkbox off
  restores all baseline rows.
- Search devices by name or identifier, or filter the list to named devices,
  Bluetooth Classic, Bluetooth LE, or Ignored. Selecting a device clears the
  search and switches to the relevant list section.
- Only Bluetooth Classic devices and Bluetooth LE devices that report a name
  alert. Anonymous BLE advertisers (often phones, watches and trackers rotating
  private addresses) do not appear in the list or notify. A BLE device first
  seen without a name alerts once if a name arrives later, unless its discovery
  history excludes the alert. Unnamed Classic devices can still notify; use the
  notification actions or Bluetooth Settings until they report a name.
- BLE scanning requests duplicate advertisements so macOS can report a later
  scan-response name. Bluetooth Watch limits repeated delivery to once every
  three seconds per identity, except that a newly reported name is delivered
  immediately. This reduces app-side update work; radio power remains managed
  by macOS, and no quantitative battery-impact measurement is available yet.
- **Pair** attempts public-API pairing for supported Bluetooth Classic devices.
  Complete any PIN/passkey or confirmation prompt.
- **Pair** on a Bluetooth LE device is experimental. macOS has no public API to
  pair an LE device directly, so the app connects and reads the device's
  characteristics; if one requires encryption, macOS shows its own pairing
  prompt. The app cannot reliably confirm that the selected BLE device was
  paired, so it opens Bluetooth settings to check after the attempt, even if
  macOS's pairing prompt succeeded. A connection or successful read alone
  never counts as pairing. If the
  device can't be connected, exposes nothing that triggers pairing, or pairing
  can't be confirmed within 60 seconds, the app disconnects and opens Bluetooth
  settings with the reason. Mice, keyboards and other HID devices usually pair
  only through Settings, because their secure services are reserved by macOS.
- Unsupported devices open Bluetooth settings. The app selects the corresponding
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
  in the menu bar list rather than silently pretending to scan.
- The menu bar icon distinguishes active scanning, unconfirmed Classic
  coverage, paused scanning, and scanner errors. Bluetooth and notification
  settings shortcuts appear where relevant. On returning to Bluetooth Watch
  from System Settings, scanner availability and notification authorization are
  checked again.
- Device observations and ignored identities are in memory only. Restarting
  clears them and begins another 10-second baseline. No discovery telemetry or
  device list is uploaded or written to disk by this app.

## Important limits

Discovery is **not proof that a device just entered pairing mode**. A device
already nearby might advertise late and trigger an alert after the short
baseline. Some devices are not observable, advertise no useful name, or require
vendor-specific setup. Bluetooth Classic inquiry repeats periodically, so
detection is not instant.

On macOS 26, `IOBluetoothDeviceInquiry` was observed (on one Mac) never calling
`deviceInquiryStarted` and ending each system inquiry cycle with the
undocumented completion code `0x1`. The app treats only `0x1` after the inquiry
went live as a routine cycle end; any other failure after going live is shown
and scanning stops until you press Retry, which starts a new quiet baseline.
Failures before an inquiry goes live are retried at most three times. If
`start()` succeeds and no failure arrives within 2 seconds, scanning proceeds,
but that only proves no early failure. Until macOS reports a Classic device the
status says Classic discovery is unconfirmed. The baseline still starts in that
state, otherwise it would never complete where no Classic devices are nearby,
so late-reporting Classic devices may alert after the baseline.

BLE identifiers can change, and dual-mode devices can appear once per transport.
Names are not used to merge devices: two different mice can have the same name.
An observation can also become stale before you press Pair; errors are shown
and Bluetooth Settings remains available. Opening Settings or establishing a
connection is never reported as successful pairing.

Notification delivery depends on macOS permissions, notification style, and
Focus. The app registers Pair and Ignore actions, but macOS does not provide a
public API for forcing them to appear inline on every collapsed banner. Choose
the **Alerts** style in System Settings > Notifications > Bluetooth Watch for
persistent notifications; this still does not guarantee inline action buttons.
Clicking the notification opens the selected device in the app when it has a
name, where both actions remain available. If no alerts appear, check System
Settings > Notifications > Bluetooth Watch; the device list remains available.
For Bluetooth permission, check System Settings > Privacy & Security >
Bluetooth. Quit from the app's menu to stop it completely, and turn off Launch
at login before removing the app.

## Development

The app is a dependency-free Swift package. `open Package.swift` opens its
source in Xcode. Use the build script to run the real **app bundle**, rather
than `swift run`: notifications, privacy permissions, and login registration
depend on the app's identity and bundle metadata.

```sh
bash scripts/test.sh
bash scripts/build-app.sh
open "build/Bluetooth Watch.app"
```

`scripts/test.sh` runs `swift test`, adding the Swift Testing search paths that
Command Line Tools-only setups need (XCTest requires full Xcode).

The Swift Testing targets cover the ten-second boundary, startup exclusion,
deduplication, pause/resume, ignore/undo/restart, interrupted observation, direct
pairing decisions, BLE pairing probe decisions, settings fallback,
outcomes, cancellation, stale scanner generations, recovery baselines, and
notification run routing. AppModel integration tests inject fake scanner and
notification services and run on macOS without Bluetooth hardware or permission
prompts. The core tests can also run on Linux with Swift installed; the native
app and integration tests are included only on macOS. A GitHub Actions workflow builds/tests on `macos-latest` and
archives an app when this project is hosted in a GitHub repository.

**Verification status:** portable logic can be tested independently, but native
compilation and real Bluetooth/notification/login behavior must be verified on
a Mac. A Linux test run is not evidence that the macOS app compiles or that a
particular peripheral supports direct pairing.

Scanner status and inquiry error codes are available in macOS Console under
subsystem `local.bluetoothwatch.app`, or in Terminal:

```sh
/usr/bin/log show --last 10m --style compact --predicate 'subsystem == "local.bluetoothwatch.app"'
```

These local diagnostic logs do not include device names or identifiers. The
status message in the menu bar list wraps to display the full error and can be
selected and copied.

Before relying on it, check on your Mac:

1. Launch with a discoverable device already nearby; it should be listed as a
   startup device without an alert, including when it returns later.
2. After the countdown, make a different device discoverable; confirm one alert,
   Pair/Ignore actions, correct device routing, and no repeated alert.
3. Exercise Classic pairing, any PIN/passkey prompts, cancellation, and a device
   disappearing mid-attempt. Check BLE Pair separately: with a device that
   requires encryption (look for a macOS prompt, then check pairing in Settings),
   and with a mouse or keyboard (expect the Settings handoff with a reason).
4. Ignore, undo, pause/resume, sleep/wake, and toggle Bluetooth off/on.
5. Deny/re-enable permissions, check Focus suppression, then enable launch at
   login and verify after logging back in.
