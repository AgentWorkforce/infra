# Contributing

Thanks for your interest in Agent Relay infrastructure. Bug reports, fixes and improvements
are welcome.

## Before you start

- **Security issues:** do not open a public issue. Follow [SECURITY.md](SECURITY.md).
- **Bugs:** open an issue with the version or commit, what you expected, what
  happened, and the smallest reproduction you can manage. Remove credentials,
  tokens and personal data from logs before you paste them.
- **Larger changes:** open an issue first to discuss the approach, so your work
  doesn't conflict with something already in progress.

## Development

You need `helm`, `kubeconform`, `yq`, Python 3 and Node.js; see
`.github/workflows/lint.yml` for the versions CI uses.

```sh
scripts/ci/charts.sh static
ci/agent-relay/render.sh
scripts/ci/deps.sh
```

Run these checks before you open a pull request. CI runs these and more (see
`.github/workflows/lint.yml`), including a chart version-bump check: bump a
chart's `version` in `Chart.yaml` when you change it.

Terraform module and example checks run through `terraform/scripts/check.sh`;
see [terraform/README.md](terraform/README.md) for tools and provider interfaces.
A passing source check is separate from the
[full application lifecycle proof](docs/terraform-helm-application-proof.md).

## Pull requests

- Branch from `main` and keep each pull request focused on one change.
- Add or update tests for behaviour you change.
- Use short, conventional commit messages (`fix: ...`, `feat: ...`, `docs: ...`).
- Describe what changed and why, and how you tested it.
- Never commit secrets, credentials, real customer data or production
  identifiers, including in tests and fixtures. Use obviously fake values.
- Fork pull request CI runs without repository secrets. One
  check, `search-worker-role-kind`, needs a repository secret: on a fork pull
  request that touches the Sessions Pipeline charts it fails rather than skips,
  and a maintainer re-runs it from a branch in this repository before merge.

A maintainer reviews every pull request. We may ask for changes, or decline a
change that doesn't fit the project's direction.

## License

By contributing, you agree that your contributions are licensed under the
the [Functional Source License 1.1, ALv2 Future License](LICENSE)
(FSL-1.1-ALv2), the license of this repository, and that Agent Workforce, Inc.
may also offer them under the Apache License 2.0 and under its commercial
licenses.
