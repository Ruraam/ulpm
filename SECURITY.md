# Security Policy

## Reporting a vulnerability

Please report security issues **privately** through GitHub's
[private vulnerability reporting](https://github.com/Ruraam/ulpm/security/advisories/new)
(Security tab → *Report a vulnerability*). Do not open a public issue for anything that
could be exploited.

Include the ULPM version (`ulpm version`), your distribution and kernel, the output of
`ulpm doctor`, and the smallest package or command that reproduces the problem.
Reports are handled on a best-effort basis; you will get an acknowledgement and, once a fix
is released, credit in the changelog unless you prefer to stay anonymous.

## Supported versions

Only the latest release receives security fixes.

## Threat model

ULPM runs applications in unprivileged Bubblewrap namespaces and verifies Ed25519
signatures on `.lpk` files. What that does and does not give you:

**Protects against**
- A package reading or writing your home directory (only `~/.var/app/<id>` and
  `~/Downloads` are exposed).
- A package seeing host processes and killing them (own PID namespace), gaining
  capabilities (`--cap-drop ALL`) or injecting into your terminal (`--new-session`).
- Tampering with a signed package after it was built (forged or corrupted packages are refused).
- Filtered session D-Bus access through `xdg-dbus-proxy`.

**Does not protect against**
- **A malicious package signed by a key you trust.** Only `ulpm trust` keys you have verified.
- **Unsigned packages when `ULPM_STRICT_SIGNATURES` is not `1`.** They run sandboxed, with a warning.
- **X11.** The X11 socket is shared with the host: any X11 client can observe keystrokes and
  windows of other clients. Use Wayland or `--no-gui` for untrusted software.
- **Input devices.** `/dev/input` and `/dev/uinput` are exposed for gamepads. Pass
  `--no-input` for software that does not need them.
- **Shared memory.** `/dev/shm` is shared with the host (required for X11 MIT-SHM).
- **Kernel vulnerabilities.** Namespaces reduce attack surface; they do not replace a VM.
  No custom seccomp filter is applied.
- **Supply-chain attacks on upstream releases.** `deb-pack` and `upgrade` re-sign what they
  build with *your* local key, which proves who built the package, not that upstream is honest.

## Hardening tips
- `export ULPM_STRICT_SIGNATURES=1` to refuse unsigned or unknown-key packages.
- Run untrusted bundles with `--offline --no-input`, plus `--no-gui` when they do not need a display.
