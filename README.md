# Deploy to Komuta

Start a [Komuta](https://komuta.io) deploy from CI and wait for the result. The job passes when the new version is live and fails when the build or rollout fails.

## GitHub Actions

```yaml
- uses: Microzon-Tech/komuta-deploy-action@v1
  with:
    token: ${{ secrets.KOMUTA_DEPLOY_TOKEN }}
    service-id: <SERVICE_ID>
```

Without a stored secret (OIDC). Create a deploy token with the CI identity **GitHub Actions** and this repository first, then:

```yaml
jobs:
  deploy:
    runs-on: ubuntu-latest
    permissions:
      id-token: write
      contents: read
    steps:
      - uses: Microzon-Tech/komuta-deploy-action@v1
        with:
          service-id: <SERVICE_ID>
```

Deploy a ready-made image instead of building:

```yaml
- uses: Microzon-Tech/komuta-deploy-action@v1
  with:
    token: ${{ secrets.KOMUTA_DEPLOY_TOKEN }}
    service-id: <SERVICE_ID>
    mode: image
    image: registry.example.com/app@${{ steps.push.outputs.digest }}
```

| Input | Default | |
|-------|---------|--|
| `token` | — | Deploy token (`kmtd_...`), stored as a secret. Leave empty to use the workflow's OIDC identity. |
| `service-id` | — | Komuta service id. |
| `mode` | `build` | `build` or `image`. |
| `ref` | pushed ref | Branch or tag to build. |
| `sha` | — | Exact commit to build. |
| `image` | — | Image pinned by digest, for `image` mode. |
| `wait` | `true` | Wait for the result and fail the job if the deploy fails. |
| `timeout` | `1800` | Seconds to wait. |

Outputs: `deployment-id`, `status`, `console-url`.

## GitLab CI

```yaml
include:
  - remote: https://raw.githubusercontent.com/Microzon-Tech/komuta-deploy-action/v1/gitlab/komuta-deploy.gitlab-ci.yml

deploy:
  extends: .komuta-deploy
  variables:
    KOMUTA_SERVICE_ID: <SERVICE_ID>
  # Either KOMUTA_DEPLOY_TOKEN as a masked CI/CD variable, or no secret at all:
  # the template requests a GitLab ID token (KOMUTA_ID_TOKEN) for an OIDC-trusted deploy token.
```

## Any CI (CLI)

```bash
curl -fsSL -o komuta-deploy https://raw.githubusercontent.com/Microzon-Tech/komuta-deploy-action/v1/komuta-deploy.sh
chmod +x komuta-deploy
KOMUTA_DEPLOY_TOKEN=... ./komuta-deploy --service <SERVICE_ID> --ref main --wait
```

Requires `bash`, `curl` and `jq`. Exit codes: `0` succeeded or superseded, `1` failed or cancelled, `2` timed out, `3` invalid usage, `4` rejected by Komuta (permissions, signature, billing).

See [Deploying from CI](https://komuta.io/docs/ci-deploy) for tokens, permissions and error codes.
