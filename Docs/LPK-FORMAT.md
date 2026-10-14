# `.lpk` format, version 4

An `.lpk` is a **SquashFS image** (zstd-compressed) optionally followed by a **104-byte signature
trailer**. It is mounted read-only with `squashfuse`; nothing is extracted to disk at run time.

## Image layout
```
meta/manifest.json      required, see below
meta/...                optional metadata (icon, desktop entry data)
root/                   application payload, mounted at /app inside the sandbox
```
A package whose `root/` contains `etc/`, `usr/` and `bin/` is treated as a **RootFS** and is run
as the sandbox root instead of being mounted under `/app`.

## Manifest (`meta/manifest.json`)
| Field | Type | Required | Notes |
|-------|------|----------|-------|
| `format_version` | number | no (defaults to 1) | must be between 1 and the engine's supported version (4) |
| `id` | string | **yes** | reverse-DNS style, `[A-Za-z0-9_][A-Za-z0-9._-]*`, no `..` |
| `name` | string | **yes** | no `/`, `\|`, control characters, leading `-`, nor `.`/`..` |
| `exec` | string | **yes** | path relative to `root/` |
| `version` | string | no | free text, `\|` and newlines are replaced |
| `arch` | string | no | e.g. `amd64`, `arm64` |
| `network` | boolean | no | `false` starts the app without network (default `true`) |

`id` and `name` are validated by the engine before any path, database or D-Bus use.
Packages with an invalid `id`/`name` are refused.

## Signature trailer (104 bytes, at end of file)
```
offset (from start of trailer)   size   content
0                                8      magic "ULPM_SIG"
8                                32     Ed25519 public key (raw)
40                               64     Ed25519 signature
```
- The signature covers **every byte before the trailer** (the SquashFS image).
- The embedded public key is compared with the keys in `~/.config/ulpm/keys/*.pub` and
  `~/.config/ulpm/trusted_keys/*.pub`.
- Verification outcomes: `trusted`, `unsigned`, `signed by unknown key`, `forged/corrupted`.
  `forged/corrupted` is always refused; the others follow `ULPM_STRICT_SIGNATURES`.
- Two equivalent signing schemes are accepted for compatibility with different OpenSSL builds:
  `openssl dgst -sha512 -sign` over the payload, or pure Ed25519 over the binary SHA-512 digest of
  the payload (`openssl pkeyutl -rawin`).
- Re-signing (`ulpm sign`) strips any existing trailer first.

## Compatibility rules
- Readers must ignore unknown manifest fields.
- A manifest with `format_version` greater than the engine's is rejected.
