# Contributing

## Layout

| Path | Purpose |
|---|---|
| `action.yaml` | Action metadata: inputs, outputs and the composite steps. |
| `scripts/deploy.sh` | Turns the inputs into a `datumctl compute deploy` call and writes the outputs. |
| `test/deploy_test.sh` | Tests `deploy.sh` against a stub `datumctl`. |
| `.github/workflows/ci.yaml` | Lint and test on every pull request. |
| `.github/workflows/e2e.yaml` | Deploys a real workload to Datum Cloud, checks its URL and destroys it. |
| `.github/workflows/release.yaml` | Moves the major version tag forward when a release from `main` is published. |

## Checks

Run every check CI runs:

```bash
task ci
```

It needs Go (for actionlint) and shellcheck on `PATH`.

## End-to-end test

`e2e.yaml` runs on pushes to `main` and on demand. It uses the `e2e` repository
environment, which needs:

| Name | Kind | Value |
|---|---|---|
| `DATUM_SA_CREDENTIALS` | secret | Credentials JSON of a service account in the test project, allowed to manage workloads. |
| `DATUM_PROJECT` | variable | The test project. |
| `DATUM_CITY` | variable | A city code the project can deploy to, such as `DFW`. |

Each run deploys a workload named `e2e-<run id>-<attempt>` and destroys it when
the job ends, whether or not the checks passed.

## Releasing

1. Confirm CI and E2E passed on the commit to release.
2. Draft a GitHub release with a new `vX.Y.Z` tag on that commit. Increase the
   major version for any change that breaks existing workflows, such as a
   removed or renamed input or a changed default with different behavior.
3. Tick **Publish this Action to the GitHub Marketplace** and publish.

Publishing triggers `release.yaml`, which moves the `vX` tag to the new release
when it is the highest `vX.*.*` release and its commit is on `main`.

When a new `datumctl` or compute plugin release is adopted, update the
`datumctl-version` and `compute-plugin-version` defaults in `action.yaml` and
the matching rows in `README.md` together.
