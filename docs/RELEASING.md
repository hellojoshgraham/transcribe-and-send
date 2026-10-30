# Releasing

## Source release

1. Run the portable CI subset and the permitted native suite. Follow the real two-Mac checklist in UPDATE-0.4.0.md. Document precisely which checks passed.
2. Update the version in Resources/Info.plist and the UI, changelog and upgrade guide.
3. Run `python3 scripts/package-source.py`. Inspect the manifest and extracted source. Only this allowlisted source tree belongs in a new public repository; do not publish the entire local working folder or old archives.
4. Create the GitHub repository with MIT licensing, enable private vulnerability reporting, add the clean source, and configure branch protection/CI. No repository or maintainer account is hard-coded here. Use an appropriate public commit identity if you do not want personal email in Git history.
5. Tag the reviewed source and publish its ZIP/checksum. This project does not publish to GitHub automatically.

## macOS binary release

For a public download, use your own **Developer ID Application** certificate and Apple's notarization service. An Apple Development certificate or ad-hoc signature is not a notarized distribution build. A signing certificate exposes its public signer identity; never distribute the certificate's private key. Decide which public signing identity the project will use before publishing binaries.

```sh
TS_SIGNING_IDENTITY='Developer ID Application: YOUR PUBLIC SIGNER (TEAMID)' bash scripts/build.sh
xcrun notarytool submit dist/0.4.1/TandS-macOS.zip --keychain-profile YOUR_NOTARY_PROFILE --wait
xcrun stapler staple 'dist/0.4.1/T&S.app'
xcrun stapler validate 'dist/0.4.1/T&S.app'
codesign --verify --strict --verbose=2 'dist/0.4.1/T&S.app'
spctl --assess --type execute --verbose=2 'dist/0.4.1/T&S.app'
# Recreate the archive after stapling.
ditto -c -k --sequesterRsrc --keepParent 'dist/0.4.1/T&S.app' dist/0.4.1/TandS-macOS.zip
shasum -a 256 dist/0.4.1/TandS-macOS.zip
```

Use your own Keychain notary profile. Never put Apple credentials, certificates or profiles in the repository. Read Apple's [notarization documentation](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) for current signing requirements. Test on a clean Mac with quarantine intact; do not instruct users to disable Gatekeeper or remove quarantine.

The build script maps source paths out of the executable. Independently inspect the final archive, certificate metadata, embedded resources and binary strings for unintended personal information. Keep one signing identity across releases so macOS can recognize privacy grants. Signing-identity changes need an explicit migration/permission-renewal notice.

A locally built application, an independently audited application, a GitHub source release and an Apple-notarized binary are separate claims. Mark release notes accordingly.
