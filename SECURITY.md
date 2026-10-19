# Security Policy

ULPM handles package signing, trust decisions and application sandboxing. Security reports are taken seriously.

## Supported versions

| Version | Supported |
| :--- | :---: |
| 6.x | Yes |
| 5.x and older | No |

Fixes are provided for the latest release on the main branch.

## Reporting a vulnerability

Do **not** open a public issue, discussion, or pull request for a security vulnerability.

Preferred channel: GitHub private vulnerability reporting through the repository **Security** tab ("Report a vulnerability").

If private reporting is unavailable, open a minimal public issue without technical details and ask a maintainer for a private contact channel.

Include, when possible:

- ULPM version (`ulpm --version`) and commit
- Distribution, kernel and architecture
- A description of the impact
- Reproduction steps or a proof of concept
- Whether the issue is already public
- Any suggested fix or mitigation

Never send private keys, access tokens, or third-party personal data.

## Scope

In scope:

- Signature verification bypass or forgery
- Trust-store, repository pin or publisher pin bypass
- Repository index signature or fingerprint bypass
- Path traversal, symlink escape, or arbitrary file write/delete during pack, install, upgrade, rollback or cleanup
- Sandbox escape through ULPM-generated Bubblewrap arguments
- Command injection through manifests, repository metadata, archive contents, filenames, URLs or environment variables
- Privilege escalation or state corruption through the transaction/WAL engine
- Token or key disclosure, including via command lines, world-readable files or logs
- Dependency confusion through index or manifest handling

Out of scope:

- Vulnerabilities in the Linux kernel, `bubblewrap`, `squashfuse`, `openssl`, `jq` or other host tools (report them upstream)
- Behavior the user explicitly enabled with `ULPM_UNSAFE_NO_SANDBOX=1`, `ULPM_ALLOW_KEY_ROTATION=1`, `ULPM_STRICT_SIGNATURES=0` or `ULPM_ALLOW_UNSIGNED=1`
- Applications accessing resources the user granted through manifest permissions or `ulpm override`
- Limitations inherent to X11 (no per-client isolation) or to the system D-Bus socket
- Denial of service requiring control of the user's own session or files
- Issues caused by running ULPM as root in unsupported configurations

## Handling process

- We aim to acknowledge reports within a few days.
- We will reproduce, assess severity and work on a fix.
- We coordinate disclosure timing with the reporter and credit reporters who wish to be named.
- Fixes are released and documented with mitigation guidance when applicable.

Timelines are best-effort; this is a community project.

## Hardening guidance

The defaults are secure: strict signature verification, publisher pinning, repository key pinning and fail-closed sandboxing. Keep them enabled.

Additional recommendations:

1. Verify publisher keys through a separate trusted channel before `ulpm trust`.
2. Keep release keys offline and separate from build machines.
3. Serve repositories over HTTPS.
4. Install `xdg-dbus-proxy` and use `--strict` with a seccomp profile for untrusted packages.
5. Prefer Wayland over X11.
6. Audit permissions with `ulpm permissions <app>` and `ulpm inspect <package.lpk>`.
7. Do not export the unsafe override variables in shell profiles.

See [docs/security.md](docs/security.md) for the full threat model.
