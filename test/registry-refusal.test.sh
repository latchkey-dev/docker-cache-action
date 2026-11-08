#!/usr/bin/env bash
# Runs the action's build step, as action.yml carries it, with the real docker buildx against a
# registry that answers every request with 403, the way the cache registry answers a job whose
# credentials may neither pull nor push the layer cache.
#
#   bash test/registry-refusal.test.sh
#
# Needs docker with buildx, and pulls the BuildKit image. Where buildx is missing it skips, unless
# REQUIRE_BUILDX=true, which CI sets.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTION="$ROOT/action.yml"

if ! docker buildx version >/dev/null 2>&1; then
  if [ "${REQUIRE_BUILDX:-}" = "true" ]; then
    echo "docker buildx is not installed" >&2
    exit 1
  fi
  echo "skip - docker buildx is not installed here"
  exit 0
fi

WORK="$(mktemp -d)"
BUILDER="dca-refusal-$$"
IMAGE="dca-refusal:$$"
SERVER_PID=""
cleanup() {
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
  fi
  docker buildx rm "$BUILDER" >/dev/null 2>&1 || true
  docker image rm "$IMAGE" >/dev/null 2>&1 || true
  rm -f "$WORK/step.sh" "$WORK/mutated.sh" "$WORK/registry.py" "$WORK/port" "$WORK/requests" \
    "$WORK/buildkitd.toml" "$WORK/output" "$WORK/log" "$WORK/calls" "$WORK/bin/docker" \
    "$WORK/ctx/Dockerfile" "$WORK/ctx/marker"
  rmdir "$WORK/bin" "$WORK/ctx" "$WORK" 2>/dev/null || true
}
trap cleanup EXIT

FAILED=0
PASSED=0
pass() { PASSED=$((PASSED + 1)); echo "ok - $1"; }
fail() { FAILED=$((FAILED + 1)); echo "not ok - $1: $2"; }

# The step's script is the block under `run: |` in the "Build with ECR cache" step.
awk '
  /^      run: \|$/ { inrun = 1; next }
  inrun && NF && !/^        / { exit }
  inrun { sub(/^        /, ""); print }
' "$ACTION" > "$WORK/step.sh"
if ! grep -q 'docker buildx build' "$WORK/step.sh"; then
  echo "could not read the build step's script out of action.yml" >&2
  exit 1
fi
# The same step with the export's ignore-error taken out: the build a refused export fails.
sed 's/,ignore-error=true//' "$WORK/step.sh" > "$WORK/mutated.sh"

cat > "$WORK/registry.py" <<'PY'
import http.server
import json
import os
import sys

requests_path, port_path = sys.argv[1], sys.argv[2]
BODY = json.dumps(
    {"errors": [{"code": "DENIED", "message": "requested access to the resource is denied"}]}
).encode()


class Refuse(http.server.BaseHTTPRequestHandler):
    def refuse(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length:
            self.rfile.read(length)
        with open(requests_path, "a") as f:
            f.write(f"{self.command} {self.path}\n")
        self.send_response(403)
        self.send_header("Content-Type", "application/json")
        self.send_header("Docker-Distribution-API-Version", "registry/2.0")
        self.send_header("Content-Length", str(len(BODY)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(BODY)

    do_GET = do_HEAD = do_PUT = do_POST = do_PATCH = do_DELETE = refuse

    def log_message(self, *args):
        pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Refuse)
with open(port_path + ".tmp", "w") as f:
    f.write(str(server.server_address[1]))
os.replace(port_path + ".tmp", port_path)
server.serve_forever()
PY
: > "$WORK/requests"
python3 -I "$WORK/registry.py" "$WORK/requests" "$WORK/port" &
SERVER_PID=$!
for _ in $(seq 1 50); do
  [ -s "$WORK/port" ] && break
  sleep 0.1
done
PORT="$(cat "$WORK/port")"
REGISTRY="127.0.0.1:${PORT}"
REPO_URL="${REGISTRY}/latchkey-runners/acme/cache"
REF="${REPO_URL}:cache-refusal"

# Plain HTTP only: with insecure set too, BuildKit tries TLS first and falls back to HTTP only when
# the answer to its handshake starts with "HTTP/", which this server's does not.
cat > "$WORK/buildkitd.toml" <<TOML
[registry."${REGISTRY}"]
  http = true
TOML
if ! docker buildx create --name "$BUILDER" --driver docker-container --driver-opt network=host \
  --buildkitd-config "$WORK/buildkitd.toml" --bootstrap > "$WORK/log" 2>&1; then
  echo "could not create the test builder:" >&2
  cat "$WORK/log" >&2
  exit 1
fi

mkdir -p "$WORK/ctx" "$WORK/bin"
printf 'FROM scratch\nCOPY marker /marker\n' > "$WORK/ctx/Dockerfile"
printf '%s\n' "$$" > "$WORK/ctx/marker"

REAL_DOCKER="$(command -v docker)"
cat > "$WORK/bin/docker" <<'SHIM'
#!/usr/bin/env bash
if [ "${1:-}" = "buildx" ] && [ "${2:-}" = "build" ]; then
  echo build >> "$SHIM_CALLS"
fi
exec "$REAL_DOCKER" "$@"
SHIM
chmod +x "$WORK/bin/docker"

# direct_build BUILD_ARGS... runs one build on the test builder, outside the step, and leaves its
# status in BUILD_STATUS.
BUILD_STATUS=0
direct_build() {
  : > "$WORK/requests"
  BUILD_STATUS=0
  docker buildx build --builder "$BUILDER" --tag "$IMAGE" --load "$@" "$WORK/ctx" \
    > "$WORK/log" 2>&1 || BUILD_STATUS=$?
}

# run_step SCRIPT runs the step's script once and leaves its exit status in STEP_STATUS.
STEP_STATUS=0
run_step() {
  : > "$WORK/requests"
  : > "$WORK/output"
  rm -f "$WORK/calls"
  STEP_STATUS=0
  local -a docker_config=()
  if [ -n "${DOCKER_CONFIG:-}" ]; then
    docker_config=("DOCKER_CONFIG=$DOCKER_CONFIG")
  fi
  env -i "${docker_config[@]}" \
    "PATH=$WORK/bin:/usr/local/bin:/usr/bin:/bin" \
    "HOME=$HOME" \
    "BUILDX_BUILDER=$BUILDER" \
    "REAL_DOCKER=$REAL_DOCKER" \
    "SHIM_CALLS=$WORK/calls" \
    "GITHUB_OUTPUT=$WORK/output" \
    "GITHUB_REPOSITORY=acme/app" \
    "ECR_CACHE_REPO=$REPO_URL" \
    "INPUT_CONTEXT=$WORK/ctx" \
    "INPUT_DOCKERFILE=Dockerfile" \
    "INPUT_TAGS=$IMAGE" \
    "INPUT_PUSH=false" \
    "INPUT_BUILD_ARGS=" \
    "INPUT_TARGET=" \
    "INPUT_PLATFORMS=" \
    "INPUT_CACHE_MODE=max" \
    "INPUT_CACHE_TAG=cache-refusal" \
    "INPUT_EXTRA_CACHE_FROM=" \
    "INPUT_EXTRA_CACHE_TO=" \
    bash "$1" > "$WORK/log" 2>&1 || STEP_STATUS=$?
}

calls() { if [ -f "$WORK/calls" ]; then wc -l < "$WORK/calls" | tr -d ' '; else echo 0; fi; }
read_refused() { grep -Eq "^(HEAD|GET) /v2/latchkey-runners/acme/cache/manifests/" "$WORK/requests"; }
write_refused() { grep -q "/v2/latchkey-runners/acme/cache/blobs/" "$WORK/requests"; }
show() {
  echo "status=$1 calls=$(calls)"
  sed 's/^/#   request /' "$WORK/requests"
  sed 's/^/#   /' "$WORK/log"
}

direct_build --cache-from "type=registry,ref=${REF}"
if [ "$BUILD_STATUS" -eq 0 ] && read_refused; then
  pass "buildx treats a cache import the registry refuses with 403 as a miss"
else
  fail "buildx treats a cache import the registry refuses with 403 as a miss" "$(show "$BUILD_STATUS")"
fi

direct_build --cache-to "type=registry,ref=${REF},mode=max"
if [ "$BUILD_STATUS" -ne 0 ] && write_refused; then
  pass "buildx fails the build on a cache export the registry refuses, without ignore-error"
else
  fail "buildx fails the build on a cache export the registry refuses, without ignore-error" \
    "$(show "$BUILD_STATUS")"
fi

direct_build --cache-to "type=registry,ref=${REF},mode=max,ignore-error=true"
if [ "$BUILD_STATUS" -eq 0 ] && write_refused; then
  pass "buildx keeps the build green on a refused cache export with ignore-error=true"
else
  fail "buildx keeps the build green on a refused cache export with ignore-error=true" \
    "$(show "$BUILD_STATUS")"
fi

run_step "$WORK/step.sh"
if [ "$STEP_STATUS" -eq 0 ] && [ "$(calls)" = "1" ] && read_refused && write_refused \
  && ! grep -q '^::warning::Build failed' "$WORK/log" \
  && grep -q '^cache-configured=true$' "$WORK/output"; then
  pass "the step builds once and stays green when the registry refuses the cache both ways"
else
  fail "the step builds once and stays green when the registry refuses the cache both ways" \
    "$(show "$STEP_STATUS")"
fi

run_step "$WORK/mutated.sh"
if [ "$STEP_STATUS" -eq 0 ] && [ "$(calls)" = "2" ] \
  && grep -q '^::warning::Build failed (exit [0-9]*)' "$WORK/log"; then
  pass "without ignore-error the step builds twice, so the case above would catch its removal"
else
  fail "without ignore-error the step builds twice, so the case above would catch its removal" \
    "$(show "$STEP_STATUS")"
fi

echo "# $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
