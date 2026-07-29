# BasaltVR management app

The M7 developer-preview app is a native macOS SwiftUI executable in the existing `streamer` package.
It is intentionally a thin front end over `BasaltBottleKit` and `BasaltCore`: bottles, profiles,
stream settings, and safety validation have one implementation shared with the command-line tools.

## Build and run

From the repository root:

```sh
swift build -c release --package-path streamer
swift run --package-path streamer BasaltVR
```

The release build is important even if the UI itself is run in debug mode. The app launches the
already-built `basalt-streamer` executable directly so it can own its lifecycle and capture its
live output; it does not start a second Swift build while a game session is connecting. Set
`BASALT_REPO_ROOT` if the app is launched with neither the repository nor one of its descendants as
the working directory.

## Current workflow

1. **Setup** checks Apple Silicon and macOS 14, adb, the pinned Wine/DXMT engine, the built OpenXR
   runtime, optional Screen Recording permission, and optional BlackHole audio. The adb and
   BlackHole actions use an existing Homebrew installation. Build-related actions open the M5
   instructions because compiling the pinned runtime is still a developer operation.
2. **Bottles** shows Basalt-managed prefixes alongside installed Whisky and CrossOver bottles.
   External prefixes are read-only. **Copy into Basalt** creates an isolated pinned-engine bottle,
   APFS-clones the existing prefix without changing its source, and runs Wine's prefix update.
   Prepare then installs DXMT and OpenXR and runs the same loader verification as
   `basaltctl bottle prepare`. Managed bottles can launch Steam or a selected Windows installer.
3. **Game Library** parses Steam `libraryfolders.vdf` and installed `appmanifest_*.acf` files in
   every discovered bottle, follows mapped extra Steam-library drives, and uses local Steam artwork
   where available. It also discovers BSManager versions below the default
   `~/BSManager/BSInstances`, the legacy Documents location, BSManager's configured installation
   parent, managed bottles, or a folder selected with **Locate BSManager**. The BSManager launcher
   panel detects its standard Windows installation inside every Basalt bottle, launches it with
   that bottle's Wine environment, and can run an official Windows installer for installation or
   updates. Versions BSManager creates inside a bottle are picked up automatically after it exits.
   Each external instance remains read-only and can become a profile in a selected Basalt bottle
   with the Steam identity and BSIPA `winhttp` override already set. Search, VR-only, and tool
   filters are included. Existing profiles and direct Beat Saber detections appear alongside Steam
   and BSManager games. Steam games in a managed bottle can become `-applaunch APP_ID` profiles
   without re-entering paths.
4. **Profiles** can edit their source, Windows executable, working directory, arguments, and
   environment, or be deleted without removing the game. OpenComposite installation is available
   from the profile editor while keeping the separately supplied DLL inside the managed prefix.
5. **Play** starts wired or Wi-Fi ALVR with the selected FPS, bitrate, resolution, latency preset,
   and optional audio input. When audio is enabled, the streamer temporarily routes default
   application output to that loopback and restores the prior output on shutdown. Once the
   authenticated runtime control file exists, the app asks `BasaltBottleKit` for a fully validated
   Wine launch command and owns that child process too.
6. **Stream** shows the latest Quest FPS, actual wire Mbps, and input-to-display latency, with
   bounded history charts and the raw session log. Stopping the session terminates both children;
   an unexpected streamer exit also terminates the game.
7. **Settings** persists global stream defaults and per-profile overrides, selects audio and
   USB/Wi-Fi transport, and allows the managed Basalt data directory to be changed from the UI.

Generic non-Steam executable scanning outside managed prefixes, online metadata/artwork, a
Developer ID-signed and notarized `.app` bundle, and a clean-user-account/live-Quest acceptance
run remain for later M7 work.
OpenComposite continues to be user-supplied and is never downloaded or redistributed by this app.

The GitHub developer-preview archive contains an ad-hoc-signed app, not a notarized consumer
installer. It does not bundle third-party Wine binaries. Developers can create a local preview
archive with:

```sh
packaging/build-release.zsh 0.1.0
```

The packager includes Basalt runtime and DXMT artifacts when they exist in the ignored build tree,
and records exactly what was included in the archive.

## Tests

```sh
swift test --package-path streamer
```

`BasaltManagerKitTests` covers repository discovery, external-bottle metadata, Steam VDF/manifests,
artwork, BSManager default/configured/explicit-location and managed-bottle launcher/instance
discovery, Windows/host path mapping, Beat Saber scanning and source inference, duplicate
resolution, stream argument generation, and live-stat parsing. `BasaltBottleKitTests` verifies
maintenance and VR launch commands, the BSManager Steam prerequisite, profile deletion, and a real
isolated import whose source remains unchanged.
