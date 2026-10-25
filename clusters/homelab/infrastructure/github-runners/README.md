# GitHub Actions runners

Self-hosted runners for GitHub Actions, run by Actions Runner Controller (ARC) runner scale sets.

```yaml
jobs:
  build:
    runs-on: homelab
```

- **Controller** (`arc-systems`): `gha-runner-scale-set-controller`. For each scale set it starts a
  **listener** pod (also in `arc-systems`) that long-polls GitHub for jobs.
- **Runners** (`arc-runners`): one fresh pod per job (ephemeral), deleted afterwards. Image
  `ghcr.io/actions/actions-runner` (Ubuntu 24.04) with a Docker-in-Docker sidecar, so `services:`,
  `docker build` and `docker/build-push-action` work. Per job: 6 CPU / 12Gi for the steps, 8 CPU / 36Gi
  for Docker, 2Gi /dev/shm (Chromium). A job's bulk writes stay off disk: the 6Gi workspace and 2Gi npm
  cache (part of the steps' 12Gi) and the 30Gi Docker storage (part of Docker's 36Gi) are tmpfs, because
  on disk they stalled etcd, which shares dell-r620's spinning RAID. On dell-r620 only.
- **Auth**: GitHub App `tkuipers-homelab-runners` (Administration: write, Metadata: read), from the
  1Password item "GitHub Actions Runner App" via `templates/external-secret.yaml`. Create or rotate it with
  `tooling/scripts/setup-credentials/setup-github-runner-credentials.sh`.
- **Monitoring**: Grafana > Infrastructure > "GitHub Actions runners (ARC)"; alerts `hl-arc-*`.

## Security

The dind sidecar is **privileged**, so a job can take over the node it runs on (dell-r620) and
read every secret there. Only attach private repos whose workflows you write. GitHub advises against
self-hosted runners on public repos because a fork's pull request can run code on them.

## Repositories

`tkuipers` is a user account. GitHub registers self-hosted runners per repository, organization or
enterprise, so there is no account-wide runner: each repo gets its own scale set. They share the
controller, the App and the pod template, and all carry the `homelab` label.

| Repo | Scale set | Warm runners | Max |
|------|-----------|--------------|-----|
| tkuipers/homelab-agent | homelab-agent | 1 | 4 |

### Add a repo

1. Give the App access to it: github.com/settings/installations > tkuipers-homelab-runners > Configure >
   Repository access > add the repo.
2. `Chart.yaml`: another dependency with `alias: <repo>`.
3. `values.yaml`: a block for the alias, like `homelab-agent:` (its own `githubConfigUrl` and
   `runnerScaleSetName`, `template: *runner-template`).
4. Add the repo to `REPOS` in the setup script, so `--check` covers it.

## The runner image vs GitHub's ubuntu-latest

GitHub's hosted image ships hundreds of tools; this one has the basics (git, jq, curl, ssh, docker CLI,
python3, unzip, passwordless sudo). It has no yq, make, gcc, node, wget, zstd or xz. Install what a job
needs in the job: `sudo apt-get install -y <pkg>`, a setup action (`actions/setup-node`), or for yq:

```yaml
      - run: sudo curl -fsSL -o /usr/local/bin/yq https://github.com/mikefarah/yq/releases/download/v4.54.1/yq_linux_amd64 && sudo chmod +x /usr/local/bin/yq
```

## CPU count inside a job

`nproc` and Node's `os.cpus()` report the node's 48 cores, not the pod's limit, so anything that sizes
itself from the core count oversubscribes the pod. Set the parallelism explicitly in CI:

- Playwright (default: 50% of `os.cpus()` = 24 workers): `workers: process.env.CI ? 4 : undefined`
- anything using `make -j$(nproc)` or similar: a fixed number such as `-j6`

## Troubleshooting

```bash
kubectl get autoscalingrunnersets -A                       # scale sets, current/desired runners
kubectl -n arc-systems get autoscalinglisteners,pods       # listener per scale set
kubectl -n arc-runners get ephemeralrunners,pods           # one per job
kubectl -n arc-systems logs deploy/arc-controller | jq -c 'select(.level != "info")'
tooling/scripts/setup-credentials/setup-github-runner-credentials.sh --check
```

Jobs stuck on "Waiting for a runner to pick up this job": the listener is down (App credentials), or
`runs-on` names a label no scale set has.
