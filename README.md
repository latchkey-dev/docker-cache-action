# Latchkey Docker Cache Action

Build Docker images with automatic ECR-based layer caching on [Latchkey](https://github.com/latchkey-dev) managed runners.

When running on a Latchkey managed runner, the `ECR_CACHE_REPO` environment variable is automatically injected. This action detects it and configures BuildKit `--cache-from` and `--cache-to` flags so Docker layers are cached across ephemeral runner instances.

On non-Latchkey runners (e.g. GitHub-hosted), the build proceeds normally without cache flags.

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

## How It Works

1. Sets up Docker Buildx
2. Checks for `ECR_CACHE_REPO` in the runner environment
3. If present, adds `--cache-from=type=registry,ref=$ECR_CACHE_REPO:cache` and `--cache-to=type=registry,ref=$ECR_CACHE_REPO:cache,mode=max`
4. Runs `docker buildx build` with all configured flags

Latchkey's infrastructure handles everything else: ECR repository creation, IAM credentials, and the ECR credential helper are all pre-configured on the managed runner AMI.

## License

MIT
