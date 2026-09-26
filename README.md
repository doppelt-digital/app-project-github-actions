# Application Platform GitHub Actions

Reusable workflows mirroring `app-project-pipelines` for GitHub-hosted runners.

Published at `doppelt-digital/app-project-github-actions`. Customer repositories get a bootstrap `.github/workflows/ci.yml`:

```yaml
jobs:
  ci:
    uses: doppelt-digital/app-project-github-actions/.github/workflows/flutter.yml@main
    secrets: inherit
```

Layout in this folder maps to the GitHub repo:

| Here | GitHub repo |
|------|-------------|
| `workflows/*.yml` | `.github/workflows/` |
| `actions/setup-asdf/` | `.github/actions/setup-asdf/` |

macOS jobs run on `macos-15` and install toolchains with the composite action (ASDF). They do not use Tart.
