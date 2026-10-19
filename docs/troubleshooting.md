# Troubleshooting

Start with the built-in diagnostic:

```bash
ulpm doctor
```

It reports host architecture, Bubblewrap, FUSE, `fuse-overlayfs`, `xdg-dbus-proxy`, portals, GPU devices, core tools, keys and GitHub authentication.

## Installation and PATH

### `ulpm: command not found`

The user install location is not on `PATH`:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

Add it to your shell profile. For a system install, `/usr/local/bin` is normally already on `PATH`.

### `Command 'x' is not available: function 'x' is not defined`

The installation is incomplete or `lib/` was moved. Re-run the installer and verify:

```bash
ls ~/.local/lib/ulpm/
ulpm doctor
```

## Sandbox startup

### `Bubblewrap sandbox unavailable`

ULPM refuses to run without isolation. Install Bubblewrap and enable unprivileged user namespaces:

```bash
sudo apt install bubblewrap
sysctl kernel.unprivileged_userns_clone   # Debian/Ubuntu
```

On distributions that restrict unprivileged namespaces, enable them through the kernel or distribution policy. In containers (Docker, LXC, PRoot), user namespaces are often unavailable.

Last-resort debug override:

```bash
ULPM_UNSAFE_NO_SANDBOX=1 ulpm run app.lpk
```

This is unsafe and not a fix.

### `bwrap: Creating new namespace failed`

The kernel or container blocks user namespaces. Check:

```bash
unshare --user --map-root-user true
```

If that fails, fix host policy or use `ULPM_UNSAFE_NO_SANDBOX=1` only for diagnostics.

### Application starts but has no display

- Verify `DISPLAY` or `WAYLAND_DISPLAY` is set in the parent environment.
- X11: the X socket and `XAUTHORITY` must be accessible.
- Wayland: the compositor socket must exist under `XDG_RUNTIME_DIR`.
- Check `ulpm permissions <app>` for `gui: false`.
- Try `ulpm override <app> gui=true` or `ulpm override <app> --desktop`.

### Application has no network

The default for apps with a `permissions` block is `network: false`:

```bash
ulpm override <app> network=true
ulpm override <app> --net
```

A manifest with a `permissions` block defaults to `network: false`. Legacy manifests without a `permissions` block default to network **enabled**. Inspect the effective value:

```bash
ulpm permissions <app>
```

Proxy environment variables are not forwarded through the sandbox environment whitelist. Applications depending on `HTTP_PROXY`/`HTTPS_PROXY` may need manifest/runtime changes.

### No audio

- Check `permissions.audio`.
- Ensure the PulseAudio or PipeWire socket exists in `XDG_RUNTIME_DIR`.
- Try `ulpm override <app> audio=true`.
- `--no-audio` or `--strict` disables audio.

### GPU/rendering problems

- Check `/dev/dri` exists and is readable.
- Check `permissions.gpu` and `permissions.devices.dri`.
- NVIDIA requires the NVIDIA device nodes and a compatible driver.
- Try without isolation: compare `ulpm run --no-gpu` to confirm an isolation issue.
- Wayland/Electron apps may need `WAYLAND_DISPLAY` and the Ozone hint; ULPM sets `--ozone-platform-hint=auto` when Electron is detected and GUI is enabled.

### Gamepad/input not detected

```bash
ulpm override <app> --gaming
ulpm run <app> --gaming
```

This enables input, hidraw, USB and GPU access. Use `--no-input` to disable.

### D-Bus errors

Install `xdg-dbus-proxy` so session D-Bus access is filtered. Without it, the full session bus is bound and the application still works, but isolation is weaker.

If an application needs a specific service, add it to the manifest:

```json
{
  "permissions": {
    "dbus": {
      "session": {
        "talk": ["org.freedesktop.portal.*", "org.freedesktop.Notifications"],
        "own": ["io.github.myapp"]
      }
    }
  }
}
```

Overrides file:

```text
~/.config/ulpm/overrides/<app_id>.json
```

## Package execution

### `Package architecture 'x' is incompatible with host 'y'`

Install a package built for the host architecture, or rebuild it natively.

### `No executable entrypoint found in package payload`

The manifest `exec` path does not exist or is not executable:

```bash
ulpm inspect app.lpk
```

Fix the manifest `exec` value or the payload layout.

### `Unsafe executable path detected`

`exec` contains `..`, an empty segment or an absolute path. Use a relative path such as `bin/app`.

### `Neither FUSE mounting nor unsquashfs is available`

Install `squashfuse` and `unsquashfs`:

```bash
sudo apt install squashfuse squashfs-tools
```

If `/dev/fuse` is blocked, ULPM unpacks to a temporary directory instead.

### Application exits immediately

Run with the system runner to preserve output:

```bash
ulpm run ./app.lpk
```

If the app needs a shared runtime that is not installed, ULPM warns and falls back to the host base. Install the runtime:

```bash
ulpm runtime install runtime_amd64.lpk
```

## Signatures and trust

### `Package signed by an untrusted key`

```bash
ulpm trust publisher.pub
ulpm inspect package.lpk
```

### `Publisher key mismatch ... possible supply-chain attack`

The new package is signed by a different key than the installed version. Verify the key independently. If the rotation is expected:

```bash
ULPM_ALLOW_KEY_ROTATION=1 ulpm install new.lpk
```

### `Unsigned package rejected`

Obtain a signed package or, only for local development:

```bash
ULPM_STRICT_SIGNATURES=0 ULPM_ALLOW_UNSIGNED=1 ulpm run app.lpk
```

### `Repository index signature verification failed`

`index.json` was modified after signing. Rebuild and re-sign the repository:

```bash
ulpm repo index ./repo-packages release_key.priv
```

### `Pinned repository key fingerprint mismatch`

The repository key changed. If intentional:

```bash
ulpm repo remove myrepo
ulpm repo add myrepo https://repo.example.com/ulpm new_key.pub
```

## Repositories

### `Could not update repository`

- Check the URL and network access.
- Confirm `index.json` and `index.json.sig` are reachable.
- Local repositories must already contain both files.
- The previous cached index is kept when an update fails.

### `No matching packages found`

- Confirm the repository is enabled: `ulpm repo list`.
- Refresh: `ulpm repo update`.
- Check the package ID and architecture.
- Restrict troubleshooting to one repository with `--repo <name>`.

### `Repository index schema invalid`

Rebuild with the current `ulpm repo index`. Common causes:

- Duplicate `id|arch` entries
- Missing or malformed `sha256`
- A package filename containing `..` or not ending in `.lpk`
- An unsupported `format` value

## Dependencies

### `Missing dependency` or `version mismatch`

```bash
ulpm deps check app.lpk
ulpm deps resolve <app-id>
ulpm transaction install <app-id>
```

If no repository provides the dependency, install it manually as an LPK or rebuild the package without the dependency.

### `Dependency cycle detected`

The manifests form a loop. Break the cycle in the packaging metadata; ULPM cannot install a cyclic graph.

### `Resolve declared dependencies before installing`

`ulpm install` only installs a single package whose dependencies are already satisfied. Use `ulpm transaction install` to resolve and install the full chain.

## Transactions

### A transaction was interrupted

```bash
ulpm transaction recover
```

### Upgrades fail and roll back

Read the failing package error, then retry only the affected app. A failed multi-package transaction is rolled back entirely.

### `CRITICAL: Rollback failed`

The snapshot is retained at the path printed by ULPM. Inspect it and restore manually if needed:

```text
~/.cache/ulpm/transactions/
~/.local/state/ulpm/wal/
```

Do not delete WAL files while a transaction is interrupted; run recovery instead.

## Disk usage

```bash
du -sh ~/.local/share/ulpm ~/.cache/ulpm ~/.var/app
ulpm history
ulpm clean
```

`ulpm clean` removes orphaned mount points and temporary build/mount directories, not installed apps, repository indexes or history.

Purge an app's sandbox data:

```bash
ulpm remove --purge <app>
```

Remove old history snapshots manually only if you accept losing rollback points.

## Desktop integration

### No launcher or icon

```bash
ulpm integrate
update-desktop-database ~/.local/share/applications 2>/dev/null || true
gtk-update-icon-cache ~/.local/share/icons/hicolor 2>/dev/null || true
```

Launchers are written to `~/.local/share/applications/<app_id>.desktop` and icons to `~/.local/share/icons/hicolor/`.

### Launcher does nothing

Run the app in a terminal and check for sandbox or permission errors:

```bash
ulpm run <app>
```

## Search and GitHub

### GitHub API rate limit

```bash
ulpm token <PAT>
ulpm doctor
```

The token is stored in `~/.config/ulpm/ulpm.conf` with mode `0600`; `GITHUB_TOKEN` overrides it.

### `ulpm self-update` fails

Set the upstream repository:

```bash
ULPM_GITHUB_REPO=owner/repo ulpm self-update
```

Self-update refuses to run when `ULPM_LIB_DIR` is not configured or missing. Reinstall with `install.sh` if the installation is damaged.

## Getting more detail

- `bash -x "$(command -v ulpm)" <command>` traces the shell execution.
- `ulpm inspect <package>` shows the manifest and signature status.
- `ulpm permissions <app>` shows effective permissions and override status.
- `mount | grep ulpm` lists active FUSE mounts.
- `journalctl` may show AppArmor, SELinux, kernel or compositor denials.
- Report reproducible bugs with distribution, kernel, architecture, `ulpm doctor` output and the exact command.

## Related documents

- [Configuration](configuration.md)
- [Permissions](permissions.md)
- [Security model](security.md)
- [CLI reference](cli-reference.md)
