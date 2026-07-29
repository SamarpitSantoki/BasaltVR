# Third-party notices

BasaltVR is MIT-licensed. It builds on or interoperates with the projects below, which retain
their own licenses and trademarks.

| Project | Use | License | Distributed in the developer-preview app |
|---|---|---|---|
| Khronos OpenXR SDK | Headers, loader, and test applications | Apache-2.0 and accompanying Khronos terms | Selected compiled runtime/test components |
| DXMT v0.80 | D3D11-to-Metal base for the Basalt IOSurface patches | MIT | Basalt-patched runtime components when available |
| DirectXMath | Optional `hello_xr` test build | MIT | No |
| Wine | Windows compatibility runtime | LGPL-2.1-or-later and component-specific licenses | No |
| ALVR | Headset client and transport protocol | MIT | No |
| OpenComposite | OpenVR-to-OpenXR translation | GPL-3.0 | No; users supply it separately |
| BlackHole | Optional macOS audio loopback device | GPL-3.0 | No |

The release packager deliberately does not bundle Wine, ALVR, OpenComposite, BlackHole, games, or
store credentials. Follow each upstream project's distribution terms when obtaining those
components.

Copies of licenses for compiled components included by the release packager are stored in
[`LICENSES`](LICENSES).
