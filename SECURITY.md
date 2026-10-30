# Security policy

## Report privately

For an exploitable issue, use the repository’s **Security → Report a vulnerability** feature. If the repository has not enabled private reporting, open a minimal issue asking for a private contact without technical exploit details, credentials, pairing codes, screenshots, or transcripts. Maintainers must enable private reporting before advertising a public binary release. No response-time guarantee is currently offered.

## Trust boundaries

T&S trusts the logged-in user, macOS, the local Superwhisper installation, and the paired Mac. The shared 256-bit key grants that peer the ability to write the receiving clipboard and, only with local consent and checks, request fixed Command–V. A compromised paired Mac is inside this trust boundary. Use a tailnet you control and restrict membership/access policies appropriately.

- The receiver binds to one active Tailscale-range IPv4 address and allowlists one peer address. No public/LAN/DNS fallback exists. Interface detection checks the address range; it does not cryptographically verify which process owns the interface. Tailscale configuration and tailnet access policies remain the operator’s responsibility.
- Payloads are AES-256-GCM authenticated with fresh nonces, challenge/request binding and bounded lifetime. Receipts bind to the content digest and follow clipboard readback. Encryption context and app/Keychain identifiers retain legacy namespaces for compatibility; these are public identifiers, not secrets.
- Pairing codes contain a long-lived secret, address and port. They are not encrypted, expiring invitations, passwords, or public keys. Share them through a private trusted path. Import requires explicit review and confirmation. Key replacement stops receiving; re-pair both Macs afterward. Clipboard transient/concealed markers are advisory to other apps.
- The Keychain item uses `WhenUnlockedThisDeviceOnly`, with no iCloud synchronization. T&S does not bundle a key, account password, certificate, provisioning profile, or SSH credential.
- Text is limited to 256 KiB; ordinary frames to 2 MiB. Authenticated image preparation permits up to a 24 MiB frame containing at most a 16 MiB PNG. PNGs are checked before decoding: bounded chunks/CRCs, dimensions, complete end marker, no trailing/animated data, at most 32 megapixels and 16,384 pixels per side. The sender strips source metadata.
- Automatic paste requires opt-in on both sides, effective OS permission, no protected input, the same focused app/window/text field, matching clipboard contents/revision, released modifiers, and a still-active request. It sends only Command–V, never Return. It does not expose arbitrary key events, activation, shell, file paths or commands to peers. Retries copy only.
- The local HID listener handles only configured shortcuts. RX captures only the mode switch. Other typing passes through, and typed characters are never stored. Secure Keyboard Entry is respected. Modifier transitions pass through to keep remote clients’ state balanced.
- Superwhisper output must be a single new, completed, non-realtime recording with stable metadata and matching changed clipboard text. Concurrent or ambiguous output fails closed. Folder read failures stop polling rather than causing repeated prompts.

## Data handling and limitations

T&S has no transcript archive or analytics. Clipboard contents, Superwhisper history, other clipboard managers, cloud transcription providers, and remote-desktop recording are outside its retention control. Failed transfers remain in app memory for explicit retry/copy/discard until replaced or quit. Screenshot temporary files are removed on completion/cancellation/error. A lost receipt may mean the target already received the data; T&S never retries paste automatically.

The app is not sandboxed because it needs global shortcut interception, cross-app paste and user-selected capture. Accessibility and Screen Recording are powerful OS permissions. Source is reviewable, but the project has not received an independent security audit. Only the latest release is maintained; no historical support window is promised.
