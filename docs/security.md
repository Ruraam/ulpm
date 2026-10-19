# Security model

ULPM applies defense in depth: signed packages, pinned publishers, verified repository metadata, atomic state changes and a Bubblewrap sandbox.

## Threat model

ULPM is designed to reduce the impact of:

- A tampered package or repository index
- A compromised package host or mirror
- An untrusted publisher key
- A malicious upgrade replacing a trusted application
- An interrupted or failed installation corrupting state
- An application accessing files or devices it did not declare

It is **not** a virtual machine, a kernel isolation boundary, or a defense against a compromised kernel, `bubblewrap`, or the host user account. Applications still run as your user; a kernel or sandbox escape can reach your data.

## Package signatures

### Trailer format

Every signed LPK ends with a 104-byte trailer:

```text
"ULPM_SIG"            8 bytes
Ed25519 public key   32 bytes
Ed25519 signature    64 bytes
```

The signature covers the SHA-256 digest of the entire package payload (everything before the trailer). The public key is embedded so packages are self-describing.

The legacy `LPK_SIG\0` trailer is still recognized for compatibility.

### Verification outcomes

| Result | Meaning | Default behavior |
| :--- | :--- | :--- |
| Valid + trusted | Signature verifies and key is in `trusted_keys/` | Accepted |
| Valid + untrusted | Signature verifies but key is not trusted | Rejected |
| Unsigned | No trailer | Rejected |
| Invalid | Corrupted or tampered | Rejected |

Strict mode is enabled by default (`ULPM_STRICT_SIGNATURES=1`). Only a deliberate combination of:

```bash
export ULPM_STRICT_SIGNATURES=0
export ULPM_ALLOW_UNSIGNED=1
```

allows unsigned packages. This is intended for local development, never for distribution.

Trust a publisher key explicitly:

```bash
ulpm trust release_key.pub
```

The trust store is:

```text
~/.config/ulpm/trusted_keys/
```

### Publisher pinning

The first successful installation records the package signer's fingerprint in `installed.db`:

```text
id|name|version|timestamp|origin|fingerprint
```

On upgrade and rollback, the new package's signer must match the pinned fingerprint. A mismatch aborts the operation with a supply-chain warning.

To accept an intentional key rotation:

```bash
ULPM_ALLOW_KEY_ROTATION=1 ulpm install new-version.lpk
```

Use this only after independently verifying the new key. It bypasses an important protection.

## Repository security

- `repo add` pins the Ed25519 public key by SHA-256 fingerprint.
- Every `repo update` verifies:
  - The pinned key file bytes and fingerprint
  - The detached signature over `index.json`
  - The index schema and package metadata
- Downloads are checked against the SHA-256 in the index.
- The downloaded manifest's ID and version must match the index entry.
- The package signature is verified before commit.
- HTTPS is recommended; HTTP and local paths are supported but reduce transport guarantees.
- A failed update keeps the previous verified cached index.

## Installation pipeline

`ulpm install` and transactions perform, in order:

1. Resolve the target and download/copy it to a private staging file.
2. Verify the package signature and trust.
3. Extract and validate the JSON manifest.
4. Validate app ID, name, version, executable path and architecture.
5. Check declared dependencies.
6. Check the publisher fingerprint pin.
7. Refuse symlinked app directories, package files, icons and launchers.
8. Stage the package, update the database through an atomic rename, then move the old package to history.
9. Sync data and release the lock.

Failures restore the previous package and database entry. Multi-package transactions use a durable WAL and snapshot rollback.

## Sandbox

Application and rootfs execution use Bubblewrap. When Bubblewrap is unavailable or user namespaces are disabled, ULPM refuses to run rather than silently degrading.

```bash
ULPM_UNSAFE_NO_SANDBOX=1 ulpm run app
```

This override prints a warning and runs without isolation. Use it only for debugging.

### Default isolation (app mode)

| Resource | Default |
| :--- | :--- |
| User, PID, UTS, cgroup namespaces | New |
| Capabilities | All dropped |
| `/usr`, `/lib`, `/bin`, `/sbin` | Read-only host bind (or shared runtime) |
| `/sys` | Read-only |
| `/proc`, `/dev` | Fresh instances |
| `/tmp`, `/run`, `/var/tmp` | Private tmpfs |
| Application payload | Read-only at `/app` |
| Home | `~/.var/app/<app_id>/home` mapped to `$HOME` |
| `~/.config`, `~/.local/share`, `~/.cache` | Per-app directories |
| Network | Shared only if `permissions.network` is true |
| GPU/audio/input | Per permissions |
| Session D-Bus | Filtered by `xdg-dbus-proxy` when available |
| Seccomp | Applied with `--strict` when a filter is present |
| Environment | Whitelist only |

### Rootfs mode

Rootfs packages mount their image as `/` inside the sandbox, bind the app data home, a private `/tmp`, and selected host sockets/devices. The host filesystem is not visible except for explicit binds (downloads, media mounts, input, GPU, audio).

### Environment whitelist

Only display, locale, theme, audio, GPU and desktop-session variables are forwarded. Arbitrary host environment variables, including secrets and tokens, are not exposed to applications.

### Filesystem permissions

```json
{
  "permissions": {
    "filesystem": {
      "home": "isolated",
      "downloads": "read-write",
      "custom": [
        {"path": "/home/user/Projects", "mode": "read"}
      ]
    }
  }
}
```

- `home`: `isolated` (default), `read`, `read-write`
- `downloads`: `none`, `read`, `read-write`
- `custom[].path`: absolute host path, validated and resolved
- `custom[].mode`: `read` or `read-write`; anything else is rejected

`--bind <host>:<dest>` adds an ad-hoc bind. Destinations are validated and cannot target unsafe paths.

## Network

Network isolation is on when `permissions.network` is false. When enabled, the sandbox shares the host network and binds only resolver and CA files needed for TLS.

Rootfs mode uses the same rule. `--offline`/`--no-net` forces isolation; `--net` re-enables it for the run.

## D-Bus

When `xdg-dbus-proxy` is available:

- A private proxy socket is created per run.
- Only namespaces in `permissions.dbus.session.talk` are allowed to be talked to.
- Names in `permissions.dbus.session.own` may be owned.
- The proxy socket replaces the session bus in the sandbox.

When the proxy is unavailable, ULPM binds the session bus socket directly. This gives the application broad session-bus access. Install `xdg-dbus-proxy` for meaningful filtering.

The system bus socket is bind-mounted when present. System services still enforce their own PolicyKit and D-Bus policies; the sandbox does not grant additional system privileges.

## Graphics, audio and devices

| Permission | Exposes |
| :--- | :--- |
| `gpu` | `/dev/dri`, NVIDIA devices, Vulkan/GLVND data |
| `audio` | `/dev/snd`, PulseAudio/PipeWire sockets |
| `gui` | X11/Wayland sockets and display environment |
| `devices.input` | `/dev/input`, `/dev/uinput`, joysticks |
| `devices.hidraw` | `/dev/hidraw*` |
| `devices.usb` | `/dev/bus/usb` |
| `devices.kvm` | `/dev/kvm` |

X11 does not provide per-window isolation: an application with the X11 socket can observe or inject input into other X11 clients. Prefer Wayland where possible.

Electron/Chromium applications are started with their internal sandbox disabled flags (`--no-sandbox`, `--disable-setuid-sandbox`) because nested sandboxing is unreliable under Bubblewrap. Bubblewrap still provides the outer isolation boundary.

## Seccomp

`--strict` applies an optional precompiled BPF filter:

```text
~/.config/ulpm/seccomp/default.bpf
```

Override with `ULPM_SECCOMP_FILTER`. ULPM does not ship a default filter; without a readable filter, strict mode still disables network/GPU/input and isolates home.

## Secrets

- `ulpm.conf` is mode `0600`.
- `installed.db` and private keys are mode `0600`.
- Key and trust directories are mode `0700`.
- `GITHUB_TOKEN` is read from the environment or `ulpm.conf`.
- Tokens are passed to `curl` through a private config file, not on the command line.
- Application sandboxes do not inherit tokens or arbitrary environment variables.

## Recommendations

1. Keep strict signatures enabled.
2. Distribute publisher keys through a separate trusted channel.
3. Use one release key per publisher and keep it offline.
4. Serve repositories over HTTPS.
5. Install `xdg-dbus-proxy`, `bubblewrap` and a seccomp profile.
6. Prefer Wayland over X11 for graphical applications.
7. Review `ulpm permissions <app>` after installing.
8. Use `--offline` for applications that do not need the network.
9. Do not set `ULPM_UNSAFE_NO_SANDBOX=1` or `ULPM_ALLOW_KEY_ROTATION=1` in your shell profile.
10. Rebuild repository indexes and verify signatures before publishing.

## Reporting vulnerabilities

Do not open a public issue for a security vulnerability. Follow the process in [SECURITY.md](../SECURITY.md).

## Related documents

- [Permissions](permissions.md)
- [LPK format](lpk-format.md)
- [Repositories](repositories.md)
- [Configuration](configuration.md)
