# T&S — Transcribe & Send

A native macOS menu-bar app for sending voice transcripts and selected screenshots between two Macs over Tailscale. Record locally with Superwhisper, even while a remote desktop has focus. T&S delivers the completed text to the other Mac’s clipboard and can paste it into the selected text field.

## What it does

- **Voice:** press Option–Space to start, press again to stop. Hold-to-talk is also available. Superwhisper handles recording and transcription, including your selected Bluetooth microphone.
- **Automatic paste:** optional on both Macs. Paste happens after the receiver confirms the clipboard. T&S never sends Return.
- **Screenshots:** enable Copy screenshots, then Command–Shift–3 selects a region of your local display. The image goes to both clipboards; paste images manually.
- **Switch direction:** Command–Option–Shift–S changes this Mac between **TX** (send) and **RX** (receive). Set your own combination in **Shortcuts & app**. The original T&S status indicator remains in the menu bar. After a successful switch shortcut, TX/RX appears for half a second to confirm the selected mode.
- **One connection:** the same peer and shared pairing key work in either direction. Only one mode is active on each Mac. Set the other Mac to the opposite mode.

T&S requires **macOS 14 or later**, **Tailscale** connected on both Macs, and **Superwhisper 2.16.3 or later** on every Mac that records voice. Superwhisper is separately licensed; it and Tailscale are not included. Jump Desktop is optional: T&S can be used with other remote-desktop clients or directly between Macs.

## Install or build

This repository is a source release. It does not promise an Apple-notarized download. Build locally using Xcode Command Line Tools with Swift 5.10 or later:

```sh
cd transcribe-and-send
TS_ALLOW_ADHOC=1 bash scripts/build.sh
open dist/0.4.1
```

Move the app into Applications and run that copy. Ad-hoc signing is an explicit local-build option; updating such a build may require renewing its macOS privacy grants. For stable signing across updates, set `TS_SIGNING_IDENTITY` to your own Apple signing identity instead. No certificate or credential is shipped. See [release instructions](docs/RELEASING.md) before distributing binaries.

## Pair your Macs

1. Connect Tailscale on both Macs and open **T&S → Settings → Connection**. **Detect** fills in this Mac’s active Tailscale IPv4 address. If multiple addresses are present, choose the intended one in Advanced connection settings.
2. On the first Mac, choose **Create & copy pairing code**. Transfer this code privately to the second Mac, paste it into **Other Mac’s code**, choose **Review pairing**, compare the address/fingerprint, and confirm.
3. On the second Mac, choose **Copy this Mac’s pairing code**. Paste that code back into T&S on the first Mac and confirm. Both now share a key and know the other’s address.
4. Put the receiving Mac in **RX**. Keep the Mac you’re using in **TX** and choose **Test saved connection**. Success means the peer authenticated; the probe does not change its clipboard.

Pairing codes contain a shared secret, not a public key. Do not post them in issues or share them with third parties. The code does not expire; replacing the shared key invalidates it. T&S marks copies transient/concealed for compatible clipboard managers, but other clipboard-sync software may still copy them. Clear the clipboard after pairing if needed.

Advanced connection settings support entering the shared key and port manually. The receiver binds only to the selected local Tailscale IPv4 address and accepts only its saved peer. Literal `100.64.0.0/10` addresses are supported; DNS/MagicDNS, LAN addresses, and IPv6 are deliberately not accepted. No SSH credentials, login password, router port forwarding, or public listener are needed.

## Set up voice on each sending Mac

In Superwhisper:

- Select your local Mac or Bluetooth headset microphone. Wait for the waveform before speaking.
- Turn **Paste result text** and **Realtime** off.
- Set **Clipboard content → Replace with dictation**.
- Choose a downloaded local voice model if audio must stay on this Mac. Cloud models send audio to Superwhisper’s configured provider; T&S does not control that choice or Superwhisper’s retention.

In **T&S → Settings → Send**, select Superwhisper’s active folder (containing `recordings`, `modes`, and `settings`) and confirm the setup checklist. The folder is selected explicitly with a read-only bookmark; T&S does not repeatedly prompt to read Documents. Existing installations keep their chosen voice shortcut and recording gesture. New installations default to Option–Space and press-to-start/stop.

## Permissions and remote-desktop use

- **Accessibility on both Macs:** enables the local switch shortcut in either mode, local voice/screenshot shortcut interception in TX, and optional automatic paste in RX. T&S only handles its configured shortcuts; it does not record other typing.
- **Screen Recording on sending Macs:** required only for screenshots. The app captures the region you explicitly select; it does not continuously watch the screen or clipboard.
- **Superwhisper:** manages its own microphone permission and recording device.

If another app uses Option–Space, T&S captures that chord while in TX with its early keyboard listener active. In RX, T&S passes voice and screenshot shortcuts through and captures only its switch shortcut. Secure Keyboard Entry can temporarily prevent capture. Check **Keyboard listener** and **Last shortcut received** in Settings. The mode shortcut is ignored while T&S is busy; no switch is queued. Switching affects the local Mac only, including while Jump has focus.

For automatic paste, enable **Automatically paste on the receiving Mac** in Send and **Allow automatic paste from the paired Mac** in Receive. Save on each Mac. Keep the remote window and text field selected while waiting. Permission, protected input, focus, clipboard contents/revision, cancellation, and held modifiers are checked before a fixed Command–V is sent. Unsupported text fields or changed focus leave the text ready for manual paste. “Paste shortcut sent” confirms event submission, not insertion by every possible target app.

If Jump Desktop’s clipboard sharing overwrites T&S’s clipboard, disable **Sync Clipboards** in the connection’s Sharing settings. The receiving account must be logged in with T&S running; this is not a pre-login service.

## Screenshots

Enable **Copy screenshots** in Send. With TX active, Command–Shift–3 opens a local marquee, replacing its usual whole-screen action while enabled. Drag over the local display or the remote desktop as displayed locally. Escape cancels. Wait for confirmation, then paste on the receiving Mac. Screenshots are always pasted manually, even when voice auto-paste is enabled.

Only T&S-initiated captures are transferred. Other clipboard images/files are not monitored. Failed transfers offer **Retry clipboard copy**, **Copy locally**, and **Discard**. Retrying never repeats automatic paste. A lost receipt can mean the remote clipboard was already updated.

## Privacy and security

The transport uses Tailscale plus authenticated AES-256-GCM messages, a random shared key stored in the local Keychain, fresh connection challenges, request identifiers, bounded payloads, and digest-bound receipts. Success is shown only after clipboard write/readback confirmation. T&S has no analytics, transcript history, shell execution, remote arbitrary commands, or automatic-update service.

Read [SECURITY.md](SECURITY.md) for trust boundaries, limits, and private reporting guidance. T&S has not undergone an independent security audit. Legacy app, Keychain, and protocol identifiers are retained for upgrade compatibility; they contain no machine address, credential, or user account information.

## Development

```sh
swift test --disable-sandbox
```

Some tests use macOS desktop services and require a logged-in desktop. Explicit opt-in is required for keyboard and paste integration fixtures. See [CONTRIBUTING.md](CONTRIBUTING.md), [validation](docs/VALIDATION.md), and [release instructions](docs/RELEASING.md). The project uses Apple frameworks only, with no third-party Swift packages.

- [0.4.1 upgrade guide](docs/UPDATE-0.4.1.md)
- [Changelog](CHANGELOG.md)
- [MIT licence](LICENSE)
