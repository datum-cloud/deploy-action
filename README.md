# Deploy to Datum Cloud

A GitHub Action that deploys a container workload to
[Datum Cloud](https://www.datum.net) Compute and, optionally, publishes it on a
Datum-managed HTTPS URL.

The action installs `datumctl` and its compute plugin, signs in a Datum service
account, and runs `datumctl compute deploy`. It creates the workload if it does
not exist and updates it otherwise, waits for the rollout to finish, and
returns the workload's URL.

## Usage

```yaml
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - name: Deploy
        id: deploy
        uses: datum-cloud/deploy-action@v1
        with:
          credentials: ${{ secrets.DATUM_SA_CREDENTIALS }}
          project: my-project
          workload: api
          image: ghcr.io/acme/api:1.4.2
          cities: DFW,IAD
          http-port: '8080'

      - run: echo "Deployed to ${{ steps.deploy.outputs.url }}"
```

### Build from source and deploy

With `build-context`, the action builds the image with the runner's Docker
BuildKit, pushes it to `image` and deploys the pushed digest. Sign in to the
registry first.

```yaml
jobs:
  deploy:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
    steps:
      - uses: actions/checkout@v7

      - uses: docker/login-action@v4
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - uses: datum-cloud/deploy-action@v1
        with:
          credentials: ${{ secrets.DATUM_SA_CREDENTIALS }}
          project: my-project
          workload: api
          image: ghcr.io/${{ github.repository }}:${{ github.sha }}
          build-context: .
          cities: DFW
          http-port: '8080'
          env: |
            LOG_LEVEL=info
            ALLOWED_ORIGINS=https://a.example,https://b.example
          env-from-secrets: |
            api-keys
```

The workload must be able to pull the image. A private registry needs pull
credentials on the workload, which this action does not set; make the package
public or deploy from a workload manifest.

## Prerequisites

1. Compute is enabled for the project (`datumctl services enable
   compute.datumapis.com`).
2. A service account in the project, with a Datum-managed key and roles that
   allow it to manage workloads. See
   [Service accounts](https://www.datum.net/docs/projects/service-accounts).
3. The key's credentials JSON stored as a repository or environment secret,
   such as `DATUM_SA_CREDENTIALS`. Raw JSON and base64 are both accepted.

The action runs on Linux runners.

## Self-hosted runners

The action leaves nothing behind. Each run signs in with its home and config
directories pointed at a private directory under `RUNNER_TEMP`, so the
session, the service account key and any file-stored token never land in the
runner user's home. If the runner has a system keyring, datumctl may store
the session there instead, and the final step signs that session out. That
step runs even when the deploy fails or the job is cancelled, and then
deletes the directory.

A runner that is killed or loses power mid-job cannot run that step, and the
directory stays in `RUNNER_TEMP` until the runner is cleaned. Run self-hosted
runners as ephemeral, one job per fresh machine or container, so that nothing
survives a job whatever happens.

## Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `credentials` | yes | | Service account credentials JSON, raw or base64. Pass it from a secret. |
| `project` | yes | | Datum Cloud project that owns the workload. |
| `workload` | yes | | Workload name: lowercase letters, digits and `-`. |
| `image` | yes | | Fully qualified image, such as `ghcr.io/acme/api:1.4.2`. The push destination when `build-context` is set. |
| `build-context` | | | Directory to build and push the image from, relative to `working-directory`. |
| `locations` | one of three | | Comma-separated locations, such as `us-east-1,eu-west-1`. |
| `cities` | one of three | | Comma-separated city codes, such as `DFW,IAD`. |
| `location-selector` | one of three | | Label selector over location topology. |
| `http-port` | | | Port the container serves HTTP on. Publishes the workload on a Datum-managed HTTPS URL. |
| `http2` | | | `true` when the container serves HTTP/2 or gRPC, `false` to switch back to HTTP/1.1. |
| `min-instances` | | | Minimum instances per location. |
| `max-instances` | | | Maximum instances to autoscale to; `0` disables autoscaling. |
| `instance-type` | | `datumcloud-d1-standard-2` | Instance type. Applied on every deploy, so pass it each time to keep another type. |
| `runtime-class` | | | Runtime class of a new workload, such as `general-purpose`. Fixed once the workload exists. |
| `network` | | | Network a new workload attaches to. Fixed once the workload exists. |
| `env` | | | Environment variables, one `KEY=VALUE` per line. `KEY-` removes one. Values are trimmed and cannot span lines. |
| `env-from-secrets` | | | Secrets to import as variables, one `NAME` or `NAME:PREFIX_` per line. |
| `env-from-configmaps` | | | ConfigMaps to import as variables, one `NAME` or `NAME:PREFIX_` per line. |
| `secret-mounts` | | | Secrets to mount, one `NAME:/mount/path` per line. |
| `configmap-mounts` | | | ConfigMaps to mount, one `NAME:/mount/path` per line. |
| `labels` | | | Labels, one `key=value` per line. Changing a label replaces the instances. |
| `rollout-timeout` | | `15m` | How long the deploy may take, including any build, such as `10m`. The step fails when exceeded. |
| `working-directory` | | `.` | Directory the deploy runs in. The deploy writes `workload.yaml` here. |
| `datumctl-version` | | `v0.24.0` | [datumctl release](https://github.com/datum-cloud/datumctl/releases) to install. |
| `compute-plugin-version` | | `v0.16.3` | [compute plugin release](https://github.com/datum-cloud/compute/releases) to install. |
| `auth-hostname` | | `auth.datum.net` | Datum auth server hostname. |

An input left empty keeps the workload's current setting on a redeploy, so a
routine image bump changes nothing else. Pass the location inputs and
`instance-type` on every deploy. Leave `http-port` empty on a redeploy unless the URL should change.

Put secret values in a Datum Secret and import them with `env-from-secrets`,
not in `env`. Values passed in `env` are stored in the workload spec.

## Outputs

| Output | Description |
|---|---|
| `url` | The workload's Datum-managed HTTPS URL, or empty when it is not published. |
| `workload` | Name of the deployed workload. |

## Rollout behavior

The step succeeds once the rollout finishes. When `rollout-timeout` passes
first, the step fails and a rollout already started continues on Datum Cloud; check it with
`datumctl compute workloads describe <workload> --project <project>`.

A new URL can take a few minutes to answer while DNS and its certificate
settle.

## Deploying from a manifest

For a workload this action's inputs cannot describe, such as one with several
containers or a private registry, install and sign in with
[setup-datumctl-action](https://github.com/datum-cloud/setup-datumctl-action)
and run `datumctl apply -f <manifest> --project <project>`.

## Versioning

Releases follow [semantic versioning](https://semver.org). The major tag, such
as `v1`, moves to the latest compatible release. For the strongest supply-chain
guarantee, pin the full commit SHA of a release:

```yaml
uses: datum-cloud/deploy-action@<commit-sha> # v1.0.0
```

## License

[Apache License 2.0](LICENSE)
