#!/usr/bin/env bash
# ============================================================================
# lib/crypto.sh - ULPM Ed25519 signing, verification and trust management
# Signature footer (104 bytes): ULPM_SIG (8) + raw public key (32) + signature (64)
# ULPM v4.1.0 (Streamed SHA256 -> Ed25519, Large-File safe, NO xxd dependency)
# ============================================================================

SIG_MAGIC="ULPM_SIG"
SIG_MAGIC_LEN=8
SIG_RAW_LEN=64
SIG_PUB_LEN=32
SIG_FOOTER_SIZE=104

_crypto_size() {
    stat -c '%s' -- "$1" 2>/dev/null || stat -f '%z' -- "$1" 2>/dev/null
}

_crypto_trusted_dir() {
    printf '%s\n' "${ULPM_CONFIG_HOME:-$HOME/.config/ulpm}/trusted_keys"
}

ensure_crypto_prerequisites() {
    check_dependencies openssl cmp dd truncate tail head stat mktemp cp mv chmod mkdir rm cat dirname basename wc grep od tr || return 1

    if ! openssl genpkey -algorithm Ed25519 -help >/dev/null 2>&1 && \
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

_crypto_is_ed25519_key() {
    local key="${1:-}" kind="${2:-private}" der_tmp prefix size
    [[ -f "$key" && -r "$key" && ! -L "$key" ]] || return 1
    der_tmp="$(mktemp "${TMPDIR:-/tmp}/ulpm-keycheck.XXXXXX")" || return 1
    if [[ "$kind" == "public" ]]; then
        openssl pkey -pubin -in "$key" -pubout -outform DER -out "$der_tmp" 2>/dev/null || { rm -f -- "$der_tmp"; return 1; }
    else
        openssl pkey -in "$key" -pubout -outform DER -out "$der_tmp" 2>/dev/null || { rm -f -- "$der_tmp"; return 1; }
    fi
    size="$(_crypto_size "$der_tmp")" || { rm -f -- "$der_tmp"; return 1; }
    prefix="$(head -c 12 -- "$der_tmp" | od -An -tx1 | tr -d ' \n')"
    rm -f -- "$der_tmp"
    [[ "$size" -eq 44 && "$prefix" == "302a300506032b6570032100" ]]
}

_crypto_valid_key_name() {
    [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ && "$1" != "." && "$1" != ".." ]]
}

ensure_default_keypair() {
    local key_dir="${ULPM_KEYS_DIR:-$HOME/.config/ulpm/keys}"
    local default_priv="$key_dir/default.priv"
    local default_pub="$key_dir/default.pub"
    local tmp_priv="" tmp_pub=""

    if [[ -f "$default_priv" && -f "$default_pub" && ! -L "$default_priv" && ! -L "$default_pub" ]]; then
        printf '%s\n' "$default_priv"
        return 0
    fi
    if [[ -e "$default_priv" || -e "$default_pub" ]]; then
        error "Incomplete default keypair exists; refusing to overwrite it."
        return 1
    fi

    ( umask 077 && mkdir -p -- "$key_dir" ) || { error "Cannot create key directory: $key_dir"; return 1; }
    ensure_crypto_prerequisites || return 1

    tmp_priv="$(mktemp "$key_dir/.default.priv.XXXXXX")" || return 1
    tmp_pub="$(mktemp "$key_dir/.default.pub.XXXXXX")" || { rm -f -- "$tmp_priv"; return 1; }
    if ! (umask 077; openssl genpkey -algorithm Ed25519 -out "$tmp_priv") 2>/dev/null || \
       ! openssl pkey -in "$tmp_priv" -pubout -out "$tmp_pub" 2>/dev/null; then
        rm -f -- "$tmp_priv" "$tmp_pub"
        error "Failed to generate the default Ed25519 keypair."
        return 1
    fi
    chmod 600 -- "$tmp_priv" || { rm -f -- "$tmp_priv" "$tmp_pub"; return 1; }
    chmod 644 -- "$tmp_pub" || { rm -f -- "$tmp_priv" "$tmp_pub"; return 1; }

    if [[ -e "$default_priv" || -e "$default_pub" ]]; then
        rm -f -- "$tmp_priv" "$tmp_pub"
        error "Default key appeared during generation; aborting."
        return 1
    fi

    mv -f -- "$tmp_priv" "$default_priv" || { rm -f -- "$tmp_priv" "$tmp_pub"; return 1; }
    mv -f -- "$tmp_pub" "$default_pub" || { rm -f -- "$tmp_pub"; return 1; }

    cmd_trust "$default_pub" >/dev/null 2>&1 || true

    printf '%s\n' "$default_priv"
}

cmd_keygen() {
    local key_name="${1:-default}"
    _crypto_valid_key_name "$key_name" || { error "Invalid key name: use 1-64 letters, digits, dots, underscores or hyphens."; return 1; }
    ensure_crypto_prerequisites || return 1

    local key_dir="${ULPM_KEYS_DIR:-$HOME/.config/ulpm/keys}"
    local priv_path="$key_dir/${key_name}.priv"
    local pub_path="$key_dir/${key_name}.pub"
    local tmp_priv="" tmp_pub=""

    if [[ -e "$priv_path" || -e "$pub_path" ]]; then
        error "Key file already exists: $priv_path or $pub_path"
        return 1
    fi
    ( umask 077 && mkdir -p -- "$key_dir" ) || { error "Cannot create key directory: $key_dir"; return 1; }
    log "Generating Ed25519 keypair ($key_name)..."

    tmp_priv="$(mktemp "$key_dir/.${key_name}.priv.XXXXXX")" || return 1
    tmp_pub="$(mktemp "$key_dir/.${key_name}.pub.XXXXXX")" || { rm -f -- "$tmp_priv"; return 1; }
    if ! (umask 077; openssl genpkey -algorithm Ed25519 -out "$tmp_priv") 2>/dev/null || \
       ! openssl pkey -in "$tmp_priv" -pubout -out "$tmp_pub" 2>/dev/null; then
        rm -f -- "$tmp_priv" "$tmp_pub"
        error "Key generation failed."
        return 1
    fi
    if ! chmod 600 -- "$tmp_priv" || ! chmod 644 -- "$tmp_pub"; then
        rm -f -- "$tmp_priv" "$tmp_pub"
        return 1
    fi

    if [[ -e "$priv_path" || -e "$pub_path" ]]; then
        rm -f -- "$tmp_priv" "$tmp_pub"
        error "Key destination appeared during generation; refusing to overwrite it."
        return 1
    fi

    mv -f -- "$tmp_priv" "$priv_path" || { rm -f -- "$tmp_priv" "$tmp_pub"; return 1; }
    mv -f -- "$tmp_pub" "$pub_path" || { rm -f -- "$tmp_pub"; return 1; }

    cmd_trust "$pub_path" >/dev/null 2>&1 || true

    info "Private key generated: $priv_path"
    info "Public key generated: $pub_path (Trusted)"
}

has_sig_magic() {
    local file="${1:-}" size
    [[ -f "$file" && -r "$file" ]] || return 1
    size="$(_crypto_size "$file")" || return 1
    [[ "$size" =~ ^[0-9]+$ && "$size" -ge "$SIG_FOOTER_SIZE" ]] || return 1

    cmp -s -n "$SIG_MAGIC_LEN" \
        <(tail -c "$SIG_FOOTER_SIZE" -- "$file" 2>/dev/null) \
        <(printf '%s' "$SIG_MAGIC")
}

strip_signature() {
    local file="${1:-}" size
    [[ -f "$file" && -w "$file" && ! -L "$file" ]] || return 1
    size="$(_crypto_size "$file")" || return 1
    if [[ "$size" -ge "$SIG_FOOTER_SIZE" ]] && has_sig_magic "$file"; then
        truncate -s "$((size - SIG_FOOTER_SIZE))" -- "$file"
    fi
}

cmd_sign() {
    local lpk_file="${1:-}" priv_key="${2:-}"
    [[ -n "$lpk_file" ]] || { error "Usage: ulpm sign <package.lpk> [priv_key]"; return 1; }
    [[ -f "$lpk_file" && -r "$lpk_file" && -w "$lpk_file" && ! -L "$lpk_file" ]] || {
        error "Package must be a readable, writable regular file (not a symlink): $lpk_file"; return 1
    }
    if [[ -z "$priv_key" ]]; then
        priv_key="$(ensure_default_keypair)" || return 1
    fi
    [[ -f "$priv_key" && -r "$priv_key" && ! -L "$priv_key" ]] || { error "Private key not found or unreadable: $priv_key"; return 1; }
    ensure_crypto_prerequisites || return 1
    _crypto_is_ed25519_key "$priv_key" private || { error "Invalid or non-Ed25519 private key: $priv_key"; return 1; }

    local base tmp_dir sig_tmp pub_raw_tmp hash_tmp size payload_size
    base="$(basename -- "$lpk_file")"
    tmp_dir="$(mktemp -d "${ULPM_CACHE_HOME:-${TMPDIR:-/tmp}}/sign_XXXXXX")" || return 1
    sig_tmp="$tmp_dir/sig.bin"
    pub_raw_tmp="$tmp_dir/pub_raw.bin"
    hash_tmp="$tmp_dir/hash.bin"

    # Remove existing signature in-place
    strip_signature "$lpk_file"
    size="$(_crypto_size "$lpk_file")" || { rm -rf -- "$tmp_dir"; return 1; }
    payload_size="$size"

    # Extract 32-byte raw public key
    if ! openssl pkey -in "$priv_key" -pubout -outform DER 2>/dev/null | tail -c "$SIG_PUB_LEN" > "$pub_raw_tmp" || \
       [[ "$(_crypto_size "$pub_raw_tmp")" -ne "$SIG_PUB_LEN" ]]; then
        error "Could not derive a valid Ed25519 public key from $priv_key."
        rm -rf -- "$tmp_dir"
        return 1
    fi

    log "Hashing payload ($payload_size bytes)..."
    # Native binary hashing via openssl (no external tool like xxd needed)
    if ! openssl dgst -sha256 -binary < "$lpk_file" > "$hash_tmp"; then
        error "Failed to compute package hash."
        rm -rf -- "$tmp_dir"
        return 1
    fi

    # Sign the 32-byte binary digest
    if ! openssl pkeyutl -sign -rawin -inkey "$priv_key" -in "$hash_tmp" -out "$sig_tmp" 2>/dev/null || \
       [[ "$(_crypto_size "$sig_tmp")" -ne "$SIG_RAW_LEN" ]]; then
        error "Ed25519 signing failed."
        rm -rf -- "$tmp_dir"
        return 1
    fi

    # Append directly
    {
        printf '%s' "$SIG_MAGIC"
        cat -- "$pub_raw_tmp" "$sig_tmp"
    } >> "$lpk_file" || { rm -rf -- "$tmp_dir"; return 1; }

    rm -rf -- "$tmp_dir"
    info "Package sealed successfully: $base"
}

verify_package() {
    local lpk_file="${1:-}"
    [[ -f "$lpk_file" && -r "$lpk_file" && ! -L "$lpk_file" ]] || { error "Package not found, unreadable, or is a symlink: $lpk_file"; return 1; }
    ensure_crypto_prerequisites || return 1
    local size
    size="$(_crypto_size "$lpk_file")" || return 1
    if [[ "$size" -le "$SIG_FOOTER_SIZE" ]] || ! has_sig_magic "$lpk_file"; then
        return 2
    fi

    local footer_offset=$((size - SIG_FOOTER_SIZE)) tmp_dir pub_raw_tmp sig_tmp pub_pem_tmp hash_tmp
    tmp_dir="$(mktemp -d "${ULPM_CACHE_HOME:-${TMPDIR:-/tmp}}/verify_XXXXXX")" || return 1
    pub_raw_tmp="$tmp_dir/raw.bin"
    sig_tmp="$tmp_dir/sig.bin"
    pub_pem_tmp="$tmp_dir/pub.pem"
    hash_tmp="$tmp_dir/hash.bin"

    if ! tail -c "$SIG_FOOTER_SIZE" -- "$lpk_file" | head -c "$((SIG_MAGIC_LEN + SIG_PUB_LEN))" | tail -c "$SIG_PUB_LEN" > "$pub_raw_tmp" || \
       ! tail -c "$SIG_RAW_LEN" -- "$lpk_file" > "$sig_tmp"; then
        rm -rf -- "$tmp_dir"
        return 1
    fi
    [[ "$(_crypto_size "$pub_raw_tmp")" -eq "$SIG_PUB_LEN" && "$(_crypto_size "$sig_tmp")" -eq "$SIG_RAW_LEN" ]] || { rm -rf -- "$tmp_dir"; return 1; }

    cmp -s -n "$SIG_MAGIC_LEN" \
        <(tail -c "$SIG_FOOTER_SIZE" -- "$lpk_file" 2>/dev/null) \
        <(printf '%s' "$SIG_MAGIC") || { rm -rf -- "$tmp_dir"; return 2; }

    # Stream hash of payload without xxd
    if ! head -c "$footer_offset" -- "$lpk_file" | openssl dgst -sha256 -binary > "$hash_tmp"; then
        rm -rf -- "$tmp_dir"
        return 1
    fi

    printf '%b' '\x30\x2a\x30\x05\x06\x03\x2b\x65\x70\x03\x21\x00' > "$tmp_dir/pub.der"
    cat -- "$pub_raw_tmp" >> "$tmp_dir/pub.der"
    if ! openssl pkey -pubin -inform DER -in "$tmp_dir/pub.der" -pubout -out "$pub_pem_tmp" 2>/dev/null; then
        error "Invalid public key embedded in package: $lpk_file"
        rm -rf -- "$tmp_dir"
        return 1
    fi

    # Verify the hash
    if ! openssl pkeyutl -verify -rawin -pubin -inkey "$pub_pem_tmp" -sigfile "$sig_tmp" -in "$hash_tmp" >/dev/null 2>&1; then
        # Backward compatibility for old small packages (direct raw)
        if ! head -c "$footer_offset" -- "$lpk_file" | openssl pkeyutl -verify -rawin -pubin -inkey "$pub_pem_tmp" -sigfile "$sig_tmp" >/dev/null 2>&1; then
            error "Signature verification failed for $lpk_file."
            rm -rf -- "$tmp_dir"
            return 1
        fi
    fi

    local trusted_dir trusted is_trusted=0
    trusted_dir="$(_crypto_trusted_dir)"
    local keys_dir="${ULPM_KEYS_DIR:-$HOME/.config/ulpm/keys}"
    shopt -s nullglob
    local trusted_keys=("$trusted_dir"/*.pub "$keys_dir"/*.pub)
    shopt -u nullglob
    for trusted in "${trusted_keys[@]}"; do
        [[ -f "$trusted" && -r "$trusted" && ! -L "$trusted" ]] || continue
        _crypto_is_ed25519_key "$trusted" public || continue
        if cmp -s "$pub_raw_tmp" <(openssl pkey -pubin -in "$trusted" -outform DER 2>/dev/null | tail -c "$SIG_PUB_LEN"); then
            is_trusted=1
            break
        fi
    done
    rm -rf -- "$tmp_dir"
    [[ "$is_trusted" -eq 1 ]] && return 0
    return 3
}

cmd_trust() {
    local pub_key="${1:-}"
    [[ -n "$pub_key" && -f "$pub_key" && -r "$pub_key" && ! -L "$pub_key" ]] || { error "Usage: ulpm trust <key.pub>"; return 1; }
    ensure_crypto_prerequisites || return 1
    _crypto_is_ed25519_key "$pub_key" public || { error "Invalid or non-Ed25519 public key: $pub_key"; return 1; }

    local key_name dest tmp trusted_dir raw_size
    key_name="$(basename -- "$pub_key")"
    [[ "$key_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}\.pub$ ]] || { error "Unsafe public-key filename: $key_name"; return 1; }
    raw_size="$(openssl pkey -pubin -in "$pub_key" -outform DER 2>/dev/null | tail -c "$SIG_PUB_LEN" | wc -c)"
    [[ "$raw_size" -eq "$SIG_PUB_LEN" ]] || { error "Only Ed25519 public keys are supported."; return 1; }

    trusted_dir="$(_crypto_trusted_dir)"
    ( umask 077 && mkdir -p -- "$trusted_dir" ) || { error "Cannot create trust directory: $trusted_dir"; return 1; }
    dest="$trusted_dir/$key_name"
    if [[ -e "$dest" ]]; then
        if cmp -s <(openssl pkey -pubin -in "$pub_key" -outform DER 2>/dev/null) \
                  <(openssl pkey -pubin -in "$dest" -outform DER 2>/dev/null); then
            info "Key is already trusted: $dest"
            return 0
        fi
        error "A different trusted key already uses this filename: $dest"
        return 1
    fi
    tmp="$(mktemp "$trusted_dir/.${key_name}.XXXXXX")" || return 1
    if ! cp -- "$pub_key" "$tmp"; then
        rm -f -- "$tmp"
        return 1
    fi
    chmod 644 -- "$tmp" || { rm -f -- "$tmp"; return 1; }
    if ! mv -f -- "$tmp" "$dest"; then
        rm -f -- "$tmp"
        error "Could not add key to trust store."
        return 1
    fi
    info "Key trusted: $dest"
}
