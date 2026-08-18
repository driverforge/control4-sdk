# Attestation public keys (prod)

Public keys the SDK embeds to verify the Anvil agent's identity (the SDK↔agent
handshake). The build injects one of these into the built bundle; committed
SDK source stays key-less. **Public keys only — never a private key here** (CI
enforces this).

This directory is inside `sdk/**`, so it **mirrors to the open-source
repo** — deliberately. Publishing the verification public key lets anyone audit
that the SDK trusts exactly the key we say it does; it grants no capability.

- `attestation-public-prod-1.pem` — `kid` **attest-prod-1**. The public half of
  the non-exportable RSA-2048 signing key `device-attestation` in the
  `kmsgroup-keyvault` Key Vault, which the cloud uses to sign device
  attestations.

## Rotation

Add `attestation-public-prod-2.pem` (etc.) for a new `kid` and inject it
alongside the current key — the SDK holds a `kid`-keyed map and can trust
several prod keys at once during a rollover. Retire the old file once no
outstanding attestation carries the old `kid`.
