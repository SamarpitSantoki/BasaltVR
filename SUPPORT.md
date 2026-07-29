# BasaltVR support

BasaltVR is an experimental developer preview with a deliberately narrow compatibility target.
Community support is best-effort; maintainers cannot promise that an arbitrary Windows VR game,
Wine build, headset, or macOS beta will work.

## Where to ask

- Use the **bug report** form for reproducible behavior that appears to be a BasaltVR defect.
- Use the **setup/help** form when the documented setup does not complete and you need help
  identifying the failing prerequisite.
- Use the **compatibility report** form to record a working or failing hardware/software
  combination.
- Use the **feature request** form for a concrete user problem and proposed improvement.
- Follow [SECURITY.md](SECURITY.md) for vulnerabilities. Never disclose a security issue in a
  public issue.

Search existing issues before opening a new one. Keep one problem per issue so fixes and
compatibility conclusions remain traceable.

## Information maintainers need

Include:

- BasaltVR version or commit;
- Mac model and chip, macOS version, headset, ALVR version, and USB or Wi-Fi;
- Wine engine, game, and relevant tool versions;
- exact reproduction steps and whether the problem reproduces after a clean restart;
- the smallest sanitized log excerpt that contains the failure.

Run these commands when applicable:

```sh
make doctor
swift run --package-path streamer basaltctl doctor
```

For runtime build problems, also run `make doctor-runtime`. For DXMT fork problems, run
`make doctor-dxmt`.

## Protect private data

Do not attach Steam or Meta credentials, ADB serial numbers, proprietary game files, full Wine
prefixes, captured screen content, or logs containing home-directory paths. Replace usernames,
device identifiers, access tokens, and account IDs with clear placeholders before posting.

## Scope

The project currently supports Apple Silicon on macOS 14 or newer and targets Beat Saber through
the documented ALVR/Wine/DXMT path. General PCVR compatibility, Intel Macs, microphone backhaul,
and a turnkey notarized installer are not currently supported.
