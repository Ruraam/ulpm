#ULPM APT Repository - GPG SIGNED

Public Key: `KEY.gpg` (armored) and `ulpm.gpg` (binary)

## Secure Installation (Recommended)
1. Add the official GPG signing key
```bash
curl -fsSL https://ruraam.github.io/ulpm/KEY.gpg | gpg --dearmor | sudo tee /usr/share/keyrings/ulpm.gpg > /dev/null
```
2. Add the signed APT repository
```bash
curl -fsSL https://ruraam.github.io/ulpm/KEY.gpg | gpg --dearmor | sudo tee /usr/share/keyrings/ulpm.gpg > /dev/null
```
3. Update and install
```bash
sudo apt update
sudo apt install ulpm
```
## For GitHub Pages
```bash
echo "deb [signed-by=/usr/share/keyrings/ulpm.gpg] https://ruraam.github.io/ulpm stable main" | sudo tee /etc/apt/sources.list.d/ulpm.list
```
## Manual Verification
```bash
gpg --import KEY.gpg
gpg --verify dists/stable/InRelease
```
Key fingerprint & details:
```
pub   rsa4096 2026-10-13 [SCEA][expires: 2028-10-12]
4E43 841C 8D0A BF27 F40C  7DB1 FD3F AD46 F663 2183
uid [ultimate] ULPM Repository (Official APT Repository Signing Key) <ulpm@ruraam.dev>
sub rsa4096 2026-10-13 [SEA][expires: 2028-10-12]
```
