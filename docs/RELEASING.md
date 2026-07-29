# Releasing BasaltVR

BasaltVR releases are explicitly labeled developer previews until the app is Developer ID-signed,
notarized, and accepted from a clean macOS user account with a live headset.

## Before tagging

1. Update `CHANGELOG.md`, `packaging/Info.plist`, and `docs/releases/vX.Y.Z.md`.
2. Run:

   ```sh
   swift test --package-path streamer
   runtime/scripts/test-wine.zsh
   runtime/scripts/test-dxmt.zsh
   packaging/build-release.zsh X.Y.Z
   ```

3. Verify the generated archive:

   ```sh
   cd release
   shasum -a 256 -c BasaltVR-X.Y.Z-macos-arm64.zip.sha256
   unzip -t BasaltVR-X.Y.Z-macos-arm64.zip
   ```

4. Confirm the app and all bundled native executables are arm64, the app's internal signature
   verifies, and the support manifest records `wineIncluded` as `false`.
5. Sanitize release notes and logs. Never publish account names, home-directory paths, ADB serials,
   Steam credentials, game files, or captured content.

## Publishing

Push an annotated `vX.Y.Z` tag. The release workflow rebuilds and verifies the pinned Basalt DXMT
fork, runs Swift tests, creates the archive and checksum, and publishes a GitHub prerelease using
`docs/releases/vX.Y.Z.md`.

The workflow uses the repository-scoped `GITHUB_TOKEN` with only `contents: write`. No Apple
signing credentials are required for the current ad-hoc-signed preview.

## Consumer-release gates

A non-preview release additionally requires:

- an Apple Developer ID Application certificate and hardened-runtime signing;
- notarization and stapling;
- an audited installation/update path for the pinned Wine engine that satisfies all third-party
  redistribution obligations;
- clean-user-account setup and upgrade tests;
- a live managed Beat Saber launch through the GUI;
- rollback and uninstall documentation.
