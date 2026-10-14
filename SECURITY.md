# Security Policy

## Reporting a vulnerability

Please report security issues **privately** through GitHub's
[private vulnerability reporting](https://github.com/Ruraam/ulpm/security/advisories/new)
(Security tab → *Report a vulnerability*). Do not open a public issue for anything that
could be exploited.

Include the ULPM version (`ulpmversion`), your distribution and kernel, the output of
`ulpm doctor`, and the smallest package or command that reproduces the problem.
Reports are handled on a best-effort basis; you will get an acknowledgement and, once a fix
is released, credit in the changelog unless you prefer to stay anonymous.

## Supported versions

| Version | Supported |
|---------|-----------|
| 5.0.x   | Yes       |
| < 5.0   | No        |

Only the latest major/minor release receives security fixes.

## Threat model

ULPM runs applications inside unprivileged Bubblewrap namespaces and verifies streaming
Ed25519 signatures on `.lpk` packages. What that does and does not give you:

###Protects against
- **Arbitrary host filesystem access by default.** Sandboxed apps only see their dedicated state
under`~/.var/app/<id>` and `~/Downloads` (read-write by default), unless explicitly overridden.
- **Process table spying and capability exploits.** Apps run in private PID/UTS namespaces,
capabilities are dropped (`--cap-drop ALL`), and terminal injection is blocked (`--new-session`).
- **Signature & payload tampering.** Modifying anypart of a signed `.lpk` bundle invalidates
the 104-byte cryptographic footer and causes immediate execution refusal.
- **Unrestricted session D-Bus access.** D-Bus calls are mediated by `xdg-dbus-proxy`,
strictly restricted to the app's own namespace and explicit portal interfaces.

### Does not protect against
- **A malicious package signed by a key you trust.** Only add keys to `ulpm trust` from
sourcesyou have independently verified.
- **Unsigned packages when `ULPM_STRICT_SIGNATURES` is not`1`.** By default, unsigned
packages trigger a runtime warning but are permitted to run in isolation.
- **X11 eavesdropping.** When X11 is forwarded, any client can observe keystrokes and capture
windows of other X11 applications. Run under native Wayland, pass `--no-gui`, or use `--strict`.
- **Extended gaming hardware passthrough.** Using the `--gaming` profile or manifests declaring
`devices.hidraw`, `devices.usb`, or `devices.input` exposes physical raw device nodes
(`/dev/hidraw*`, `/dev/bus/usb`, `/dev/input/*`).
- **Permissive filesystem overrides.** If a package or an override sets
`permissions.filesystem.home: "read-write"` (e.g. via `ulpm override <app> --share-home`),
host `$HOME` confidentiality is completely surrendered to the application.
- **Shared memory.** `/dev/shm` is mounted from the host (required for IPC and X11 MIT-SHM).
- **Kernel vulnerabilities.** User namespaces and cgroups mitigate attacks; they do not replace
a hardware hypervisor (VM). No seccompsystem-call filter is currently enforced.
- **Supply-chain attacks on upstream releases.** `deb-pack`,`search`, and `upgrade` re-pack
and sign binaries with *your* local developer key. This validates local authenticity, not
that the upstream binary provider is benevolent.

## Hardening & Audit tips
- **Enforce strict signature policy:**
```bash
export ULPM_STRICT_SIGNATURES=1
```
Refuses any package without a valid signature from a trusted key in `~/.config/ulpm/trusted_keys/`.

- **Audit effective permissions before launching:**
```bash
ulpm permissions <app_name>
```
Inspects the combined permissions (Manifest v5 + local user overrides) to verify network,
hardware device, and filesystem boundaries.

- **Lock down untrusted software using the strict profile:**
```bash
ulpm run --strict <package.lpk>
```
Completely severs network access, removes direct DRI/GPU access, isolates `$HOME`, unbinds
downloads, and constrains D-Bus communications.

- **Inspect and reset local permission overrides:**
User overrides are stored declaratively at `~/.config/ulpm/overrides/<app_id>.json`. You can
reset them anytime:
```bash
ulpm permissions reset <app_name>
```



