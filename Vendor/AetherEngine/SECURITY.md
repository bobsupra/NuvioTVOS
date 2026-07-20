# Security Policy

## Supported versions

AetherEngine ships fixes on the latest released minor line. Security fixes land there first; older lines are not back-patched. Host apps pin the engine by commit SHA, so picking up a fix means bumping the pin to the patched release.

| Version | Supported          |
| ------- | ------------------ |
| 2.1.x   | :white_check_mark: |
| < 2.1   | :x:                |

## Reporting a vulnerability

Please report security issues **privately**, not as a public issue or pull request.

Use GitHub's private reporting: [Security → Report a vulnerability](https://github.com/superuser404notfound/AetherEngine/security/advisories/new). That opens a private advisory visible only to you and the maintainers.

Helpful things to include:

- The affected version or commit SHA, and the platform (tvOS / iOS / macOS).
- A description of the issue and its impact.
- Steps or a proof of concept that reproduce it. For a malformed-media issue, a sample file or `ffprobe` output is ideal.

You can expect an initial acknowledgement within a few days. Once a fix is ready it ships in a new release and the advisory is published with credit, unless you prefer to remain anonymous.

## Scope

AetherEngine plays media from servers and local sources and parses untrusted container and codec data. Areas most relevant to security:

- **Media parsing.** Demuxing and decoding of untrusted containers and bitstreams (the FFmpeg / dav1d surface).
- **Network handling.** The engine's HTTP range reading and its on-device loopback server used to bridge sources into AVPlayer. Nothing is exposed off the device, and there is no external analytics or session reporting.
- **Memory safety.** Crashes or out-of-bounds behavior triggered by crafted input.

Out of scope: vulnerabilities in a host app's own UI or networking (report those on the host app's tracker), and issues in upstream FFmpeg / dav1d themselves (report those upstream, though we are glad to know if a bundled build is affected).
