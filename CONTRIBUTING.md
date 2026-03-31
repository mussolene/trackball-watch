# Contributing

## Scope

This repository is an active product-in-development. Contributions are welcome, but changes should preserve the product direction:

- real-time input behavior must stay deterministic
- pointer mechanics matter more than feature count
- assistant behavior must not be added into the hot path of cursor motion

## Before Opening a PR

1. Read [README.md](./README.md)
2. Read [docs/product.md](./docs/product.md)
3. Read [docs/architecture.md](./docs/architecture.md)
4. Verify that your change fits the current product stage

## Development Expectations

- Keep platform boundaries clear.
- Do not commit local certificates, provisioning files, crash dumps, or temporary diagnostics.
- Prefer focused changes over broad refactors unless the refactor clearly reduces risk.
- Add or update tests when changing input behavior or protocol logic.

## Versioning (desktop host)

Desktop bundle versions follow **annotated semver tags** `vMAJOR.MINOR.PATCH` (for example `v1.0.1`).

- `npm run tauri:build` in `apps/host-desktop` runs `scripts/sync-version-from-git.mjs`, which updates `Cargo.toml`, `tauri.conf.json`, `package.json`, and `package-lock.json` from `git describe` (or from `GITHUB_REF` on tag builds in CI).
- If you do not want those files to change locally, set `SKIP_SYNC_VERSION=1` for that command.
- Release builds on GitHub Actions run the same sync step before `npm ci` so artifacts match the pushed tag.

## For Input Changes

When changing pointer behavior, include:

- what mode is affected
- what movement semantics changed
- what tests were added or updated
- what manual behavior should be checked on-device

## Security

If your change touches pairing, encryption, injection, clipboard, or assistant-assisted execution, review [SECURITY.md](./SECURITY.md) before submitting it.
