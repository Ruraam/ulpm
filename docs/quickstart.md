# Quick start

This guide builds, signs, runs and installs a minimal application, then introduces repositories, permissions and transactions.

## 1. Verify the installation

```bash
ulpm --version
ulpm doctor
```

`ulpm doctor` reports the sandbox engine, mount support, D-Bus proxy, GPU devices and required tools. If Bubblewrap is unavailable, ULPM refuses to run applications unless you explicitly opt into unsafe mode.

## 2. Create a minimal application

```bash
mkdir -p hello
cat > hello/AppRun <<'EOF'
#!/usr/bin/env bash
echo "Hello from ULPM!"
echo "Args: $*"
EOF
chmod +x hello/AppRun
```

## 3. Build an LPK

```bash
ulpm pack ./hello hello hello_amd64.lpk 1.0.0
```

What happens:

- A Schema v5 manifest is generated with ID `io.lpk.hello`
- `AppRun` is detected as the entrypoint
- On first use, ULPM creates and trusts a default Ed25519 keypair in `~/.config/ulpm/keys/`
- The SquashFS image is compressed with zstd and sealed with a 104-byte signature trailer

Inspect the result:

```bash
ulpm inspect hello_amd64.lpk
```

## 4. Run the package

Run directly from the file:

```bash
ulpm run ./hello_amd64.lpk
```

Pass application arguments after `--`:

```bash
ulpm run ./hello_amd64.lpk -- one two
```

Install it:

```bash
ulpm install ./hello_amd64.lpk
ulpm list
ulpm run hello
```

The application ID is the stable identifier; the name is used for directories and launchers:

| Field | Value |
| :--- | :--- |
| ID | `io.lpk.hello` |
| Name | `hello` |
| Version | `1.0.0` |
| Executable | `AppRun` |

## 5. Inspect and change permissions

```bash
ulpm permissions hello
```

By default, the generated manifest grants network, GPU, audio and GUI access, keeps `$HOME` isolated, and exposes the host Downloads directory read-write.

Disable network access persistently:

```bash
ulpm override hello --no-net
ulpm permissions hello
```

Reset all local overrides:

```bash
ulpm permissions reset hello
```

See [Permissions and sandbox](permissions.md) for the full model.

## 6. Publish a local signed repository

Create a release key and sign the package with it:

```bash
ulpm keygen release_key
ulpm sign hello_amd64.lpk ~/.config/ulpm/keys/release_key.priv
```

Build a repository directory:

```bash
mkdir -p repo-packages
cp hello_amd64.lpk repo-packages/
cp ~/.config/ulpm/keys/release_key.pub repo-packages/
ulpm repo index repo-packages ~/.config/ulpm/keys/release_key.priv
```

Register it:

```bash
ulpm repo add local ./repo-packages ./repo-packages/release_key.pub
```

Install from the repository by name or ID:

```bash
ulpm repo search hello
ulpm install hello
```

`ulpm repo add` pins the repository key fingerprint and updates `index.json`. Subsequent updates must be signed by the same key unless the repository is removed and re-added.

See [Repositories](repositories.md) for HTTPS hosting, GitHub Pages and `ulrm`.

## 7. Atomic multi-package operations

Resolve a dependency plan:

```bash
ulpm deps resolve io.lpk.hello
```

Install several packages atomically:

```bash
ulpm transaction install io.lpk.hello io.lpk.other
```

If any download, signature, checksum or database write fails, the transaction restores the previous state.

## 8. History and rollback

Every upgrade keeps the previous package in history:

```bash
ulpm history hello
ulpm rollback hello
```

Rollback verifies the historical package signature and the publisher fingerprint before switching versions.

## 9. Ephemeral execution

Run a remote package without installing it:

```bash
ulpm stream https://example.com/app_amd64.lpk
ulpm stream owner/repo
ulpm stream owner/repo@v1.2.3
```

The package is downloaded to `/dev/shm` when enough RAM is available and wiped when the application exits.

## 10. Remove the application

```bash
ulpm remove hello
```

To also delete persistent sandbox data and overrides:

```bash
ulpm remove --purge hello
```

## Next steps

- [CLI reference](cli-reference.md)
- [Packaging](packaging.md)
- [LPK format](lpk-format.md)
- [Troubleshooting](troubleshooting.md)
