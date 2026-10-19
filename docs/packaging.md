# Packaging

ULPM can package directories, AppImages, Debian packages, tar archives and zip archives into signed `.lpk` bundles.

## Build requirements

```bash
sudo apt install squashfs-tools jq openssl file binutils zstd
```

`ulpm doctor` reports missing runtime tools. Build-specific tools:

| Tool | Use |
| :--- | :--- |
| `mksquashfs` | Creating the LPK image |
| `unsquashfs` | Inspecting and extracting sources |
| `readelf` | Safe AppImage offset detection and ELF checks |
| `file` | Entrypoint identification |
| `tar`, `ar`, `dpkg-deb` | Archive and Debian extraction |
| `openssl` | Ed25519 signing and verification |

## Build an application

```bash
ulpm pack [flags] <source> [name] [out.lpk] [version]
```

Examples:

```bash
ulpm pack ./myapp
ulpm pack ./myapp myapp myapp_amd64.lpk 1.2.0
ulpm pack ./myapp.AppImage myapp myapp_amd64.lpk 1.2.0
ulpm pack ./myapp.tar.gz myapp
ulpm pack ./debian-package.deb myapp
```

Defaults:

- `name` comes from the source basename, with `io.lpk.` stripped and invalid characters removed.
- `out.lpk` defaults to `<name>_<host-arch>.lpk`.
- `version` defaults to `1.0.0`.
- The package is signed with the default Ed25519 key, created on first use.

### Flags

| Flag | Description |
| :--- | :--- |
| `--no-scan`, `--fast` | Skip dynamic library bundling |
| `--shared` | Mark the output as a shared runtime (`shared: true`) |
| `--runtime <id>` | Declare a shared runtime dependency |
| `--dependency <id>` | Add a dependency; repeatable |
| `--depends <id[op version]>` | Same as `--dependency` |

Dependency operators: `>=`, `<=`, `==`, `=`, `>`, `<`.

```bash
ulpm pack ./myapp myapp myapp_amd64.lpk 1.0.0 \
  --runtime org.example.runtime \
  --dependency io.lpk.sdk \
  --depends 'io.lpk.runtime>=2.1.0'
```

### Source modes

#### Raw source

A directory without a manifest, or a supported archive, is assembled into:

```text
meta/manifest.json
root/
  AppRun
  ...
```

The entrypoint is auto-detected. A manifest is generated with ID `io.lpk.<name>`, the selected architecture, default permissions and an empty dependency list.

#### Pre-structured source

A directory containing `meta/manifest.json` (or `manifest.json`) is packed as-is. This is required for:

- Rootfs images
- Shared runtimes
- Custom payload layouts
- Manifests with precise permissions or dependencies

Pack flags can merge additional dependencies, runtime and `shared` into a pre-structured manifest.

## Dynamic library bundling

For application packages, `ulpm pack`:

1. Finds the host dynamic loader.
2. Resolves `DT_NEEDED` libraries with the loader.
3. Copies non-host-provided libraries into `root/lib`.
4. Repeats up to 10 passes to capture transitive dependencies.

The following are intentionally **not** bundled, because the host or runtime provides them:

```text
ld-linux*, ld-musl*, libc, libm, libpthread, libdl, librt, libresolv, libutil,
libnss_*, libGL*, libEGL*, libGLX*, libGLdispatch*, libdrm*, libvulkan*,
libX11*, libxcb*, libXau*, libasound*, libpulse*, libpipewire*, libwayland*
```

Skip bundling for rootfs images, or with `--no-scan`, `--fast` or `ULPM_NO_SCAN=1`.

## Reproducible output

- Timestamps are normalized to `SOURCE_DATE_EPOCH` (default `0`).
- Permissions are normalized (`0755` directories and executables, `0644` files).
- SquashFS is created with `-all-root`, `-no-xattrs`, `-mkfs-time` and `-reproducible` when supported.
- zstd level defaults to `15`; set `ULPM_ZSTD_LEVEL=1..22`.

## Debian conversion

```bash
ulpm deb-pack [pack flags] <pkg|file.deb|owner/repo> [name] [out.lpk] [version]
```

Accepted inputs:

- APT package name, for example `firefox-esr`
- Local `.deb` file
- GitHub repository or `owner/repo[@tag]` containing a `.deb` release asset

Behavior:

1. Downloads the primary package with `apt-get download` or `curl`.
2. Reads `Package`, `Version` and `Architecture` from the Debian control metadata.
3. Downloads direct library `Depends` available through APT (best effort).
4. Skips packages whose architecture does not match the host.
5. Extracts the archives into a staging root.
6. Creates an `AppRun` that sets `PATH` and `LD_LIBRARY_PATH`.
7. Removes host-provided core, graphics, audio and display libraries.
8. Calls `ulpm pack`, which bundles remaining libraries and signs the result.

Limitations:

- Dependency resolution is best-effort and based on APT metadata; non-library dependencies may need manual additions.
- Debian maintainer scripts (`postinst`, `prerm`, ...) are not executed.
- Epoch prefixes are stripped from versions.
- A package that relies on host system services may need manifest permission changes or runtime files.

## AppImage and archive handling

### AppImage

ULPM extracts AppImages without executing them:

1. Reads the ELF section header offset to locate the SquashFS payload.
2. Runs `unsquashfs -o <offset>`.
3. Falls back to `unsquashfs` directly, then to execution only when `ULPM_ALLOW_APPIMAGE_EXEC=1`.

The intentional fallback flag exists because executing an AppImage during packaging is a trust decision.

### Tar and zip

Tar extraction uses Python's `tarfile` when available and rejects absolute paths, `..`, NUL bytes and escaping symlinks. Zip extraction uses a safe Python extractor when available; otherwise it validates entries before using the system tool.

## Signing

Every `pack` and `deb-pack` output is signed by `_pack_and_seal`:

```bash
ulpm sign <package.lpk> [private-key]
```

- The default keypair is created and trusted on first use.
- An existing 104-byte trailer is stripped before signing.
- The signature covers the SHA-256 digest of the payload.
- The public key is embedded in the trailer.

For a release key:

```bash
ulpm keygen release_key
ulpm pack ./myapp myapp myapp_amd64.lpk 1.0.0
ulpm sign myapp_amd64.lpk ~/.config/ulpm/keys/release_key.priv
```

Distribute `release_key.pub` so users can trust the package:

```bash
ulpm trust release_key.pub
```

## Shared runtimes

Create a runtime from a pre-structured rootfs-like tree. Set `shared` and `runtime_abi` in `meta/manifest.json` before packaging:

```json
{
  "format_version": 5,
  "id": "org.example.runtime",
  "name": "runtime",
  "version": "1.0.0",
  "arch": "amd64",
  "shared": true,
  "runtime_abi": "glibc-2.39",
  "permissions": {}
}
```

Then:

```bash
ulpm pack --shared ./runtime-root runtime runtime_amd64.lpk 1.0.0
ulpm runtime install runtime_amd64.lpk
```

Applications select it with:

```json
{
  "runtime": "org.example.runtime",
  "runtime_abi": "glibc-2.39"
}
```

## Publishing a repository

A minimal static repository contains:

```text
index.json
index.json.sig
example_amd64.lpk
release_key.pub
```

Build it:

```bash
ulpm repo index ./repo-packages ~/.config/ulpm/keys/release_key.priv
```

Upload the directory over HTTPS, or serve it locally:

```bash
ulpm repo add local ./repo-packages ./repo-packages/release_key.pub
```

The repository index must contain exactly one version per `id|arch`. Remove old packages before rebuilding if you publish a new version.

See [Repositories](repositories.md) and the `ulrm` workflow.

## Cross-architecture builds

`ulpm pack` uses the host architecture. There is no cross-compilation or emulation layer. Build each architecture natively or under emulation, and publish separate files with distinct `arch` values.

## Release checklist

- [ ] Manifest has the intended `id`, `name`, `version`, `arch` and permissions
- [ ] `ulpm inspect <package>.lpk` reports a trusted signature
- [ ] `ulpm deps check <manifest>` passes
- [ ] Package runs with `ulpm run <package>.lpk`
- [ ] GUI/audio/network permissions are minimal but sufficient
- [ ] Repository index rebuilt and signed
- [ ] Key fingerprint distributed out of band
- [ ] Tests and smoke run completed on each target architecture

## Related documents

- [LPK format](lpk-format.md)
- [Repositories](repositories.md)
- [Security model](security.md)
- [Troubleshooting](troubleshooting.md)
