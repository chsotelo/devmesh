# Contributing

## Before opening a pull request

Run both checks:

```bash
make check        # shellcheck + shfmt -i 2 -ci + bats
make integration  # real hub and machines in containers (requires Docker)
```

Both must pass.

## Rules

- Every change ships with a test. Bug fixes get a regression test.
- Shell style: `shfmt -i 2 -ci`, and `shellcheck` clean. Do not disable a
  check without a comment that explains why.
- Code, comments, logs, and error messages are in English.
- UI strings live in `client/lib/i18n/`. Do not hardcode user-facing text in
  the panel code.
- Keep changes focused. One concern per pull request.
- Do not commit secrets, keys, backups, or machine-specific data (hostnames,
  IP addresses, domains). `tests/repo_hygiene.bats` enforces part of this.

## Pull requests

- Describe what changed and why, in English.
- Fill in the pull request template.
- Keep the description short; no marketing language.

## Workflow

- `main` is protected: every change arrives through a pull request from a branch
  (`feat/…`, `fix/…`, `docs/…`) or a fork, and merges only with CI green (squash merge,
  linear history).
- Releases are tags `vX.Y.Z` on `main`: bump `VERSION`, move the `CHANGELOG.md`
  entries under the new version, tag. The release workflow publishes the tarball,
  `SHA256SUMS`, build provenance and the hub image.
- Your own hub's settings go in `deploy.local.mk` (copy `deploy.local.mk.example`; git
  ignores it). Deploy a release, not a work in progress: `git checkout vX.Y.Z && make hub`.
