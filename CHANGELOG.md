# Changelog

All notable changes to BasaltVR are documented here.

## Unreleased

### Fixed

- Bundled `basaltctl` now locates the app's packaged support files when invoked outside the source
  checkout.

### Project maintenance

- Added one-command environment, test, build, documentation-link, and repository-hygiene checks.
- Added maintainer, support, triage, compatibility-report, and contributor workflows.
- Hardened GitHub Actions configuration and release preflight validation.

## 0.1.0 - 2026-07-28

Initial public developer preview.

- Native SwiftUI manager, streamer, and bottle/profile CLI.
- ALVR v20 wired and wireless video transport with optional BlackHole audio.
- Experimental Windows OpenXR runtime with D3D11/DXMT/IOSurface handoff.
- HMD and Touch tracking, OpenXR actions, controller presence, velocity, and haptics.
- Managed Wine bottle isolation, OpenXR registration, Steam launch profiles, and OpenComposite
  installation from a user-supplied artifact.
- Automated Swift, Wine loader, and DXMT acceptance coverage.

This is not a conformant OpenXR runtime or a general PCVR compatibility release.
