# Contributing to BasaltVR

BasaltVR is an experimental Apple Silicon PCVR stack. Small, testable changes are easiest to
review. Before opening a pull request, explain the user-visible problem, keep unrelated
refactors separate, and add or update tests for behavior changes.

## Development setup

The native components require macOS 14 or newer on Apple Silicon with Xcode command-line tools.

```sh
swift test --package-path streamer
swift build -c release --package-path streamer
```

The Windows OpenXR runtime additionally requires CMake and MinGW:

```sh
brew install cmake mingw-w64
runtime/scripts/test-wine.zsh
```

The larger DXMT gate is documented in [runtime/README.md](runtime/README.md). Live Quest tests
require physical hardware and should be reported separately from deterministic local tests.

## Pull requests

- Run the Swift test suite and the relevant runtime smoke test.
- Keep generated files, local Wine prefixes, build directories, and release archives out of Git.
- Update the README or focused documentation when setup, flags, or compatibility changes.
- Describe hardware-dependent validation precisely: Mac model, headset, connection type, refresh
  rate, resolution, bitrate, and observed duration.
- Do not include proprietary game files, Meta/Steam credentials, device identifiers, or logs that
  expose personal paths.

By contributing, you agree that your contribution is licensed under this repository's MIT license.
