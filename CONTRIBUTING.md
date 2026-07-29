# Contributing to BasaltVR

BasaltVR is an experimental Apple Silicon PCVR stack. Small, testable changes are easiest to
review. Before opening a pull request, explain the user-visible problem, keep unrelated
refactors separate, and add or update tests for behavior changes.

## Before you start

Search existing issues and pull requests first. For a substantial protocol, architecture,
dependency, licensing, or user-workflow change, open a focused issue before investing in an
implementation. Small bug fixes, tests, and documentation corrections can go directly to a pull
request.

Most Swift, documentation, and cross-build work does not require a headset or a game account.
Hardware-only validation must be reported separately from deterministic automated results.

## Development environment

The native components require macOS 14 or newer on Apple Silicon with Xcode command-line tools.

```sh
git clone <your-fork-url>
cd BasaltVR
make doctor
make check
```

`make check` validates scripts and metadata, checks local documentation links and repository
hygiene, runs all Swift tests, and produces an Apple Silicon release build. Use `make help` to see
the supported contributor commands.

The Windows OpenXR runtime additionally requires CMake and MinGW. Confirm that environment before
working in `runtime`:

```sh
brew install cmake mingw-w64
make doctor-runtime
make runtime-build
```

The larger DXMT gate needs Meson, Ninja, Rosetta 2, and the Xcode Metal toolchain:

```sh
brew install cmake mingw-w64 meson ninja
make doctor-dxmt
make dxmt-test
```

The first DXMT fork build can take tens of minutes. Details and safe environment overrides are in
[runtime/README.md](runtime/README.md).

## Choosing the right checks

| Changed area | Required local verification |
|---|---|
| Documentation, templates, scripts | `make check` |
| Swift app, CLI, bottles, or streamer | `make check` |
| OpenXR runtime ABI or loader behavior | `make check && make runtime-test` |
| DXMT patches, textures, fences, or composition | `make check && make dxmt-test` |
| Headset transport or live input/audio | relevant deterministic checks plus a documented physical-hardware run |

If a required gate is unavailable, explain why in the pull request. Do not describe an unrun gate
as passing.

## Design and safety boundaries

- Keep Windows OpenXR ABI code, native macOS composition, and ALVR transport boundaries explicit.
- Preserve local-only networking, bounded buffering, managed-root containment, and explicit audio
  capture unless a reviewed design intentionally changes them.
- External Whisky and CrossOver bottles are read-only until a user explicitly creates an isolated
  Basalt-managed copy.
- Do not add automatic downloads or redistribute third-party binaries without documenting their
  source, checksum, license, update, and rollback behavior.
- Keep public protocols and persisted formats versioned and backward-compatible where practical.
- Never weaken validation merely to make a compatibility test pass.

## Pull requests

- Keep the pull request focused enough to review and revert independently.
- Add a regression test for bug fixes and tests for new behavior.
- Run `make check` and the relevant runtime or DXMT gate.
- Keep generated files, local Wine prefixes, build directories, and release archives out of Git.
- Update the README or focused documentation when setup, flags, or compatibility changes.
- Describe hardware-dependent validation precisely: Mac model, headset, connection type, refresh
  rate, resolution, bitrate, and observed duration.
- Do not include proprietary game files, Meta/Steam credentials, device identifiers, or logs that
  expose personal paths.
- Call out breaking behavior, data migrations, dependency changes, and rollback considerations.

Draft pull requests are welcome for early design feedback. A pull request is ready for review when
its description, tests, documentation, and verification checklist represent the final intended
change.

## Commit and code style

- Follow `.editorconfig`; do not remove meaningful trailing context whitespace from patch files.
- Prefer clear subsystem boundaries and small helpers over unrelated broad refactors.
- Write commit subjects in the imperative mood and explain non-obvious compatibility or safety
  decisions in the body.
- Do not commit generated build products. The ignored `streamer/.build`, `runtime/build*`, `dist`,
  and `release` directories are disposable local state.

By contributing, you agree that your contribution is licensed under this repository's MIT license.
