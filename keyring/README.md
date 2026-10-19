# The archive signing key

Signs the `apt` repo's `InRelease`. Generated 2026-10-19: Ed25519, sign and certify only, no expiry,
no passphrase.

```
7BA7 3311 5EBD 092A 6E29  62B0 6EE7 70FA FCBE 0D96
TVBian archive signing key <archive@tvbian.com>
```

`tvb-archive-keyring.gpg` is the public key, binary. The private key is never committed; CI signs
from the `ARCHIVE_SIGNING_KEY` Actions secret.

## Load the secret

```sh
gh secret set ARCHIVE_SIGNING_KEY < <private-key-file>        # host, repo root
```

## Check a key file

```sh
gpg --show-keys --with-fingerprint keyring/tvb-archive-keyring.gpg   # host: fingerprint above
```

## Trust it on a box not flashed from our image

```sh
sudo curl -fsSLo /usr/share/keyrings/tvb-archive-keyring.gpg \
  https://raw.githubusercontent.com/<gh-repo>/main/keyring/tvb-archive-keyring.gpg   # box
```

## Rotate

No expiry, so only on compromise or by choice.

1. Generate the new key the same way, in a throwaway `GNUPGHOME`.
2. Commit `tvb-archive-keyring.gpg` holding both public keys; `tvb-archive-keyring` ships it.
3. Sign `InRelease` with both keys for one release cycle.
4. Drop the old key from the file and the secret.

A compromised key cannot announce its own successor: rotate by reflash or a manual key install.
