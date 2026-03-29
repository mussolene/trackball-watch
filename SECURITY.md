# Security Policy

## Reporting

If you find a security issue, do not open a public issue with exploit details.

Report it privately to the maintainers through the repository security advisory flow or private maintainer contact.

## Scope

The highest-risk areas in this repository are:

- pairing and session key exchange
- packet authentication and encryption
- desktop input injection
- mobile relay and background connectivity
- clipboard, buffer, and future assistant-integrated input flows

## Publication Checklist

Before making the repository public or cutting a release, verify:

1. No certificates, provisioning profiles, private keys, `.env` files, or local Xcode config files are tracked.
2. No crash dumps, temporary diagnostics, or local device metadata are tracked.
3. CI and release workflows reference GitHub Secrets only, not inline credentials.
4. README and docs do not contain placeholder org links, private hosts, local IPs as product defaults, or unpublished distribution URLs.
5. Git history has been scanned for accidental secrets, not just the current working tree.

## Notes

This project intentionally documents the existence of CI secrets such as signing keys and App Store credentials in workflow files. Those references are expected and are not leaks by themselves.
