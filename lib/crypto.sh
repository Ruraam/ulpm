#!/usr/bin/env bash
# ==============================================================================
# lib/crypto.sh - ULPM Ed25519 signing, verification, trust & repository crypto
# Signature footer (104 bytes):
#   - Magic "ULPM_SIG"       (8 bytes)
#   - Raw Ed25519 Public Key (32 bytes)
#   - Raw Ed25519 Signature  (64 bytes)
# ULPM v6.0.0 Architecture Engine (v5.3 Proven Zero-Copy Streamed Crypto)
# ==============================================================================

SIG_MAGIC="ULPM_SIG"
SIG_MAGIC_LEN=8
SIG_RAW_LEN=64
SIG_PUB_LEN=32
SIG_FOOTER_SIZE=104

_crypto_size() {
    local f="${1:-}"
    stat -c '%s' -- "$f" 2>/dev/null || stat -f '%z' -- "$f" 2>/dev/null || {
        local sz
        sz="$(wc -c < "$f" 2>/dev/null)" || return 1
        printf '%s\n' "${sz//[[:space:]]/}"
    }
}

_crypto_trusted_dir() {
    local base="${ULPM_CONFIG_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/ulpm}"
    printf '%s\n' "$base/trusted_keys"
}

_crypto_keys_dir() {
    local base="${ULPM_CONFIG_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/ulpm}"
    printf '%s\n' "${ULPM_KEYS_DIR:-$base/keys}"
}

ensure_crypto_prerequisites() {
    check_dependencies openssl cmp truncate tail head stat mktemp cp mv chmod mkdir rm cat dirname basename wc grep tr || return 1

    if ! openssl genpkey -algorithm Ed25519 -help > /dev/null 2>&1 && \
       ! openssl list -public-key-algorithms 2>/dev/null | grep -qi 'ED25519'; then
        error "Installed OpenSSL provider does not support Ed25519."
        return 1
    fi
    if ! openssl pkeyutl -help 2>&1 | grep -qw -- '-rawin'; then
        error "OpenSSL with pkeyutl -rawin support is required."
        return 1
    fi
    return 0
}

_crypto_extract_raw_pubkey() {
    local in_key="$1" out_raw="$2"
    [[ -f "$in_key" && -r "$in_key" ]] || return 1
    openssl pkey -pubin -in "$in_key" -outform DER 2>/dev/null | tail -c "$SIG_PUB_LEN" > "$out_raw" 2>/dev/null || return 1
    [[ "$(_crypto_size "$out_raw")" -eq "$SIG_PUB_LEN" ]]
}

_crypto_is_ed25519_key() {
    local key="${1:-}" kind="${2:-private}" der_tmp prefix size
    [[ -f "$key" && -r "$key" ]] || return 1
    der_tmp="$(mktemp "${TMPDIR:-/tmp}/ulpm-keycheck.XXXXXX")" || return 1
    if [[ "$kind" == "public" ]]; then
        openssl pkey -pubin -in "$key" -pubout -outform DER -out "$der_tmp" 2>/dev/null || { rm -f -- "$der_tmp"; return 1; }
    else
        openssl pkey -in "$key" -pubout -outform DER -out "$der_tmp" 2>/dev/null || { rm -f -- "$der_tmp"; return 1; }
    fi
    size="$(_crypto_size "$der_tmp")" || { rm -f -- "$der_tmp"; return 1; }

    if command -v od >/dev/null 2>&1; then
        prefix="$(head -c 12 -- "$der_tmp" | od -An -tx1 | tr -d ' \n')"
    elif command -v hexdump >/dev/null 2>&1; then
        prefix="$(head -c 12 -- "$der_tmp" | hexdump -v -e '1/1 "%02x"')"
    else
        prefix="$(openssl asn1parse -inform DER -in "$der_tmp" 2>/dev/null | grep -q 'ED25519' && echo '302a300506032b6570032100' || true)"
    fi

    rm -f -- "$der_tmp"
    [[ "$size" -eq 44 && "$prefix" == "302a300506032b6570032100" ]]
}

_crypto_valid_key_name() {
    [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ && "$1" != "." && "$1" != ".." ]]
}

crypto_fingerprint() {
    local pub_key="${1:-}" der_tmp hash
    [[ -f "$pub_key" && -r "$pub_key" ]] || return 1
    der_tmp="$(mktemp "${TMPDIR:-/tmp}/ulpm-fp.XXXXXX")" || return 1
    if ! openssl pkey -pubin -in "$pub_key" -pubout -outform DER -out "$der_tmp" 2>/dev/null; then
        rm -f -- "$der_tmp"
        return 1
    fi
    hash="$(openssl dgst -sha256 "$der_tmp" 2>/dev/null | awk '{print $NF}')"
    rm -f -- "$der_tmp"
    [[ -n "$hash" ]] || return 1
    printf '%s\n' "$hash"
}

_crypto_generate_keypair() {
    local name="$1" dir="$2"
    local priv_path="$dir/${name}.priv"
    local pub_path="$dir/${name}.pub"
    local tmp_priv tmp_pub

    tmp_priv="$(mktemp "$dir/.${name}.priv.XXXXXX")" || return 1
    tmp_pub="$(mktemp "$dir/.${name}.pub.XXXXXX")" || { rm -f -- "$tmp_priv"; return 1; }

    if ! (umask 077 && openssl genpkey -algorithm Ed25519 -out "$tmp_priv") 2>/dev/null || \
       ! openssl pkey -in "$tmp_priv" -pubout -out "$tmp_pub" 2>/dev/null; then
        rm -f -- "$tmp_priv" "$tmp_pub"
        return 1
    fi

    chmod 600 -- "$tmp_priv" || { rm -f -- "$tmp_priv" "$tmp_pub"; return 1; }
    chmod 644 -- "$tmp_pub"  || { rm -f -- "$tmp_priv" "$tmp_pub"; return 1; }

    sync_file "$tmp_priv" 2>/dev/null || true
    sync_file "$tmp_pub" 2>/dev/null || true

    mv -f -- "$tmp_priv" "$priv_path" || { rm -f -- "$tmp_priv" "$tmp_pub"; return 1; }
    mv -f -- "$tmp_pub" "$pub_path"   || { rm -f -- "$tmp_priv"; return 1; }
    sync_dir "$dir" 2>/dev/null || true

    cmd_trust "$pub_path" >/dev/null 2>&1 || true
    return 0
}

ensure_default_keypair() {
    local key_dir
    key_dir="$(_crypto_keys_dir)"
    local default_priv="$key_dir/default.priv"
    local default_pub="$key_dir/default.pub"

    if [[ -f "$default_priv" && -f "$default_pub" ]]; then
        printf '%s\n' "$default_priv"
        return 0
    fi
    if [[ -e "$default_priv" || -e "$default_pub" ]]; then
        error "Incomplete default keypair exists; refusing to overwrite it."
        return 1
    fi

    (umask 077 && mkdir -p -- "$key_dir") || { error "Cannot create key directory: $key_dir"; return 1; }
    ensure_crypto_prerequisites || return 1

    if ! _crypto_generate_keypair "default" "$key_dir"; then
        error "Failed to generate default Ed25519 keypair."
        return 1
    fi

    printf '%s\n' "$default_priv"
}

cmd_keygen() {
    local key_name="${1:-default}"
    _crypto_valid_key_name "$key_name" || { error "Invalid key name: use 1-64 alphanumeric chars, dots, underscores or hyphens."; return 1; }
    ensure_crypto_prerequisites || return 1

    local key_dir
    key_dir="$(_crypto_keys_dir)"
    local priv_path="$key_dir/${key_name}.priv"
    local pub_path="$key_dir/${key_name}.pub"

    if [[ -e "$priv_path" || -e "$pub_path" ]]; then
        error "Key file already exists: $priv_path or $pub_path"
        return 1
    fi
    (umask 077 && mkdir -p -- "$key_dir") || { error "Cannot create key directory: $key_dir"; return 1; }
    log "Generating Ed25519 keypair ($key_name)..."

    if ! _crypto_generate_keypair "$key_name" "$key_dir"; then
        error "Key generation failed."
        return 1
    fi

    local fp
    fp="$(crypto_fingerprint "$pub_path" 2>/dev/null || true)"
    info "Private key generated: $priv_path"
    info "Public key generated:  $pub_path (Trusted)"
    [[ -n "$fp" ]] && info "SHA-256 Fingerprint: $fp"
}

has_sig_magic() {
    local file="${1:-}" size
    [[ -f "$file" && -r "$file" ]] || return 1
    size="$(_crypto_size "$file")" || return 1
    [[ "$size" =~ ^[0-9]+$ && "$size" -ge "$SIG_FOOTER_SIZE" ]] || return 1

    # Standard ULPM layout check (Offset -104: ULPM_SIG)
    if cmp -s -n "$SIG_MAGIC_LEN" \
        <(tail -c "$SIG_FOOTER_SIZE" -- "$file" 2>/dev/null) \
        <(printf '%s' "$SIG_MAGIC"); then
        return 0
    fi

    # Alternative layout fallback (Offset -8: LPK_SIG\0)
    tail -c "$SIG_MAGIC_LEN" -- "$file" 2>/dev/null | cmp -s - <(printf 'LPK_SIG\0')
}

strip_signature() {
    local file="${1:-}" size
    [[ -f "$file" && -w "$file" ]] || return 1
    size="$(_crypto_size "$file")" || return 1
    if [[ "$size" -ge "$SIG_FOOTER_SIZE" ]] && has_sig_magic "$file"; then
        truncate -s -"$SIG_FOOTER_SIZE" -- "$file" || return 1
        sync_file "$file" 2>/dev/null || true
    fi
}

cmd_sign() {
    local lpk_file="${1:-}" priv_key="${2:-}"
    [[ -n "$lpk_file" ]] || { error "Usage: ulpm sign <package.lpk> [priv_key]"; return 1; }
    [[ -f "$lpk_file" && -r "$lpk_file" && -w "$lpk_file" && ! -L "$lpk_file" ]] || {
        error "Package must be a readable, writable regular file: $lpk_file"; return 1
    }
    if [[ -z "$priv_key" ]]; then priv_key="$(ensure_default_keypair)" || return 1; fi
    [[ -f "$priv_key" && -r "$priv_key" && ! -L "$priv_key" ]] || { error "Private key not found or unreadable: $priv_key"; return 1; }
    ensure_crypto_prerequisites || return 1
    _crypto_is_ed25519_key "$priv_key" private || { error "Invalid or non-Ed25519 private key: $priv_key"; return 1; }

    local base tmp_dir sig_tmp pub_raw_tmp hash_tmp payload_size
    base="$(basename -- "$lpk_file")"
    tmp_dir="$(mktemp -d "${ULPM_CACHE_HOME:-${TMPDIR:-/tmp}}/sign_XXXXXX")" || return 1
    sig_tmp="$tmp_dir/sig.bin"
    pub_raw_tmp="$tmp_dir/pub_raw.bin"
    hash_tmp="$tmp_dir/hash.bin"

    # Strip existing signature safely in place
    strip_signature "$lpk_file" || { rm -rf -- "$tmp_dir"; return 1; }
    payload_size="$(_crypto_size "$lpk_file")" || { rm -rf -- "$tmp_dir"; return 1; }

    # Extract 32-byte raw public key
    if ! openssl pkey -in "$priv_key" -pubout -outform DER 2>/dev/null | tail -c "$SIG_PUB_LEN" > "$pub_raw_tmp" || \
       [[ "$(_crypto_size "$pub_raw_tmp")" -ne "$SIG_PUB_LEN" ]]; then
        error "Could not derive a valid Ed25519 public key from $priv_key."
        rm -rf -- "$tmp_dir"
        return 1
    fi

    # Streamed SHA256 digest: fast & memory safe even on multi-GB archives
    log "Hashing payload ($payload_size bytes)..."
    if ! openssl dgst -sha256 -binary < "$lpk_file" > "$hash_tmp"; then
        error "Failed to compute package digest."
        rm -rf -- "$tmp_dir"
        return 1
    fi

    # Sign the 32-byte binary digest directly
    if ! openssl pkeyutl -sign -rawin -inkey "$priv_key" -in "$hash_tmp" -out "$sig_tmp" 2>/dev/null || \
       [[ "$(_crypto_size "$sig_tmp")" -ne "$SIG_RAW_LEN" ]]; then
        error "Ed25519 signing failed."
        rm -rf -- "$tmp_dir"
        return 1
    fi

    # Append 104-byte sealed trailer: [ULPM_SIG (8B)] + [PubKey (32B)] + [Sig (64B)]
    {
        printf '%s' "$SIG_MAGIC"
        cat -- "$pub_raw_tmp" "$sig_tmp"
    } >> "$lpk_file" || { rm -rf -- "$tmp_dir"; return 1; }

    sync_file "$lpk_file" 2>/dev/null || true
    rm -rf -- "$tmp_dir"
    info "Package sealed successfully: $base (104-byte Ed25519 signature attached)"
}

ulpm_signature_strict() {
    case "${ULPM_STRICT_SIGNATURES:-1}" in
        1|true|TRUE|yes|YES|on|ON) return 0 ;;
        0|false|FALSE|no|NO|off|OFF)  return 1 ;;
        *) error "Invalid ULPM_STRICT_SIGNATURES value; use true/false or 1/0."; return 2 ;;
    esac
}

check_package_signature() {
    local package="${1:-}" rc=0 strict_rc=0
    [[ -n "$package" ]] || { error "Package path required for signature verification."; return 1; }
    verify_package "$package" || rc=$?
    case "$rc" in
        0) return 0 ;;
        2)
            ulpm_signature_strict || strict_rc=$?
            if (( strict_rc == 1 )) && [[ "${ULPM_ALLOW_UNSIGNED:-0}" == 1 ]]; then
                warn "Accepting unsigned package only because ULPM_STRICT_SIGNATURES=0 and ULPM_ALLOW_UNSIGNED=1."
                return 0
            fi
            error "Unsigned package rejected. Package must contain a valid Ed25519 trailer."
            return 1
            ;;
        3)
            ulpm_signature_strict || strict_rc=$?
            if (( strict_rc == 1 )); then
                warn "Package signature is mathematically valid but publisher key is untrusted (Strict Mode OFF)."
                return 0
            fi
            error "Package signed by an untrusted key; trust it via: ulpm trust <key.pub>"
            return 1
            ;;
        *)
            error "Package signature is invalid or tampered: $package"
            return 1
            ;;
    esac
}

verify_package() {
    local lpk_file="${1:-}"
    [[ -f "$lpk_file" && -r "$lpk_file" && ! -L "$lpk_file" ]] || { error "Package not found or unreadable: $lpk_file"; return 1; }
    ensure_crypto_prerequisites || return 1
    local size
    size="$(_crypto_size "$lpk_file")" || return 1
    if [[ "$size" -le "$SIG_FOOTER_SIZE" ]] || ! has_sig_magic "$lpk_file"; then
        return 2
    fi

    local footer_offset=$((size - SIG_FOOTER_SIZE))
    local cache_home="${ULPM_CACHE_HOME:-${TMPDIR:-/tmp}}"
    local tmp_dir pub_raw_tmp sig_tmp pub_pem_tmp hash_tmp
    mkdir -p -- "$cache_home" || return 1
    tmp_dir="$(mktemp -d "$cache_home/verify_XXXXXX")" || return 1

    pub_raw_tmp="$tmp_dir/raw.bin"
    sig_tmp="$tmp_dir/sig.bin"
    pub_pem_tmp="$tmp_dir/pub.pem"
    hash_tmp="$tmp_dir/hash.bin"

    # Extract public key and signature based on trailer magic
    if cmp -s -n "$SIG_MAGIC_LEN" <(tail -c "$SIG_FOOTER_SIZE" -- "$lpk_file" 2>/dev/null) <(printf '%s' "$SIG_MAGIC"); then
        # Format 1 (Standard): ULPM_SIG (8) + Pub (32) + Sig (64)
        tail -c "$SIG_FOOTER_SIZE" -- "$lpk_file" | head -c "$((SIG_MAGIC_LEN + SIG_PUB_LEN))" | tail -c "$SIG_PUB_LEN" > "$pub_raw_tmp"
        tail -c "$SIG_RAW_LEN" -- "$lpk_file" > "$sig_tmp"
    else
        # Format 2 (Trailer legacy): Pub (32) + Sig (64) + LPK_SIG\0 (8)
        tail -c "$SIG_FOOTER_SIZE" -- "$lpk_file" | head -c "$SIG_PUB_LEN" > "$pub_raw_tmp"
        tail -c "$((SIG_RAW_LEN + SIG_MAGIC_LEN))" -- "$lpk_file" | head -c "$SIG_RAW_LEN" > "$sig_tmp"
    fi

    [[ "$(_crypto_size "$pub_raw_tmp")" -eq "$SIG_PUB_LEN" && "$(_crypto_size "$sig_tmp")" -eq "$SIG_RAW_LEN" ]] || {
        rm -rf -- "$tmp_dir"
        return 1
    }

    # Stream payload digest without copying huge files to /tmp
    if ! head -c "$footer_offset" -- "$lpk_file" | openssl dgst -sha256 -binary > "$hash_tmp"; then
        rm -rf -- "$tmp_dir"
        return 1
    fi

    # Reconstruct DER public key header
    printf '\x30\x2a\x30\x05\x06\x03\x2b\x65\x70\x03\x21\x00' > "$tmp_dir/pub.der"
    cat -- "$pub_raw_tmp" >> "$tmp_dir/pub.der" || { rm -rf -- "$tmp_dir"; return 1; }

    if ! openssl pkey -pubin -inform DER -in "$tmp_dir/pub.der" -pubout -out "$pub_pem_tmp" 2>/dev/null; then
        rm -rf -- "$tmp_dir"
        error "Invalid public key in package: $lpk_file"
        return 1
    fi

    # Verify binary hash (Streamed digest verification)
    local verified=0
    if openssl pkeyutl -verify -rawin -pubin -inkey "$pub_pem_tmp" -sigfile "$sig_tmp" -in "$hash_tmp" >/dev/null 2>&1; then
        verified=1
    elif head -c "$footer_offset" -- "$lpk_file" | openssl pkeyutl -verify -rawin -pubin -inkey "$pub_pem_tmp" -sigfile "$sig_tmp" >/dev/null 2>&1; then
        # Fallback for direct raw payload legacy packages
        verified=1
    fi

    if (( verified == 0 )); then
        error "Signature verification failed for $lpk_file (tampered payload or invalid signature)."
        rm -rf -- "$tmp_dir"
        return 1
    fi

    # Check key against trusted stores (v5.3 robust comparison)
    local trusted_dir trusted is_trusted=0 trusted_raw_tmp="$tmp_dir/trusted_raw.bin"
    trusted_dir="$(_crypto_trusted_dir)"
    local keys_dir
    keys_dir="$(_crypto_keys_dir)"
    shopt -s nullglob
    local trusted_keys=("$trusted_dir"/*.pub "$keys_dir"/*.pub)
    shopt -u nullglob
    for trusted in "${trusted_keys[@]}"; do
        [[ -f "$trusted" && -r "$trusted" && ! -L "$trusted" ]] || continue
        _crypto_is_ed25519_key "$trusted" public || continue
        if openssl pkey -pubin -in "$trusted" -outform DER 2>/dev/null | tail -c "$SIG_PUB_LEN" > "$trusted_raw_tmp" 2>/dev/null; then
            if [[ "$(_crypto_size "$trusted_raw_tmp")" -eq "$SIG_PUB_LEN" ]] && cmp -s "$pub_raw_tmp" "$trusted_raw_tmp"; then
                is_trusted=1
                break
            fi
        fi
    done

    rm -rf -- "$tmp_dir"
    [[ "$is_trusted" -eq 1 ]] && return 0
    return 3
}

# ==============================================================================
# Detached Signature Engine (Static Repositories Phase 2)
# ==============================================================================

crypto_sign_detached() {
    local target_file="${1:-}" priv_key="${2:-}" out_sig="${3:-}"
    [[ -f "$target_file" && -r "$target_file" ]] || return 1
    [[ -f "$priv_key" && -r "$priv_key" ]] || return 1
    [[ -n "$out_sig" ]] || return 1

    local tmp_sig
    tmp_sig="$(mktemp "${out_sig}.tmp.XXXXXX")" || return 1
    if ! openssl pkeyutl -sign -rawin -inkey "$priv_key" -in "$target_file" -out "$tmp_sig" 2>/dev/null; then
        rm -f -- "$tmp_sig"
        return 1
    fi
    sync_file "$tmp_sig" 2>/dev/null || true
    mv -f -- "$tmp_sig" "$out_sig" || { rm -f -- "$tmp_sig"; return 1; }
    sync_dir "$(dirname -- "$out_sig")" 2>/dev/null || true
}

crypto_verify_detached() {
    local target_file="${1:-}" sig_file="${2:-}" pub_key="${3:-}"
    [[ -f "$target_file" && -r "$target_file" ]] || return 1
    [[ -f "$sig_file" && -r "$sig_file" ]] || return 1
    [[ -f "$pub_key" && -r "$pub_key" ]] || return 1

    openssl pkeyutl -verify -rawin -pubin -inkey "$pub_key" -sigfile "$sig_file" -in "$target_file" >/dev/null 2>&1
}

cmd_trust() {
    local pub_key="${1:-}"
    [[ -n "$pub_key" && -f "$pub_key" && -r "$pub_key" && ! -L "$pub_key" ]] || { error "Usage: ulpm trust <key.pub>"; return 1; }
    ensure_crypto_prerequisites || return 1
    _crypto_is_ed25519_key "$pub_key" public || { error "Invalid or non-Ed25519 public key: $pub_key"; return 1; }

    local key_name dest tmp trusted_dir raw_size tmp_der_a tmp_der_b fp
    key_name="$(basename -- "$pub_key")"
    [[ "$key_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}\.pub$ ]] || { error "Unsafe public-key filename: $key_name"; return 1; }

    raw_size="$(openssl pkey -pubin -in "$pub_key" -outform DER 2>/dev/null | tail -c "$SIG_PUB_LEN" | wc -c | tr -d ' \t\n')"
    [[ "${raw_size:-0}" -eq "$SIG_PUB_LEN" ]] || { error "Only Ed25519 public keys are supported."; return 1; }

    trusted_dir="$(_crypto_trusted_dir)"
    (umask 077 && mkdir -p -- "$trusted_dir") || { error "Cannot create trust directory: $trusted_dir"; return 1; }
    chmod 700 "$trusted_dir" 2>/dev/null || true
    dest="$trusted_dir/$key_name"

    fp="$(crypto_fingerprint "$pub_key" 2>/dev/null || echo "unknown")"

    if [[ -e "$dest" ]]; then
        tmp_der_a="$(mktemp "${TMPDIR:-/tmp}/der_a.XXXXXX")" || return 1
        tmp_der_b="$(mktemp "${TMPDIR:-/tmp}/der_b.XXXXXX")" || { rm -f -- "$tmp_der_a"; return 1; }
        openssl pkey -pubin -in "$pub_key" -outform DER > "$tmp_der_a" 2>/dev/null || true
        openssl pkey -pubin -in "$dest" -outform DER > "$tmp_der_b" 2>/dev/null || true
        if cmp -s "$tmp_der_a" "$tmp_der_b"; then
            rm -f -- "$tmp_der_a" "$tmp_der_b"
            info "Key is already trusted: $dest (Fingerprint: $fp)"
            return 0
        fi
        rm -f -- "$tmp_der_a" "$tmp_der_b"
        error "A different key already occupies filename: $dest"
        return 1
    fi

    tmp="$(mktemp "$trusted_dir/.${key_name}.XXXXXX")" || return 1
    if ! cp -- "$pub_key" "$tmp"; then
        rm -f -- "$tmp"
        return 1
    fi
    chmod 644 -- "$tmp" || { rm -f -- "$tmp"; return 1; }
    sync_file "$tmp" 2>/dev/null || true
    if ! mv -f -- "$tmp" "$dest"; then
        rm -f -- "$tmp"
        error "Could not commit key to trust store."
        return 1
    fi
    sync_dir "$trusted_dir" 2>/dev/null || true
    info "Key registered and trusted: $dest"
    info "SHA-256 Fingerprint: $fp"
}
