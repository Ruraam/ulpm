# Repositories

A ULPM repository is a static directory containing signed index metadata and `.lpk` packages. There is no repository daemon or database service.

## Layout

```text
repository/
  index.json
  index.json.sig
  release_key.pub
  example_amd64.lpk
  other_arm64.lpk
```

The index lists packages by ID and architecture and includes each package's SHA-256. The signature is a detached Ed25519 signature over `index.json`.

## Create a repository

### 1. Create a publisher key

```bash
ulpm keygen release_key
```

Keys are stored in:

```text
~/.config/ulpm/keys/release_key.priv
~/.config/ulpm/keys/release_key.pub
```

### 2. Sign packages

`ulpm pack` signs with the default key. To use the release key:

```bash
ulpm sign example_amd64.lpk ~/.config/ulpm/keys/release_key.priv
```

Every package in the repository must be signed. The repository index itself is signed separately.

### 3. Build the index

```bash
ulpm repo index ./repo-packages ~/.config/ulpm/keys/release_key.priv
```

This creates or replaces:

```text
repo-packages/index.json
repo-packages/index.json.sig
```

Rules:

- Only `*.lpk` files in the directory are indexed.
- Invalid or unreadable LPKs are skipped with a warning.
- The index must contain one version per `id|arch`.
- Packages are sorted by `id` and `arch` for deterministic output.
- The public key used to verify the repository must be distributed separately.

Copy the public key into the repository directory for convenience:

```bash
cp ~/.config/ulpm/keys/release_key.pub ./repo-packages/
```

## Add a repository

```bash
ulpm repo add <name> <url> <public-key.pub>
```

Examples:

```bash
ulpm repo add local ./repo-packages ./repo-packages/release_key.pub
ulpm repo add myrepo https://repo.example.com/ulpm ./release_key.pub
```

What `repo add` does:

1. Validates the repository name and Ed25519 public key.
2. Stores the public key at `~/.config/ulpm/repos/<name>.pub`.
3. Records its SHA-256 fingerprint in `~/.config/ulpm/repos/<name>.json`.
4. Downloads and verifies `index.json` and `index.json.sig`.
5. Adds the publisher key to the LPK trust store.
6. Updates the cached index.

A repository name must match `[A-Za-z0-9][A-Za-z0-9._-]{0,63}` and cannot contain `..`.

### HTTPS and local repositories

| URL form | Supported |
| :--- | :---: |
| `https://...` | Yes |
| `http://...` | Yes (not recommended) |
| Absolute local directory | Yes |
| `./relative` or `../relative` | Yes |
| `file://...` | Yes |

Local repositories must already contain `index.json` and `index.json.sig`. Missing files cause `repo add` to fail.

## Manage repositories

```bash
ulpm repo list
ulpm repo update [name]
ulpm repo verify [name]
ulpm repo enable <name>
ulpm repo disable <name>
ulpm repo remove <name>
ulpm repo search <query>
ulpm repo install <app-id> [repository]
```

- `update` fetches and verifies indexes for enabled repositories. A failed repository keeps its previous cached index.
- `verify` re-checks cached indexes against pinned keys.
- `enable`/`disable` toggle participation in updates, searches, installs and upgrades.
- `remove` deletes the configuration, pinned key and cached index.
- `search` refreshes indexes and searches cached metadata.
- `install` delegates to the transaction engine.

Top-level shortcuts:

```bash
ulpm update [name]
ulpm refresh [name]
```

## Install from a repository

```bash
ulpm install firefox
ulpm install io.lpk.firefox --repo myrepo
ulpm repo install io.lpk.firefox myrepo
```

Resolution behavior:

- The package ID or name is matched against enabled repository indexes.
- The highest compatible version wins across repositories.
- `--repo` restricts the search to one repository.
- The package is downloaded, its SHA-256 is checked against the index, then normal signature, dependency and publisher-pin checks run.

`ulpm upgrade` uses the same indexes to find newer versions of repository-tracked applications.

## Search output

```bash
ulpm repo search blender
```

Prints matching entries from cached indexes:

```text
ID                               NAME                   VERSION      ARCH     [REPO]
io.lpk.blender                   blender                4.2.1        amd64    [myrepo]
```

`ulpm search <query>` also queries GitHub releases and APT on Debian-like systems and offers an interactive installation menu.

## Repository key pinning

The repository key is pinned by fingerprint in `<name>.json`. On every update and verification:

- The presented public key must match the pinned file byte-for-byte.
- Its SHA-256 fingerprint must match `key_fingerprint_sha256`.
- The detached signature must verify over the exact `index.json` bytes.

To rotate a repository key:

```bash
ulpm repo remove myrepo
ulpm repo add myrepo https://repo.example.com/ulpm new_release_key.pub
```

This is intentionally explicit. Removing and re-adding trusts the new key.

This repository pin is separate from the per-application publisher pin stored in `installed.db`. Upgrading an installed app also requires the package signer to match the original publisher unless `ULPM_ALLOW_KEY_ROTATION=1` is set.

## Hosting

Any static HTTP server can host a repository. Example nginx location:

```nginx
location /ulpm/ {
    root /var/www;
    autoindex off;
    types {
        application/json json;
        text/plain sig;
        application/octet-stream lpk;
    }
}
```

Requirements:

- `index.json` and `index.json.sig` must be served unchanged.
- Package filenames must match the `file` field in the index.
- HTTPS is strongly recommended.
- Do not rewrite or compress `index.json` in a way that changes its bytes.

GitHub Pages works well: put the repository contents on a branch or in `/docs`, and use:

```text
https://<owner>.github.io/<repo>/
```

## `ulrm` repository manager

`ulrm` automates a local repository and publishing.

### Configuration

Set these environment variables as needed:

| Variable | Default |
| :--- | :--- |
| `REPO_NAME` | `myrepo` |
| `REPO_DIR` | `~/ulpm-repo` |
| `PACKAGES_DIR` | `$REPO_DIR/packages` |
| `KEY_NAME` | `release_key` |
| `KEY_DIR` | `~/.config/ulpm/keys` |
| `PUBLISH_METHOD` | `github` (`local`, `rsync`, `github`) |
| `REMOTE_PATH` | `user@server:/var/www/ulpm/` |
| `GITHUB_REPO` | `your-user/ulpm-packages` |
| `GITHUB_BRANCH` | `gh-pages` |
| `GITHUB_TOKEN` | empty (uses `gh`/git credentials otherwise) |

### Workflow

```bash
ulrm init
ulrm add ./example_amd64.lpk ./other_arm64.lpk
ulrm rebuild
ulrm publish
```

| Command | Description |
| :--- | :--- |
| `init` | Create the repository and generate the release key if missing |
| `add <files>` | Copy packages and sign unsigned ones with the release key |
| `rebuild`, `index` | Rebuild and sign `index.json`, refresh the public key |
| `publish` | Publish using `PUBLISH_METHOD` |
| `help` | Show usage |

Publishing modes:

- `local`: leaves the repository in `$PACKAGES_DIR` and prints the `ulpm repo add` command.
- `rsync`: mirrors the packages to `REMOTE_PATH`.
- `github`: publishes to a GitHub Pages branch and prints the public URL.

Manual equivalent:

```bash
ulpm repo index "$PACKAGES_DIR" "$KEY_DIR/$KEY_NAME.priv"
ulpm repo add "$REPO_NAME" "$PACKAGES_DIR" "$PACKAGES_DIR/$KEY_NAME.pub"
```

## Private repositories

A repository is just static files. For private HTTPS access, use your web server's authentication or a token-bearing proxy. ULPM's `curl` requests do not currently provide repository-specific authentication headers; for GitHub release downloads, `GITHUB_TOKEN` is used.

## Troubleshooting

| Error | Likely cause |
| :--- | :--- |
| `Repository index, signature, or pinned key missing` | Files absent or wrong URL |
| `Pinned repository key fingerprint mismatch` | Key changed without re-adding the repository |
| `Repository index signature verification failed` | `index.json` was modified after signing |
| `Repository index schema invalid` | Wrong format, duplicate `id|arch`, invalid fields |
| `Could not update repository` | Network error; previous cached index is retained |
| `No matching packages found` | No enabled index contains the package |

See [Troubleshooting](troubleshooting.md).

## Related documents

- [Configuration](configuration.md)
- [Security model](security.md)
- [Packaging](packaging.md)
- [Dependencies and transactions](dependencies-transactions.md)
