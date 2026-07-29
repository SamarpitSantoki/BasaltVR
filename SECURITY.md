# Security policy

BasaltVR captures screen or game content, launches Windows processes, and can communicate with a
headset over USB or the local network. Treat unexpected network exposure, path escapes, unsafe
process execution, and capture without clear user intent as security issues.

## Supported versions

Security fixes are made on the default branch and included in the next developer-preview release.
Older preview archives are not maintained.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting or security-advisory feature for this repository.
Do not open a public issue containing an exploit, credentials, device identifiers, private logs,
or captured screen content.

Include the affected revision, macOS and headset versions, reproduction steps, expected impact,
and whether the issue requires USB, LAN access, or a malicious local file. You should receive an
initial response within seven days after a private report is available to the maintainers.

## Operational safety

- The desktop preview binds to localhost unless the user explicitly selects a LAN address.
- Wired streaming uses ADB forwards to one authorized physical device.
- Game audio capture is opt-in and requires an explicitly selected loopback device.
- Basalt-managed bottles must remain inside the configured data root.

These are intended safety boundaries, not a claim that experimental releases are security audited.
