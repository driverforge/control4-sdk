# Security Policy

## Reporting a vulnerability

Please report security issues **privately** — do not open a public issue.

- **Preferred:** GitHub's [private vulnerability reporting](https://docs.github.com/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability) on this repository (**Security → Report a vulnerability**).
- **Or** email **oss@driverforge.com**.

Please include a description, reproduction steps, and the affected version where you can. We'll acknowledge your report and keep you posted on the fix.

### Encrypting your report

If you report by email and the report contains anything sensitive — exploit details, credentials, logs from a real system — please encrypt it to our OpenPGP key.

```
Key:         Driverforge Security <oss@driverforge.com>
Fingerprint: 118C 8DF5 2508 16AD EB82  9414 D027 75BC C660 101D
```

Check that the fingerprint of the key you import matches the one above. If it doesn't, don't use the key.

With GnuPG, save the key below as `driverforge-security.asc`, then:

```sh
gpg --import driverforge-security.asc
gpg --fingerprint oss@driverforge.com    # compare against the fingerprint above
gpg --armor --encrypt --recipient oss@driverforge.com report.txt
```

Send the resulting `report.txt.asc` as an attachment, or paste it into the body of the email. Put nothing sensitive in the subject line, because the subject isn't encrypted. If you'd like an encrypted reply, include your own public key.

<details>
<summary>Driverforge Security public key</summary>

```
-----BEGIN PGP PUBLIC KEY BLOCK-----

mDMEavA63hYJKwYBBAHaRw8BAQdAITatc7gk54/KDIwIMub0MnjsQiKvDPAgvTsq
izr9geS0KkRyaXZlcmZvcmdlIFNlY3VyaXR5IDxvc3NAZHJpdmVyZm9yZ2UuY29t
Poi1BBMWCgBdFiEEEYyN9SUIFq3rgpQU0Cd1vMZgEB0FAmrwOt4bFIAAAAAABAAO
bWFudTIsMi41KzEuMTIsMCwzAhsBBQkDwmcABQsJCAcCAiICBhUKCQgLAgQWAgMB
Ah4HAheAAAoJENAndbzGYBAduVsBAN0jiT7bxw/435QGdmYkVAQZLwjAn2v28/5f
UM4fJZQWAP9qMzmRs1IXGTVfSkYc6EcQFDDQ1NCdtUuENQ6Db7DHDLg4BGrwOukS
CisGAQQBl1UBBQEBB0AlEwVOcPKCBXhlRzXJMkqU04Ar/hOJafQ0KDSkN/TYZwMB
CAeImgQYFgoAQhYhBBGMjfUlCBat64KUFNAndbzGYBAdBQJq8DrpGxSAAAAAAAQA
Dm1hbnUyLDIuNSsxLjEyLDAsMwIbDAUJA8JnAAAKCRDQJ3W8xmAQHVh7AP9khxtw
lE1AgdQmshfabiDORlOwUv0MpPYFWfNBPDOT6gD8C+prKi2vSshGaRkLLPvVB4F7
+dK19AjykBwiZUPXMQw=
=N4yL
-----END PGP PUBLIC KEY BLOCK-----
```

</details>

The key expires on 2028-11-07. We'll extend it or replace it before then and update this file when we do.

## Scope

This policy covers the Driverforge Control4 **SDK** in this repository — the library a driver vendors. The SDK handles **no secrets at all**: it ships no credentials of its own, and the driver token supplied at `Driverforge:Init` is an identifier rather than a credential — it names the driver, it does not authenticate it. The attestation root embedded at build time is a public key. The backend/ingestion and the agents are separate and out of scope here.

## Supported versions

We support the latest released version — please confirm the issue on the current release before reporting.
