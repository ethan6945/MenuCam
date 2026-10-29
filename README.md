# MenuCam

A small macOS background camera recorder with English UI and private Tailscale web control.

**[Download the latest Mac app](https://github.com/ethan6945/MenuCam/releases/latest)** · Apple Silicon · macOS 13+

## Screenshots

### Native control window

Version 1.6 opens a compact window with Tailscale and localhost links, Copy Control Link and Quit. There is no menu bar/status icon. Closing the window keeps the authenticated server running; opening the app again restores the same window.

### Web control and first-device authorization

<img src="docs/screenshots/web-control.png" width="320" alt="English recording controls with live timer"> <img src="docs/screenshots/web-authorization.png" width="320" alt="English device authorization page">

### After saving

<img src="docs/screenshots/web-saved.png" width="320" alt="Timer reset to zero with duration and Movies-relative save location">

Web screenshots show the earlier control layout using demonstration data; version 1.6 also adds a small Quit button. No camera photos or access keys are shown.

## Get started

1. Download the ZIP, unzip it, and open `MenuCam.app`.
2. Allow camera access on the Mac; allow the microphone if you want audio.
3. Connect the Mac and phone to the same Tailscale network.
4. The launch window shows the Tailscale control address and a localhost address for this Mac.
5. Select **Copy Control Link** and open that full link on your phone. Without Tailscale, it copies the localhost link for this Mac only.
6. If **Device Authorization** appears, paste the control link or access key and select **Authorize & Connect**.
7. Bookmark the full link for next time; the browser remembers authorized access.

## How to use

- **Open web control:** click the address in the Mac window.
- **Start recording:** select **Start Recording** on the web page.
- **Stop from the web:** select **Stop & Save**.
- **Stop from the Mac:** press a keyboard key while blackout mode is active.
- **Take a current photo:** quickly tap the web timer three times, with less than 450 ms between taps.
- **Hide the photo:** tap the image once to clear it and show the timer again.
- **Take a photo while recording:** the existing video stream supplies the image; recording and timing continue uninterrupted.
- **Take a photo while idle:** the camera opens briefly for one photo, then closes; no recording or blackout starts.
- **Find a saved video:** read **Saved to** below the timer; the default path starts at `Movies/MenuCam/`.
- **Check the take length:** read **Duration** in the saved result; saving time is excluded.
- **Start another take:** the main timer resets to `00:00:00` after saving.
- **Quit the app:** select **Quit** in the Mac window or the small **Quit** button on the authenticated web page. Both save any active recording and restore settings before exiting. Reopen the Mac app to restart the server.

## What happens during recording

- Black windows cover the Mac screens.
- Supported display brightness is set to zero and automatic brightness is turned off.
- System audio output is muted and supported keyboard backlight is turned off.
- Stopping restores the original display, audio and keyboard settings.
- Closing the window or stopping a take keeps the web server online.
- Photos stay in memory only; they are not saved as photo files or browser storage.
- Videos are saved locally as mirrored MOV files, with microphone audio when permitted.
- Camera startup black frames are skipped; cold camera photos may take several seconds.
- Browser tabs, bookmarks and phone home-screen shortcuts use the App's logo.
- Only one MenuCam instance runs, avoiding competing web servers.

## Requirements and access

- Apple Silicon Mac, macOS 13+, with a camera.
- Tailscale on both devices; allow TCP **8765** to the Mac in the tailnet ACLs.
- Both this Mac and the phone use the same Tailscale address.
- Full control links contain `#key=...`; treat them like passwords.
- The server binds only to Tailscale IPv4 `utun` addresses and `127.0.0.1` (localhost), never ordinary LAN or wildcard interfaces. Both require the same persistent access key.
- MenuCam does not configure port forwarding, Serve or Funnel. Keep the service inside the tailnet.
- The app is ad-hoc signed, not notarized; macOS may require an explicit Open confirmation.

## Support

If MenuCam is useful to you, consider buying me a coffee.

[![Buy Me a Coffee](https://img.shields.io/badge/Buy%20Me%20a%20Coffee-FFDD00?style=for-the-badge&logo=buymeacoffee&logoColor=black)](https://buymeacoffee.com/ethan6945)
