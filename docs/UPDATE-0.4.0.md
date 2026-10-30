# T&S 0.4.0

Quit T&S before replacing the installed app. Use one installed copy in Applications on each Mac. Preserve the same signing identity across updates where possible; signing identity changes can require macOS privacy grants to be renewed. Existing pairing keys, folder grants, voice shortcuts, gesture choices, and screenshot options are preserved.

## What changes

- Command–Option–Shift–S switches the local Mac between TX and RX. Customize modifiers/key under **Shortcuts & app** and save. Voice and screenshot shortcut conflicts are rejected. Both roles now use Accessibility for this local switch listener.
- The menu-bar icon becomes a small TX/RX switch with the current mode highlighted. Delivery checkmarks and error indicators remain.
- **Connection** holds one peer address and shared key for both directions. New users exchange pairing codes in both directions. Existing paired users do not need a new key.
- A previous send-only or receive-only peer address fills the opposite direction. If older settings contain two different peers, both are preserved and shown; choose a single paired Mac explicitly before saving the new setup.
- Sending, receiving, and app controls have their own tabs. Changing mode never saves an unfinished settings draft. Active recording/transfer prevents mode switching.

## Check after updating

1. Confirm the correct peer and this Mac’s active Tailscale address in Connection. Save if you detect an address. Do not replace the key for an already-paired setup.
2. Press the switch shortcut with a remote desktop focused. Verify the local menu-bar highlight changes once. In RX, voice and screenshot shortcuts should pass through. Put the other Mac into the opposite mode separately.
3. Use Test saved connection from TX, then dictate into a disposable remote editor. Confirm the selected recording gesture and optional automatic paste.
4. Test a harmless screenshot region, Escape, and a switch attempt while a transfer is active. Verify no operation is interrupted by the switch.
5. Quit/reopen and check that settings and the selected mode persist. Test the reverse direction with Superwhisper configured on that sender.

The encrypted clipboard protocol remains compatible with 0.3.x. Pairing-code import and the configurable switch UI require 0.4.0. Source code is MIT licensed; a locally signed development build is not an Apple-notarized public release.
