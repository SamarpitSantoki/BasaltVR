# Managed bottles and launch profiles

Milestone 5 is implemented by the `basaltctl` executable in the streamer's Swift package. Its
default data root is `~/Library/Application Support/BasaltVR`; set `BASALT_DATA_DIR` or pass
`--root PATH` to use a different root. Every writable bottle prefix, private engine, metadata
file, and launch profile stays below that root.

> [!IMPORTANT]
> The downloadable developer-preview app includes Basalt's compiled runtime and DXMT handoff
> artifacts, but it does not redistribute the pinned Wine engine. Creating the supported VR bottle
> currently requires a prepared source checkout and the build steps below. The packaged manager is
> not yet a turnkey installer.

## Engines and safety

Run the prerequisite check from the repository root:

```sh
swift run --package-path streamer basaltctl doctor
swift run --package-path streamer basaltctl engines
```

The supported VR provider is `pinned-wine-11.10-dxmt-0.80`. Creating one of these bottles uses
an APFS copy-on-write clone of the verified Wine toolchain, so installing the Basalt DXMT fork
cannot affect another bottle. Installed WhiskyWine and GPTK providers are also discoverable for
managed prefixes, but `bottle prepare` deliberately refuses to overlay DXMT into those shared
engines. CrossOver bottles and applications are never modified.

Bottle and profile names accept only 1–64 ASCII letters, digits, dots, underscores, and hyphens;
the first character must be alphanumeric. Loaded metadata is checked against its managed
directory. A pinned engine must remain inside its own bottle, while a shared provider must still
exactly match a currently discovered engine.

## Bottle commands

```sh
swift run --package-path streamer basaltctl bottle list
swift run --package-path streamer basaltctl bottle create beat-saber \
  --engine pinned-wine-11.10-dxmt-0.80
swift run --package-path streamer basaltctl bottle prepare beat-saber
swift run --package-path streamer basaltctl bottle verify beat-saber
```

`create` initializes a win64 prefix. `prepare` installs the built Basalt DXMT Windows and Unix
components into the bottle's private engine, copies the runtime DLL and JSON manifest to
`C:\basalt\runtime`, and writes the Khronos `ActiveRuntime` HKLM value. It then queries that value
and runs `loader_smoke.exe` through the bottle's Wine executable, requiring the managed DXMT
environment to advertise `XR_KHR_D3D11_enable`.

The individual `bottle install-dxmt` and `bottle install-runtime` commands are available for
diagnosis, but `prepare` is the normal idempotent path.

## Profiles

Profiles support `direct`, `steam`, `bsmanager`, and `itch` sources. The source records launcher
intent; the executable and arguments remain explicit so the CLI does not guess per-user install
locations.

```sh
swift run --package-path streamer basaltctl profile add beat-saber-steam \
  --bottle beat-saber --source steam \
  --exe 'C:\Program Files (x86)\Steam\steam.exe' \
  --arg -applaunch --arg 620980 \
  --env STEAM_COMPAT_CONFIG=basalt

swift run --package-path streamer basaltctl profile list
swift run --package-path streamer basaltctl profile show beat-saber-steam
```

Repeat `--arg VALUE` and `--env KEY=VALUE` as needed. `--cwd HOST_PATH` optionally selects the
Wine process's host working directory.

## OpenComposite

Basalt does not download, link, or redistribute OpenComposite. Supply the matching-bitness
`openvr_api.dll` from the [official OpenComposite project](https://gitlab.com/znixian/OpenOVR/-/tree/openxr),
then name the exact game DLL target inside the managed prefix:

```sh
swift run --package-path streamer basaltctl opencomposite install beat-saber-steam \
  --artifact /path/to/openvr_api.dll \
  --target "$HOME/Library/Application Support/BasaltVR/Bottles/beat-saber/prefix/drive_c/Program Files (x86)/Steam/steamapps/common/Beat Saber/Beat Saber_Data/Plugins/x86_64/openvr_api.dll"
```

The installer requires an `MZ` PE artifact and an `openvr_api.dll` destination below that
bottle's prefix. If the game DLL exists, its first version is retained as
`openvr_api.dll.basalt-original`. The generated `opencomposite.ini` uses the D3D11 path
(`initUsingVulkan=false`).

## Launch

Start the native streamer first; it creates the authenticated loopback control file. Pass the
BlackHole input explicitly when game audio is wanted:

```sh
swift run -c release --package-path streamer basalt-streamer \
  --wired --runtime /tmp/basalt-control \
  --audio-device 'BlackHole 2ch' --route-audio
```

In another terminal:

```sh
swift run -c release --package-path streamer basaltctl run beat-saber-steam \
  --control-file /tmp/basalt-control -- --optional-game-argument
```

The run command refuses incomplete bottles or a missing control file. It maps that file into the
Wine `Z:` drive, enables the private DXMT IOSurface gate, applies the profile environment, and
starts the explicit executable. Extra arguments after `--` are appended for that invocation only.

The generated OpenComposite configuration keeps `enableAudio=false`: OpenComposite's audio option
tries to redirect games to an Oculus/Rift output that does not exist in this Wine setup. Instead,
set BlackHole to 48 kHz in Audio MIDI Setup and let `--route-audio` temporarily direct application
output into the loopback; the streamer restores the prior Mac output on shutdown. The management
app adds this flag automatically. Direct CLI users with an existing Multi-Output route can omit
it. Validate the host side with `basalt-streamer --list-audio-devices` and
`basalt-streamer audio-loopback-selftest --device 'BlackHole 2ch'`.
