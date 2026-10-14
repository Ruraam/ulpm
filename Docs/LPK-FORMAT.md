# `.lpk` format, version 5

An `.lpk` is a **SquashFS image** (zstd-compressed) optionally followed by a **104-byte signature
trailer**. It is mounted read-only via `squashfuse`; nothing is extracted to disk at run time.

## Image layout
```
meta/manifest.json      required, see schema below
meta/icon.png           optional application icon (standard 256x256or 512x512)
meta/...                optional metadata (desktop entries, translation strings)
root/                   application payload, mounted at /app inside the sandbox
```
A package whose `root/` contains `etc/`,`usr/`, and `bin/` (or package `type: "rootfs"`) is treated as a **RootFS** and is run as the sandbox root (`/`) instead of being isolated under `/app`.

---

## Manifest (`meta/manifest.json`)

### Core Metadata Fields
| Field | Type | Required | Notes |
|-------|------|----------|-------|
| `format_version` | integer | no (default: 1) | Engine support sversions 1 through **5**. |
| `id` | string | **yes** | Reverse-DNS identifier: `^[A-Za-z0-9][A-Za-z0-9._-]*$`, no`..`. |
| `name` | string | **yes** | Binary/Application slug: alphanumeric, dots, underscores, hyphens. |
| `exec` | string | **yes** | Entrypoint path relative to `root/` (e.g. `bin/main`, `AppRun`). |
| `version` | string | no | Freeform semantic version string (default: `"1.0.0"`). |
| `arch` | string | no | Target CPU architecture (`x86_64`, `aarch64`, `armhf`, `all`). |
| `runtime` | string | no | Optional shared runtime identifier (e.g. `org.freedesktop.Platform//23.08`). |
| `shared` | boolean | no | If `true`, indicates this package acts as a reusable shared runtime base. |
| `network` | boolean | no | **v1-v4 legacy compatibility**. Overridden by `permissions.network` in v5. |

---

### Declarative Sandbox Permissions (`permissions` block, Schema v5)

Starting with `format_version: 5`, permissions are declared in astructured `permissions` object:
