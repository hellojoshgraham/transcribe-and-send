# Validation

## 0.4.1 — 30 October 2026

- Restored the original menu-bar label/status symbol. A successful keyboard-triggered mode change shows the TX/RX graphic for 500 milliseconds. Repeated successful switches cancel the previous timer and start a new interval; ignored or failed switches do not flash. Menu and Settings mode controls keep their existing appearance.
- The existing full suite passed **90 tests, zero failures, zero skips**, including native shortcut routing and isolated automatic paste. No new tests were added for this presentation-only change. The transient display is driven by the existing successful shortcut path; exact perceived timing on a busy desktop still depends on the macOS UI scheduler.
- Network behavior, pairing, permissions and capture remain unchanged. The public source package is regenerated separately from the development-signed app.

## 0.4.0 — 30 October 2026

Validation is performed against synthetic data, private named pasteboards, and temporary fixtures. No personal pairing keys, transcripts, screenshots, addresses, or computer names belong in this file or the source release.

The final full suite passed **90 tests, zero failures, zero skips** with explicit native integration opt-in. Coverage includes:

- Existing encrypted text/image transport, authentication/replay/deadline handling, strict PNG validation, transcript freshness, folder-access failure handling, and automatic-paste checks.
- Default/custom mode shortcuts, reserved chord conflicts, malformed shortcut configuration, and preference round trips.
- A tagged native keyboard test verifying one mode-switch callback in TX and RX, repeat suppression, consumed key-up, and ordinary voice/screenshot pass-through in RX. A sink blocks tagged events from reaching user apps.
- Pairing-code round trips and rejection of invalid, oversized, wrong-version, non-Tailscale, or malformed-key input.
- One-direction preference migration and preservation of explicitly different legacy peers.
- Actual fixed Command–V insertion into an isolated native editor, with no Return and no focus theft by receiver panels.
- Native light/dark UI previews, without loading real preferences, credentials, or network listeners.

A restricted-runner attempt could not access macOS private-pasteboard services. The complete suite ran with permitted desktop service access. An added activity assertion identified redundant idle notifications; notification delivery was narrowed to actual state changes and the suite then passed. Neither test grants nor broad macOS privacy resets were performed.

The sanitized source ZIP was extracted to a fresh temporary directory and built without the working tree’s caches. Its CI subset passed **43 tests, zero failures**. Archive integrity and every source-manifest digest were verified. A separate scan found no development-user names, actual peer addresses, pairing fingerprint, signing-team identifiers or personal paths in the source ZIP. Old build archives, installation backups, logs and Git history are excluded.

A universal arm64/x86_64 development-signed app was built separately from the source ZIP and passed strict signature verification. Absolute debug-map paths were stripped before the final archive was signed; a binary scan confirmed no builder home paths remained. The updated local installation retained its existing designated signing requirement, pairing fingerprint, voice gesture, automatic-paste setting, folder grant and screenshot permission. The native Connection tabs rendered correctly in the installed app. The mode control was exercised TX → RX (listening) → TX, and the saved peer passed an authenticated connection probe afterward. The physical Command–Option–Shift–S shortcut was subsequently user-confirmed to switch TX → RX → TX with Jump Desktop focused. New pair-code exchange and reverse-direction voice on two physical Macs still require the upgrade checklist. No new key or privacy grant was created during this upgrade check.

Native offscreen previews do not render the AppKit tab-control material correctly; the actual installed settings window was inspected to verify the tab labels. The TX/RX template icons were separately rendered and inspected in light and dark appearances. No live desktop image is included in the public source ZIP.

The previous installed version’s voice auto-paste and screenshot workflow were user-confirmed working. That does not establish live acceptance for the new mode shortcut or reverse-direction workflow. The physical two-Mac checks are in [the upgrade guide](UPDATE-0.4.0.md).

## Earlier coverage

0.3.2 passed 84 tests and fixed connection timeouts previously confused with user cancellation. 0.3.0 introduced bounded screenshot transport. 0.2.0 introduced acknowledged optional automatic paste. 0.1.3 moved local shortcut capture ahead of competing session-stage filters. Detailed installation-specific development notes and old binary archives are intentionally excluded from the public source package.
