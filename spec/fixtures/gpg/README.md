# Test keys

OpenPGP keys generated for the specs, on 2026-11-18, with gpg 2.5.24. They
sign nothing but the packages the specs build, protect nothing, and their
private halves are public by being here: never use them for a release.

| Files | Key | Passphrase | Fingerprint |
|---|---|---|---|
| `rsa-secret.asc`, `rsa-public.asc` | RSA 3072, no encryption subkey, no expiry | `crystalreleaser-spec` | `9BCB5C9D9BCDDC23B63C403FB7A81D331E802F50` |
| `ed25519-secret.asc`, `ed25519-public.asc` | Ed25519, no encryption subkey, no expiry | none | `6CC6E8C79701909AA1CE8A209C8CDABADD46C2D3` |

The two cover what the signing code branches on: a key with and without a
passphrase, and the two signature header tags of an RPM package (`RSAHEADER`
for RSA, `DSAHEADER` for Ed25519).

To generate them again (the fingerprints in the specs then change):

```sh
export GNUPGHOME="$(mktemp -d)"
gpg --batch --pinentry-mode loopback --passphrase crystalreleaser-spec \
  --quick-generate-key "crystalreleaser spec RSA <rsa@spec.invalid>" rsa3072 sign never
gpg --batch --pinentry-mode loopback --passphrase "" \
  --quick-generate-key "crystalreleaser spec Ed25519 <ed25519@spec.invalid>" ed25519 sign never
gpg --batch --pinentry-mode loopback --passphrase crystalreleaser-spec \
  --armor --output rsa-secret.asc --export-secret-keys rsa@spec.invalid
gpg --armor --output rsa-public.asc --export rsa@spec.invalid
gpg --armor --output ed25519-secret.asc --export-secret-keys ed25519@spec.invalid
gpg --armor --output ed25519-public.asc --export ed25519@spec.invalid
gpgconf --kill all
```
