#!/usr/bin/env bash
# ==============================================================================
# lib/crypto.sh - High-Integrity Ed25519 TOFU Verification & Signing Engine
# ==============================================================================

SIG_MAGIC="ULPM_SIG"
SIG_FOOTER_SIZE=104

# ------------------------------------------------------------------------------
# Dependency & Cryptographic Version Verification
# ------------------------------------------------------------------------------
ensure_crypto_prerequisites() {
    check_dependencies openssl cmp dd truncate tail head

    local ossl_ver
    ossl_ver="$(openssl version 2>/dev/null | awk '{print $2}')"
    if [[ "$ossl_ver" =~ ^0\. || "$ossl_ver" =~ ^1\.0 ]]; then
        error "OpenSSL >= 1.1.1 is strictly required for Ed25519 curves (Detected: ${ossl_ver:-unknown})."
        return 1
    fi
    return 0
}

# ------------------------------------------------------------------------------
# Key Generation
# ------------------------------------------------------------------------------
cmd_keygen() {
    local key_name="${1:-id_ed25519}"
    ensure_crypto_prerequisites || return 1

    local priv_path="$ULPM_KEYS_DIR/${key_name}.priv"
    local pub_path="$ULPM_KEYS_DIR/${key_name}.pub"

    if [[ -f "$priv_path" ]]; then
        error "Key file already exists: $priv_path"
        return 1
    fi

    mkdir -p "$ULPM_KEYS_DIR"

    log "Generating hardened Ed25519 keypair ($key_name)..."
    openssl genpkey -algorithm Ed25519 -out "$priv_path" 2>/dev/null
    chmod 600 "$priv_path"
    openssl pkey -in "$priv_path" -pubout -out "$pub_path" 2>/dev/null

    info "Private key generated: $priv_path"
    info "Public key generated:  $pub_path"
}

# Alias to match the dispatcher in bin/ulpm
generate_keypair() { cmd_keygen "$@"; }

# ------------------------------------------------------------------------------
# Signature Helpers (Subshell & Null-Byte Safe)
# ------------------------------------------------------------------------------
has_sig_magic() {
    local file="$1"
    local magic_check
    magic_check="$(tail -c "$SIG_FOOTER_SIZE" "$file" 2>/dev/null | head -c 8 | tr -d '\0')"
    [ "$magic_check" = "$SIG_MAGIC" ]
}

strip_signature() {
    local file="$1"
    local size
    size=$(stat -c%s "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null || echo 0)

    if [ "$size" -gt "$SIG_FOOTER_SIZE" ]; then
        if has_sig_magic "$file"; then
            local offset=$((size - SIG_FOOTER_SIZE))
            truncate -s "$offset" "$file"
        fi
    fi
}

# ------------------------------------------------------------------------------
# Package Signing (Payload + MAGIC[8] + PUBKEY[32] + SIG[64])
# ------------------------------------------------------------------------------
cmd_sign() {
    local lpk_file="${1:-}"
    local priv_key="${2:-}"

    if [[ -z "$lpk_file" || -z "$priv_key" ]]; then
        error "Usage: ulpm sign <package.lpk> <private_key.priv>"
        return 1
    fi

    [[ ! -f "$lpk_file" ]] && { error "Target package not found: $lpk_file"; return 1; }
    [[ ! -f "$priv_key" ]] && { error "Private key not found: $priv_key"; return 1; }

    ensure_crypto_prerequisites || return 1

    # Remove any pre-existing signature before sealing the payload
    strip_signature "$lpk_file"

    local sig_tmp pub_raw_tmp
    sig_tmp="$(mktemp "${ULPM_CACHE_HOME:-/tmp}/sig_XXXXXX.bin")"
    pub_raw_tmp="$(mktemp "${ULPM_CACHE_HOME:-/tmp}/pub_XXXXXX.bin")"

    # Extract the 32 raw bytes of the Ed25519 public key (DER tail)
    openssl pkey -in "$priv_key" -pubout -outform DER 2>/dev/null | tail -c 32 > "$pub_raw_tmp"

    # Compute Ed25519 signature over package payload
    openssl dgst -sha512 -sign "$priv_key" -out "$sig_tmp" "$lpk_file" 2>/dev/null

    # Append cryptographic footer: MAGIC (8) + PUB_RAW (32) + SIG (64) = 104 bytes
    {
        printf "%s" "$SIG_MAGIC"
        cat "$pub_raw_tmp"
        cat "$sig_tmp"
    } >> "$lpk_file"

    rm -f "$sig_tmp" "$pub_raw_tmp"
    info "Package signed and sealed successfully: $lpk_file"
}

# Alias to match the dispatcher in bin/ulpm
sign_package() { cmd_sign "$@"; }

# ------------------------------------------------------------------------------
# Package Verification (TOFU Keystore + Cryptographic Integrity)
# ------------------------------------------------------------------------------
verify_package() {
    local lpk_file="$1"
    ensure_crypto_prerequisites || return 1

    local size
    size=$(stat -c%s "$lpk_file" 2>/dev/null || stat -f%z "$lpk_file" 2>/dev/null || echo 0)

    if [ "$size" -le "$SIG_FOOTER_SIZE" ]; then
        warn "Package $lpk_file is too small to contain a cryptographic footer."
        return 1
    fi

    if ! has_sig_magic "$lpk_file"; then
        warn "No ULPM cryptographic signature detected in $lpk_file."
        return 2
    fi

    local footer_offset=$((size - SIG_FOOTER_SIZE))
    local pub_raw_tmp sig_tmp pub_pem_tmp
    pub_raw_tmp="$(mktemp "${ULPM_CACHE_HOME:-/tmp}/raw_XXXXXX.bin")"
    sig_tmp="$(mktemp "${ULPM_CACHE_HOME:-/tmp}/sig_XXXXXX.bin")"
    pub_pem_tmp="$(mktemp "${ULPM_CACHE_HOME:-/tmp}/pem_XXXXXX.bin")"

    # Direct byte extraction without Bash string subshell expansion
    tail -c "$SIG_FOOTER_SIZE" "$lpk_file" | head -c 40 | tail -c 32 > "$pub_raw_tmp"
    tail -c 64 "$lpk_file" > "$sig_tmp"

    # Reconstruct PEM public key safely:
    # DER Ed25519 Prefix (12 bytes) + 32 raw bytes -> PEM conversion
    printf '%b' '\x30\x2a\x30\x05\x06\x03\x2b\x65\x70\x03\x21\x00' > "$pub_pem_tmp.der"
    cat "$pub_raw_tmp" >> "$pub_pem_tmp.der"
    openssl pkey -pubin -inform DER -in "$pub_pem_tmp.der" -pubout -out "$pub_pem_tmp" 2>/dev/null
    rm -f "$pub_pem_tmp.der"

    # Cryptographic verification of payload (entire archive minus the 104-byte footer)
    local verified=0
    head -c "$footer_offset" "$lpk_file" | openssl dgst -sha512 -verify "$pub_pem_tmp" -signature "$sig_tmp" >/dev/null 2>&1 && verified=1

    if [ "$verified" -ne 1 ]; then
        rm -f "$pub_raw_tmp" "$sig_tmp" "$pub_pem_tmp"
        error "CRYPTOGRAPHIC SIGNATURE FORGERY DETECTED: Verification FAILED for $lpk_file!"
        return 1
    fi

    # TOFU verification (Trust On First Use / Keystore check)
    local is_trusted=0
    shopt -s nullglob
    local trusted_keys=("$ULPM_KEYS_DIR"/*.pub)
    shopt -u nullglob

    for trusted in "${trusted_keys[@]}"; do
        if cmp -s "$pub_pem_tmp" "$trusted" 2>/dev/null; then
            is_trusted=1
            break
        fi
    done

    rm -f "$pub_raw_tmp" "$sig_tmp" "$pub_pem_tmp"

    if [ "$is_trusted" -eq 1 ]; then
        info "Valid signature from trusted author."
        return 0
    else
        warn "Package signature is mathematically valid, but author key is NOT in your trusted keystore ($ULPM_KEYS_DIR)."
        return 3
    fi
}

# ------------------------------------------------------------------------------
# Keystore Trust Authority
# ------------------------------------------------------------------------------
cmd_trust() {
    local pub_key="${1:-}"
    if [[ -z "$pub_key" || ! -f "$pub_key" ]]; then
        error "Usage: ulpm trust <public_key.pub>"
        return 1
    fi

    mkdir -p "$ULPM_KEYS_DIR"
    local dest
    dest="$ULPM_KEYS_DIR/$(basename "$pub_key")"
    cp "$pub_key" "$dest"
    info "Public key successfully added to trusted authority store: $dest"
}

# Alias to match the dispatcher in bin/ulpm
trust_key() { cmd_trust "$@"; }
