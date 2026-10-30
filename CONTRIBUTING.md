# Contributing

Use macOS 14+, Swift 5.10+, and Xcode Command Line Tools. There are no external Swift package dependencies. Keep changes small and include tests for protocol, permission, cancellation, migration, and shortcut-routing behavior when affected.

## Build and test

```sh
swift build --disable-sandbox
swift test --disable-sandbox
```

The ordinary suite uses synthetic data and private named pasteboards. Some cases need a logged-in macOS desktop; a restricted runner without pasteboard/bookmark services may fail. Native event/paste tests opt out unless explicitly enabled. The CI job runs the portable subset and builds the app; it does not claim live remote-desktop verification.

On your own development Mac, with existing Accessibility/event-posting permission, opt into native fixtures:

```sh
mkdir -p .build
swiftc scripts/PasteTestTarget.swift -o .build/PasteTestTarget
TS_TEST_EVENT_TAPS=1 \
TS_TEST_PASTE_TARGET="$PWD/.build/PasteTestTarget" \
TS_TEST_PREVIEW_DIR="$PWD/.build/previews" \
swift test --disable-sandbox
```

Keyboard tests tag events and consume them in a downstream sink so they do not reach user apps. The paste fixture briefly focuses a temporary editor, reads a private clipboard, then closes and restores the previous app. Tests must never reset permissions, inspect personal transcripts, capture the user's desktop, rotate real keys or use production pairings.

`--disable-sandbox` controls SwiftPM’s build sandbox; it does not disable macOS security protections.

## Source packages

```sh
python3 scripts/package-source.py
```

This creates a source-only ZIP using an allowlist, rejects local credentials/artifacts and common private-data patterns, and includes a SHA-256 manifest. Review the manifest and the extracted contents before publishing. The scanner is a guardrail, not proof that every possible secret pattern has been identified.

Do not commit `dist/`, `.build/`, `.swiftpm/`, certificates, Keychain exports, pairing codes, real network addresses, desktop captures, or installation-specific notes. Use synthetic fixtures and generic paths in examples. Keep the historical bundle/Keychain/protocol IDs stable unless an explicit migration is designed.

Changes are contributed under the repository’s MIT licence. Be respectful and constructive. See SECURITY.md for private vulnerability reporting; do not post exploitable issues publicly.
