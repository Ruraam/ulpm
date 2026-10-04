#!/usr/bin/env bash
# crypto.sh - Ed25519 signature, verification, key management

ensure_default_key() {
  [[ -f "$DEFAULT_KEY" ]] && return 0
  require_openssl3 || return 1

  echo -e "${CYAN}-> Generating default Ed25519 keypair...${NC}"
  local pub_key="${DEFAULT_KEY%.key}.pub"
  mkdir -p "$CONF_DIR"

  if ! (umask 077; openssl genpkey -algorithm ed25519 -out "$DEFAULT_KEY" 2>/dev/null); then
    echo -e "${RED}[-] Failed to generate private key${NC}" >&2
    return 1
  fi
  chmod 600 "$DEFAULT_KEY"

  if ! openssl pkey -in "$DEFAULT_KEY" -pubout -out "$pub_key" 2>/dev/null; then
    echo -e "${RED}[-] Failed to derive public key${NC}" >&2
    rm -f "$DEFAULT_KEY" "$pub_key"
    return 1
  fi

  cp -f "$pub_key" "$TRUSTED_KEYS_DIR/default.pub"
  echo -e "${GREEN}✔ Default key created and trusted${NC}"
}

cmd_keygen() {
  local key_name="${1:-ulpm_ed25519}"
  [[ "$key_name" =~ ^[A-Za-z0-9._-]+$ ]] || {
    echo -e "${RED}[-] Invalid key name${NC}" >&2
    return 1
  }
  local priv_key="$CONF_DIR/${key_name}.key"
  local pub_key="$CONF_DIR/${key_name}.pub"

  require_openssl3 || return 1
  mkdir -p "$CONF_DIR" "$TRUSTED_KEYS_DIR"

  if [[ -f "$priv_key" ]]; then
    echo -e "${YELLOW}[!] Key already exists. Overwrite? (y/N)${NC}"
    read -r reply || reply="n"
    [[ ! "$reply" =~ ^[yYoO]$ ]] && return 0
  fi

  echo -e "${CYAN}-> Generating Ed25519 keypair: $key_name${NC}"
  rm -f "$priv_key"
  (umask 077; openssl genpkey -algorithm ed25519 -out "$priv_key" 2>/dev/null) || return 1
  chmod 600 "$priv_key"
  openssl pkey -in "$priv_key" -pubout -out "$pub_key" 2>/dev/null || return 1
  cp -f "$pub_key" "$TRUSTED_KEYS_DIR/${key_name}.pub"
  echo -e "${GREEN}✔ Key created and trusted: ${BOLD}$pub_key${NC}"
}

cmd_sign() {
  local pkg_path="${1:-}"
  local priv_key="${2:-$DEFAULT_KEY}"

  if [[ -z "$pkg_path" || ! -f "$pkg_path" ]]; then
    echo -e "${RED}[-] Specify a valid .lpk file to sign${NC}" >&2
    return 1
  fi
  if [[ ! -f "$priv_key" ]]; then
    echo -e "${RED}[-] Private key not found: $priv_key${NC}" >&2
    return 1
  fi
  require_openssl3 || return 1

  local file_size
  file_size=$(wc -c < "$pkg_path")
  if [[ "$file_size" -ge $SIG_FOOTER_TOTAL ]] && has_sig_footer "$pkg_path"; then
    echo -e "${YELLOW}[!] Stripping old signature footer...${NC}"
    truncate -s "-$SIG_FOOTER_TOTAL" "$pkg_path"
  fi

  local pub_raw="$TEMP_DIR/pub_raw.bin"
  local sig_raw="$TEMP_DIR/sig_raw.bin"

  openssl pkey -in "$priv_key" -pubout -outform DER 2>/dev/null | tail -c "$SIG_PUB_LEN" > "$pub_raw"

  if ! openssl pkeyutl -sign -rawin -inkey "$priv_key" -in "$pkg_path" -out "$sig_raw" 2>/dev/null; then
    echo -e "${RED}[-] Ed25519 signing failed${NC}" >&2
    return 1
  fi

  if [[ "$(wc -c < "$sig_raw")" -ne $SIG_RAW_LEN || "$(wc -c < "$pub_raw")" -ne $SIG_PUB_LEN ]]; then
    echo -e "${RED}[-] Unexpected signature / key size, aborting${NC}" >&2
    rm -f "$pub_raw" "$sig_raw"
    return 1
  fi

  cat "$sig_raw" "$pub_raw" > "$TEMP_DIR/footer.bin"
  printf "%s" "$SIG_MAGIC" >> "$TEMP_DIR/footer.bin"
  cat "$TEMP_DIR/footer.bin" >> "$pkg_path"
  rm -f "$TEMP_DIR/footer.bin" "$pub_raw" "$sig_raw"

  echo -e "${GREEN}✔ Package signed (embedded footer)${NC}"
}

cmd_trust() {
  local pub_key="${1:-}"
  if [[ -z "$pub_key" || ! -f "$pub_key" ]]; then
    echo -e "${RED}[-] Provide a valid .pub file${NC}" >&2
    return 1
  fi
  require_openssl3 || return 1
  if ! openssl pkey -pubin -in "$pub_key" -noout 2>/dev/null; then
    echo -e "${RED}[-] Not a valid PEM public key: $pub_key${NC}" >&2
    return 1
  fi
  cp -f "$pub_key" "$TRUSTED_KEYS_DIR/$(basename "$pub_key")"
  echo -e "${GREEN}✔ Key added to trusted keyring${NC}"
}

verify_package_signature() {
local pkg="$1"
LAST_SIG_FPR=""

if [[ ! -f "$pkg" ]]; then
echo -e "${RED}[-] Package not found: $pkg${NC}" >&2
return 1
fi

local fsize
fsize=$(wc -c < "$pkg")
if [[ "$fsize" -lt $SIG_FOOTER_TOTAL ]]; then
echo -e "${RED}[-] Security: file too small (missing signature footer)${NC}" >&2
return 1
fi

if ! has_sig_footer "$pkg"; then
echo -e "${YELLOW}[!] Warning: unsigned package (no LPK signature magic)${NC}"
if [[ "${ULPM_STRICT_SIGNATURES}" == "true" ]]; then
echo -e "${RED}[-] Strict mode: unsigned packages are rejected${NC}" >&2
return 1
fi
return 0
fi

require_openssl3 || return 1

local payload_size=$((fsize - SIG_FOOTER_TOTAL))
local footer_off=$payload_size
local sig_bin="$TEMP_DIR/chk.sig"
local pub_raw="$TEMP_DIR/chk_raw.pub"
local pub_der="$TEMP_DIR/chk_full.pub"

dd if="$pkg" of="$sig_bin" bs=1 skip="$footer_off" count="$SIG_RAW_LEN" status=none
dd if="$pkg" of="$pub_raw" bs=1 skip=$((footer_off + SIG_RAW_LEN)) count="$SIG_PUB_LEN" status=none

if [[ "$(wc -c < "$sig_bin")" -ne $SIG_RAW_LEN || "$(wc -c < "$pub_raw")" -ne $SIG_PUB_LEN ]]; then
echo -e "${RED}[-] Corrupted signature footer${NC}" >&2
rm -f "$sig_bin" "$pub_raw" "$pub_der"
return 1
fi

printf '\x30\x2a\x30\x05\x06\x03\x2b\x65\x70\x03\x21\x00' > "$pub_der"
cat "$pub_raw" >> "$pub_der"

if ! head -c "$payload_size" "$pkg" | openssl pkeyutl -verify -rawin -pubin -keyform DER \
-inkey "$pub_der" -sigfile "$sig_bin" &>/dev/null; then
echo -e "${RED}[-] CRITICAL: Signature verification failed! Package is corrupted or tampered.${NC}" >&2
rm -f "$sig_bin" "$pub_raw" "$pub_der"
return 1
fi

LAST_SIG_FPR=$(openssl dgst -sha256 -r "$pub_raw" 2>/dev/null | cut -d' ' -f1)

local matched=false
local pub_keys=()
shopt -s nullglob
pub_keys=("$TRUSTED_KEYS_DIR"/*.pub)
shopt -u nullglob

local trusted_pub trusted_der
for trusted_pub in ${pub_keys[@]+"${pub_keys[@]}"}; do
trusted_der="$TEMP_DIR/trusted_check.der"
openssl pkey -pubin -inform PEM -in "$trusted_pub" -outform DER -out "$trusted_der" 2>/dev/null || continue

if cmp -s "$pub_der" "$trusted_der"; then
matched=true
echo -e "${GREEN}✔ Valid signature from trusted source: $(basename "$trusted_pub")${NC}"
rm -f "$trusted_der"
break
fi
rm -f "$trusted_der"
done

if [[ "$matched" != "true" ]]; then
if [[ "${ULPM_REQUIRE_TRUSTED_KEYS}" == "true" ]]; then
echo -e "${RED}[-]Valid signature, but publisher key is not trusted (strict trust mode).${NC}" >&2
echo -e "${GRAY}    Key fingerprint (sha256): $LAST_SIG_FPR${NC}" >&2
echo -e "${GRAY}    Add the publisher's .pub with 'ulpm trust <file.pub>'.${NC}" >&2
rm -f "$sig_bin" "$pub_raw" "$pub_der"
return 1
else
echo -e "${YELLOW}[!]Signature is valid, but this publisher is not in your trusted keyring.${NC}" >&2
echo -e "${GRAY}    Fingerprint (sha256): $LAST_SIG_FPR${NC}" >&2
echo -e "${GRAY}    Integrity is verified; publisher identity is not independently established.${NC}">&2
echo -e "${GRAY}    Use 'ulpm trust <file.pub>' to trust this publisher, or${NC}" >&2
echo -e "${GRAY}    ULPM_REQUIRE_TRUSTED_KEYS=trueto reject unknown publishers.${NC}" >&2
fi
fi

rm -f "$sig_bin" "$pub_raw" "$pub_der"
return 0
}