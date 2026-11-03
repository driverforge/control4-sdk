# Attestation public keys (prod)

Public keys the SDK embeds to verify the Anvil agent's identity (the SDK↔agent
handshake). The build injects all of these into the built bundle; committed
SDK source stays key-less. **Public keys only — never a private key here** (CI
enforces this).

This directory is inside `sdk/**`, so it **mirrors to the open-source
repo** — deliberately. Publishing the verification public key lets anyone audit
that the SDK trusts exactly the key we say it does; it grants no capability.

- `attestation-public-prod-2.pem` — `kid` **attest-prod-2**, RSA-4096. The key
  the cloud signs device attestations with.
- `attestation-public-prod-3.pem` — `kid` **attest-prod-3**, RSA-4096. A
  standby: nothing signs with it yet. It ships now so that moving the cloud to
  it needs no SDK release.

The build embeds every `attestation-public-prod-*.pem` here, with the `kid`
taken from the file name.

`attest-prod-1` is retired. Its private key no longer exists, so no
attestation can carry it again.

## Rotation

The cloud moves to the standby key; SDKs already in the field trust it. Then a
new standby, `attestation-public-prod-N.pem`, is added here and ships in the
next release. Retire a file once no outstanding attestation carries its `kid`.
