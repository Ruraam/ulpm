#!/usr/bin/env bash
# ==============================================================================
# lib/crypto.sh - High-Integrity Ed25519 Signing & Verification Engine
# ==============================================================================

SIG_MAGIC="ULPM_SIG"
SIG_MAGIC_LEN=8
SIG_RAW_LEN=64
SIG_PUB_LEN=32
SIG_FOOTER_SIZE=104

ensure_crypto_prerequisites() {
    check_dependencies openssl cmp dd truncate tail head
    local ossl_ver
    ossl_ver="$(openssl version 2>/dev/null | awk '{print $2}')"
    if [[ "$ossl_ver" =~ ^0\. || "$ossl_ver" =~ ^1\.0 ]]; then
        error "OpenSSL >= 1.1.1 is strictly required for Ed25519 (Detected: ${ossl_ver:-unknown})."
        return 1
    fi
    return 0
}

ensure_default_keypair() {
    local default_priv="$ULPM_KEYS_DIR/default.priv"
    local default_pub="$ULPM_KEYS_DIR/default.pub"

    if [[ -f "$default_priv" && -f "$default_pub" ]]; then
        echo "$default_priv"
        return 0
    fi

    mkdir -p "$ULPM_KEYS_DIR"
    ensure_crypto_prerequisites || return 1
    openssl genpkey -algorithm Ed25519 -out "$default_priv" 2>/dev/null
    chmod 600 "$default_priv"
    openssl pkey -in "$default_priv" -pubout -out "$default_pub" 2>/dev/null
    echo "$default_priv"
}

cmd_keygen() {
    local key_name="${1:-default}"
    ensure_crypto_prerequisites || return 1

    local priv_path="$ULPM_KEYS_DIR/${key_name}.priv"
    local pub_path="$ULPM_KEYS_DIR/${key_name}.pub"

    if [[ -f "$priv_path" ]]; then
        warn "Key file already exists: $priv_path"
        return 0
    fi

    mkdir -p "$ULPM_KEYS_DIR"
    log "Generating hardened Ed25519 keypair ($key_name)..."
    openssl genpkey -algorithm Ed25519 -out "$priv_path" 2>/dev/null
    chmod 600 "$priv_path"
    openssl pkey -in "$priv_path" -pubout -out "$pub_path" 2>/dev/null

    info "Private key generated: $priv_path"
    info "Public key generated:  $pub_path"
}

has_sig_magic() {
    local file="$1"
    local magic_check
    magic_check="$(tail -c "$SIG_FOOTER_SIZE" "$file" 2>/dev/null | head -c "$SIG_MAGIC_LEN" | tr -d '\0')"
    [[ "$magic_check" == "$SIG_MAGIC" ]]
}

strip_signature() {
    local file="$1"
    local size
    size=$(stat -c%s "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null || echo 0)
    if [[ "$size" -gt "$SIG_FOOTER_SIZE" ]] && has_sig_magic "$file"; then
        truncate -s -"$SIG_FOOTER_SIZE" "$file"
    fi
}

cmd_sign() {
    local lpk_file="${1:-}"
    local priv_key="${2:-}"

    [[ -z "$lpk_file" ]] && { error "Usage: ulpm sign <package.lpk> [priv_key]"; return 1; }
    [[ -z "$priv_key" ]] && priv_key="$(ensure_default_keypair)"
    [[ ! -f "$lpk_file" ]] && { error "Package not found: $lpk_file"; return 1; }
    [[ ! -f "$priv_key" ]] && { error "Private key not found: $priv_key"; return 1; }

    ensure_crypto_prerequisites || return 1
    strip_signature "$lpk_file"

    local sig_tmp pub_raw_tmp
    sig_tmp="$(mktemp "${ULPM_CACHE_HOME:-/tmp}/sig_XXXXXX.bin")"
    pub_raw_tmp="$(mktemp "${ULPM_CACHE_HOME:-/tmp}/pub_XXXXXX.bin")"

    openssl pkey -in "$priv_key" -pubout -outform DER 2>/dev/null | tail -c "$SIG_PUB_LEN" > "$pub_raw_tmp"
    openssl dgst -sha512 -sign "$priv_key" -out "$sig_tmp" "$lpk_file" 2>/dev/null

    {
        printf "%s" "$SIG_MAGIC"
        cat "$pub_raw_tmp"
        cat "$sig_tmp"
    } >> "$lpk_file"

    rm -f "$sig_tmp" "$pub_raw_tmp"
    info "Package sealed successfully: $(basename "$lpk_file")"
}

verify_package() {
    local lpk_file="$1"
    ensure_crypto_prerequisites || return 1

    local size
    size=$(stat -c%s "$lpk_file" 2>/dev/null || stat -f%z "$lpk_file" 2>/dev/null || echo 0)

    if [[ "$size" -le "$SIG_FOOTER_SIZE" ]] || ! has_sig_magic "$lpk_file"; then
        return 2
    fi

    local footer_offset=$((size - SIG_FOOTER_SIZE))
    local pub_raw_tmp sig_tmp pub_pem_tmp
    pub_raw_tmp="$(mktemp "${ULPM_CACHE_HOME:-/tmp}/raw_XXXXXX.bin")"
    sig_tmp="$(mktemp "${ULPM_CACHE_HOME:-/tmp}/sig_XXXXXX.bin")"
    pub_pem_tmp="$(mktemp "${ULPM_CACHE_HOME:-/tmp}/pem_XXXXXX.bin")"

    tail -c "$SIG_FOOTER_SIZE" "$lpk_file" | head -c $((SIG_MAGIC_LEN + SIG_PUB_LEN)) | tail -c "$SIG_PUB_LEN" > "$pub_raw_tmp"
    tail -c "$SIG_RAW_LEN" "$lpk_file" > "$sig_tmp"

    printf '%b' '\x30\x2a\x30\x05\x06\x03\x2b\x65\x70\x03\x21\x00' > "$pub_pem_tmp.der"
    cat "$pub_raw_tmp" >> "$pub_pem_tmp.der"
    openssl pkey -pubin -inform DER -in "$pub_pem_tmp.der" -pubout -out "$pub_pem_tmp" 2>/dev/null
    rm -f "$pub_pem_tmp.der"

    local verified=0
    head -c "$footer_offset" "$lpk_file" | openssl dgst -sha512 -verify "$pub_pem_tmp" -signature "$sig_tmp" >/dev/null 2>&1 && verified=1

    if [[ "$verified" -ne 1 ]]; then
        rm -f "$pub_raw_tmp" "$sig_tmp" "$pub_pem_tmp"
        error "CRYPTOGRAPHIC FORGERY: Verification failed for $lpk_file!"
        return 1
    fi

    shopt -s nullglob
    local trusted_keys=("$ULPM_KEYS_DIR"/*.pub)
    shopt -u nullglob

    local is_trusted=0
    for trusted in "${trusted_keys[@]}"; do
        if cmp -s "$pub_pem_tmp" "$trusted" 2>/dev/null; then
            is_trusted=1
            break
        fi
    done

    rm -f "$pub_raw_tmp" "$sig_tmp" "$pub_pem_tmp"
    [[ "$is_trusted" -eq 1 ]] && return 0 || return 3
}

cmd_trust() {
    local pub_key="${1:-}"
    [[ -z "$pub_key" || ! -f "$pub_key" ]] && { error "Usage: ulpm trust <key.pub>"; return 1; }
    mkdir -p "$ULPM_KEYS_DIR"
    cp -f "$pub_key" "$ULPM_KEYS_DIR/$(basename "$pub_key")"
    info "Key trusted: $pub_key"
}
