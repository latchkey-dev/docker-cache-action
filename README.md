# Latchkey Docker Cache Build

Build Docker images with automatic ECR layer caching on [Latchkey](https://latchkey.dev) managed
runners. Layers persist across ephemeral runner instances with no registry wiring of your own.

**New to Latchkey?** Start at **[latchkey.dev/sign-in](https://latchkey.dev/sign-in)**: sign in with
GitHub, connect your organization, and pick your repositories. Then point a job at a Latchkey runner
and this action works with no further setup.

When running on a Latchkey managed runner, the `ECR_CACHE_REPO` environment variable is injected
automatically. This action detects it and configures BuildKit `--cache-from` and `--cache-to` so
Docker layers survive between runs.

> On non-Latchkey runners, including GitHub-hosted, the build proceeds normally without cache flags.
> Nothing breaks — you just do not get the cache.

## Usage

```yaml
jobs:
  build:
    runs-on: [self-hosted, latchkey-medium]
    steps:
      - uses: actions/checkout@v4

      - uses: latchkey-dev/docker-cache-action@v1
        with:
          context: .
          tags: myapp:latest
          push: true
```

## Inputs

| Input | Description | Required | Default |
|-------|-------------|----------|---------|
| `context` | Build context path | No | `.` |
| `dockerfile` | Path to Dockerfile (relative to context) | No | `Dockerfile` |
| `tags` | Image tags (newline or comma separated) | **Yes** | |
| `push` | Push image to registry after build | No | `false` |
| `build-args` | Build arguments (newline separated, `KEY=VALUE`) | No | |
| `target` | Build target stage | No | |
| `platforms` | Target platforms (e.g. `linux/amd64,linux/arm64`) | No | |
| `cache-mode` | BuildKit cache mode (`min` or `max`) | No | `max` |
| `cache-tag` | ECR image tag used for cache layers | No | `cache` |
| `extra-cache-from` | Additional `--cache-from` arguments (newline separated) | No | |
| `extra-cache-to` | Additional `--cache-to` arguments (newline separated) | No | |

## Outputs

| Output | Description |
|--------|-------------|
| `cache-configured` | Whether ECR cache flags were configured (`true`/`false`) |
| `image-digest` | Image digest from the build |

## How it works

1. Sets up Docker Buildx
2. Checks for `ECR_CACHE_REPO` in the runner environment
3. If present, adds `--cache-from=type=registry,ref=$ECR_CACHE_REPO:cache` and `--cache-to=type=registry,ref=$ECR_CACHE_REPO:cache,mode=max`
4. Runs `docker buildx build` with all configured flags

Everything else is handled by the [Latchkey managed runner](https://latchkey.dev/documentation/runners-overview):
ECR repository creation, IAM credentials, and the ECR credential helper are pre-configured on the
runner AMI. Full details in the
[Docker layer caching docs](https://latchkey.dev/documentation/docker-layer-caching).

For dependency caches — `node_modules`, `~/.gradle`, `~/.m2` — use
[`latchkey-dev/cache-action`](https://github.com/marketplace/actions/latchkey-fast-cache), covered in
[dependency caching](https://latchkey.dev/documentation/dependency-caching).

## About Latchkey

Managed, ephemeral GitHub Actions runners that repair transient build failures mid-run. A fresh
Ubuntu 24.04 machine per job, destroyed when the job ends, and a hosted MCP server so your coding
agent can triage failures directly.

- [Documentation](https://latchkey.dev/documentation) · [Quickstart](https://latchkey.dev/documentation/quickstart) · [Runners](https://latchkey.dev/github-actions-runners)
- [Self-healing: what it does](https://latchkey.dev/documentation/self-healing)
- [Connect your AI agent (MCP)](https://latchkey.dev/documentation/connect-your-ai-agent)
- [Free for open source](https://latchkey.dev/open-source) — a free Scale plan for public, openly licensed projects

## License

MIT
