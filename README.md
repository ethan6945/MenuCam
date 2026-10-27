# MenuCam

A native macOS menu bar camera recorder with authenticated Tailscale web control.

## Features

- Compact menu bar popover: control link and Quit.
- Mobile web page: start/stop recording and live elapsed time. After saving, the main timer resets to zero and the summary retains the take duration and home-relative save path (starting at Movies for the default folder). Saving time is excluded from the take duration.
- Triple-tap the web clock to display a current camera photo in place of the clock; tap the photo to restore the clock. Works during recording and while idle.
- Idle photos use a temporary camera-only session: no recording, microphone, black screen, volume or brightness changes. The camera is released after capture.
- During recording, full-display black windows cover the screens; supported display brightness goes to zero, automatic brightness is disabled, system output is muted and keyboard backlight is turned off.
- A keyboard event stops the take, dismisses black windows and restores the previous settings. The web server stays running.
- Mirrored local MOV recording, optional microphone audio, gentle low-light enhancement, one-pass focus locking where supported, disk-space checks and camera interruption handling.
- Rejects initial all-black camera frames and waits briefly for exposure settling before an idle photo.
- Photos are handled in memory, are not saved as photo files or browser storage, and are removed from the page on dismissal.

## Requirements

- Apple Silicon Mac, macOS 13 or later.
- Built-in camera and macOS camera permission. Microphone permission is optional for recording with sound.
- Tailscale on the Mac and controlling device, in the same tailnet. ACLs must allow TCP 8765 to the Mac.
- Xcode Command Line Tools to build from source.

## Run

Download the Apple Silicon app ZIP from [Releases](https://github.com/ethan6945/MenuCam/releases), unzip it and open `MenuCam.app`. The app is ad-hoc signed, not notarized; macOS may require an explicit Open confirmation.

Click the menu bar icon. The popover shows this Mac's Tailscale control address. Click to open it, or right-click the address to copy the full authenticated link to your phone. The browser remembers the credential for later visits. The full link includes a `#key=...` fragment; copying or bookmarking it preserves access on a new device. A fresh browser opening the bare address shows a device authorization form. Paste the full control link or 64-character access key and select Authorize and Connect. Previously authorized browsers open controls directly. Treat the full link as a password.

The app listens only on detected Tailscale IPv4 `utun` interfaces in `100.64.0.0/10`, on port **8765**. Both this Mac and the phone use the same address. It does not bind to ordinary LAN interfaces or localhost, configure port forwarding, or enable Tailscale Serve/Funnel. Without Tailscale, the popover waits for a connection.

The server runs while MenuCam remains open. Closing the popover or stopping a recording does not stop it.

### Web photo

Quickly click/tap the clock three times, with less than 450 ms between taps. The clock is replaced by one current camera image; click that image to discard it and restore the clock. Recording continues if a take is active.

A cold camera start can take several seconds. First-time camera permission must be granted on the Mac. A missing or persistently black camera frame returns an error instead of a misleading black photo.

## Build

```sh
./build.command
./start.command
```

Build produces `MenuCam.app` in this directory, targeting Apple Silicon and macOS 13+. It uses system frameworks only; no third-party packages or telemetry.

## Verify

Connect Tailscale before running HTTP integration checks:

```sh
./verify.command
./verify.command --hardware
./verify.command --blackout
```

The default checks use synthetic audio/video, a separate HTTP test port, and simulated display settings. They do not use the camera. `--hardware` briefly changes actual audio/keyboard/display brightness and restores it. `--blackout` briefly covers the screens with black windows and posts a keyboard event to verify recovery and continued HTTP availability.

Current validation includes synthetic MOV/audio/mirror/low-light tests; authenticated HTTP and icon responses; browser photo display/dismissal; and real idle-camera capture. A complete physical-camera recording and phone-to-Mac end-to-end workflow have not been exhaustively tested.

## Settings and recovery

- Recordings default to `~/Movies/MenuCam`. Existing saved folder preferences remain supported.
- The random 32-byte web credential lives in `~/Library/Application Support/MenuCam/remote-key`, with file permissions `0600` and directory permissions `0700`. It is generated on the user's Mac and is not bundled with the app.
- Initial audio, keyboard and display settings are journaled locally before changes. Stop, failure and normal exit attempt restoration. After a crash or force-quit, relaunch MenuCam to retry recovery; unplugged devices may require another retry.
- Display/keyboard brightness controls use private macOS interfaces. Future OS releases may change them. Some third-party external displays cannot be dimmed in hardware, but black windows still cover them.
- macOS-reserved keys remain under system control. Screen topology changes or app deactivation end a take so stale black overlays do not remain.
- Screen light is not camera illumination: setting screen brightness to zero can make a screen-lit room genuinely darker.

## HTTP interface

All API requests require `Authorization: Bearer <key>`. Responses use `Cache-Control: no-store`; cross-origin requests are denied.

| Endpoint | Method | Result |
| --- | --- | --- |
| `/api/status` | GET | Recording state, busy state, phase and elapsed time |
| `/api/start` | POST | Start a recording |
| `/api/stop` | POST | Stop and save the current take |
| `/api/snapshot` | GET | One JPEG from the current take or a temporary idle camera session |

Requests must have empty bodies. Keep this HTTP service inside the tailnet; do not proxy it to the public internet.
