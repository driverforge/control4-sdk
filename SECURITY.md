# Security Policy

## Reporting a vulnerability

Please report security issues **privately** — do not open a public issue.

- **Preferred:** GitHub's [private vulnerability reporting](https://docs.github.com/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability) on this repository (**Security → Report a vulnerability**).
- **Or** email **oss@driverforge.com**.

Please include a description, reproduction steps, and the affected version where you can. We'll acknowledge your report and keep you posted on the fix.

## Scope

This policy covers the Driverforge Control4 **SDK** in this repository — the library a driver vendors. The SDK handles **no secrets at all**: it ships no credentials of its own, and the driver token supplied at `Driverforge:Init` is an identifier rather than a credential — it names the driver, it does not authenticate it. The attestation root embedded at build time is a public key. The backend/ingestion and the agents are separate and out of scope here.

## Supported versions

We support the latest released version — please confirm the issue on the current release before reporting.
