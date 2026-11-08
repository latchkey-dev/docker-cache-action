#!/usr/bin/env bash
# Runs the action's build step, as action.yml carries it, against a stub docker that records its
# arguments, and reads the registry cache tag the step hands to --cache-from and --cache-to.
#
#   bash test/cache-tag.test.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTION="$ROOT/action.yml"
WORK="$(mktemp -d)"
# The step's own tools, with and without its digest tools, for runners that lack them.
NOTOOLS=(bash tr sort paste mktemp rm)
NOSHA_TOOLS=("${NOTOOLS[@]}" shasum)
cleanup() {
  local tool
  for tool in "${NOSHA_TOOLS[@]}"; do
    rm -f "$WORK/nosha/$tool" "$WORK/notools/$tool"
  done
  rm -f "$WORK/step.sh" "$WORK/argv" "$WORK/output" "$WORK/log" "$WORK/calls" "$WORK/bin/docker"
  rmdir "$WORK/nosha" "$WORK/notools" "$WORK/bin" "$WORK" 2>/dev/null || true
}
trap cleanup EXIT

REPO_URL='registry.example/latchkey-runners/workspace/cache'
FAILED=0
PASSED=0

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

# GitHub passes an unset input as its declared default, so each case starts from action.yml's.
input_default() {
  awk -v name="  $1:" '
    $0 == name { found = 1; next }
    found && /^  [^ ]/ { exit }
    found && /^    default:/ {
      sub(/^    default: */, "")
      gsub(/^'\''|'\''$/, "")
      print
      exit
    }
  ' "$ACTION"
}

mkdir -p "$WORK/bin"
cat > "$WORK/bin/docker" <<'STUB'
#!/usr/bin/env bash
calls=$(( $(cat "$STUB_CALLS" 2>/dev/null || echo 0) + 1 ))
echo "$calls" > "$STUB_CALLS"
printf '%s\n' "$@" > "$STUB_ARGV"
# BuildKit fails the build on a cache export the registry refuses unless the export carries
# ignore-error=true; test/registry-refusal.test.sh holds the real buildx to that.
if [ "${STUB_REFUSE_EXPORT:-}" = "true" ]; then
  prev=""
  for arg in "$@"; do
    if [ "$prev" = "--cache-to" ] && [[ "$arg" == *"ref=${STUB_REPO}:"* ]]; then
      echo "ERROR: failed to push ${arg}: unexpected status: 403 Forbidden" >&2
      [[ ",${arg}," == *",ignore-error=true,"* ]] || exit 1
    fi
    prev=$arg
  done
fi
if [ "${STUB_FAIL_FIRST:-}" = "true" ] && [ "$calls" -eq 1 ]; then
  exit "${STUB_FAIL_CODE:-1}"
fi
exit 0
STUB
chmod +x "$WORK/bin/docker"

# run_step NAME=VALUE ... runs the step once with those inputs over the defaults, and leaves its
# exit status in STEP_STATUS.
STEP_STATUS=0
run_step() {
  : > "$WORK/argv"
  : > "$WORK/output"
  rm -f "$WORK/calls"
  local -a vars=(
    "PATH=$WORK/bin:/usr/local/bin:/usr/bin:/bin"
    "GITHUB_OUTPUT=$WORK/output"
    "GITHUB_REPOSITORY=acme/app"
    "ECR_CACHE_REPO=$REPO_URL"
    "STUB_ARGV=$WORK/argv"
    "STUB_CALLS=$WORK/calls"
    "STUB_REPO=$REPO_URL"
    "INPUT_CONTEXT=$(input_default context)"
    "INPUT_DOCKERFILE=$(input_default dockerfile)"
    "INPUT_TAGS=app:ci"
    "INPUT_PUSH=$(input_default push)"
    "INPUT_BUILD_ARGS=$(input_default build-args)"
    "INPUT_TARGET=$(input_default target)"
    "INPUT_PLATFORMS=$(input_default platforms)"
    "INPUT_CACHE_MODE=$(input_default cache-mode)"
    "INPUT_CACHE_TAG=$(input_default cache-tag)"
    "INPUT_EXTRA_CACHE_FROM=$(input_default extra-cache-from)"
    "INPUT_EXTRA_CACHE_TO=$(input_default extra-cache-to)"
  )
  local status=0
  env -i "${vars[@]}" "$@" bash "$WORK/step.sh" > "$WORK/log" 2>&1 || status=$?
  if [ "$status" -ne 0 ]; then
    echo "the step exited $status:" >&2
    cat "$WORK/log" >&2
  fi
  STEP_STATUS=$status
  return 0
}

# The value after each --cache-from / --cache-to that points at the workspace repository.
ref_after() {
  awk -v flag="$1" 'prev == flag { print } { prev = $0 }' "$WORK/argv" | grep "ref=${REPO_URL}:" || true
}

# tag_for NAME=VALUE ... prints the tag the step reads and writes, or fails the case.
tag_for() {
  run_step "$@"
  local from to from_tag to_tag
  from=$(ref_after --cache-from)
  to=$(ref_after --cache-to)
  from_tag=${from#type=registry,ref="${REPO_URL}":}
  to_tag=${to#type=registry,ref="${REPO_URL}":}
  to_tag=${to_tag%%,*}
  if [ -z "$from" ] || [ -z "$to" ] || [ "$from_tag" != "$to_tag" ]; then
    echo "no matching registry cache refs (from='$from' to='$to')" >&2
    return 1
  fi
  printf '%s\n' "$from_tag"
}

pass() { PASSED=$((PASSED + 1)); echo "ok - $1"; }
fail() { FAILED=$((FAILED + 1)); echo "not ok - $1: $2"; }

expect_same() {
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "'$2' != '$3'"; fi
}
expect_differ() {
  if [ -n "$2" ] && [ "$2" != "$3" ]; then pass "$1"; else fail "$1" "both '$2'"; fi
}

default_tag=$(tag_for)

if [[ "$default_tag" =~ ^cache-[0-9a-f]{16}$ ]]; then
  pass "the default tag is derived, starts with cache and is a valid image tag"
else
  fail "the default tag is derived, starts with cache and is a valid image tag" "'$default_tag'"
fi

# A change to the derivation moves every workspace's cache once, so its output is pinned.
expect_same "the derivation of the default inputs is pinned" "$default_tag" "cache-0da7753b9a0dbcaa"

expect_same "the same image derives the same tag on every run" "$default_tag" "$(tag_for)"

expect_differ "two contexts on the default Dockerfile derive two tags" \
  "$(tag_for INPUT_CONTEXT=api)" "$(tag_for INPUT_CONTEXT=web)"

expect_differ "two Dockerfiles in one context derive two tags" \
  "$(tag_for INPUT_DOCKERFILE=Dockerfile)" "$(tag_for INPUT_DOCKERFILE=Dockerfile.worker)"

expect_differ "the joined path, not the dockerfile input alone, enters the tag" \
  "$(tag_for INPUT_CONTEXT=api INPUT_DOCKERFILE=Dockerfile)" \
  "$(tag_for INPUT_CONTEXT=. INPUT_DOCKERFILE=Dockerfile)"

expect_differ "two repositories in one workspace derive two tags" \
  "$(tag_for GITHUB_REPOSITORY=acme/api)" "$(tag_for GITHUB_REPOSITORY=acme/web)"

expect_differ "two targets of one Dockerfile derive two tags" \
  "$(tag_for INPUT_TARGET=test)" "$(tag_for INPUT_TARGET=release)"

expect_differ "two platforms of one Dockerfile derive two tags" \
  "$(tag_for INPUT_PLATFORMS=linux/amd64)" "$(tag_for INPUT_PLATFORMS=linux/arm64)"

expect_same "the order and spacing of a platform list do not change the tag" \
  "$(tag_for INPUT_PLATFORMS=linux/amd64,linux/arm64)" \
  "$(tag_for 'INPUT_PLATFORMS=linux/arm64, linux/amd64')"

expect_same "build arguments do not enter the tag" \
  "$(tag_for INPUT_BUILD_ARGS=GIT_SHA=1111111)" "$(tag_for INPUT_BUILD_ARGS=GIT_SHA=2222222)"

if command -v shasum >/dev/null 2>&1; then
  mkdir -p "$WORK/nosha"
  for tool in "${NOSHA_TOOLS[@]}"; do
    ln -sf "$(command -v "$tool")" "$WORK/nosha/$tool"
  done
  expect_same "a runner without sha256sum derives the same tag through shasum" \
    "$(tag_for "PATH=$WORK/bin:$WORK/nosha")" "$default_tag"
else
  echo "skip - shasum is not installed here"
fi

mkdir -p "$WORK/notools"
for tool in "${NOTOOLS[@]}"; do
  ln -sf "$(command -v "$tool")" "$WORK/notools/$tool"
done
notools_tag=$(tag_for "PATH=$WORK/bin:$WORK/notools")
if [ "$notools_tag" = "cache" ] && grep -q '^::warning::No sha256sum or shasum' "$WORK/log"; then
  pass "a runner with no digest tool warns and keeps the shared tag rather than an empty digest"
else
  fail "a runner with no digest tool warns and keeps the shared tag rather than an empty digest" \
    "'$notools_tag'"
fi

run_step 'INPUT_BUILD_ARGS=TOKEN=s3cr3t-value'
if grep -q 's3cr3t-value' "$WORK/log"; then
  fail "a build argument value stays out of the log" "found in the log"
else
  pass "a build argument value stays out of the log"
fi

expect_same "a set cache-tag is used as given" "$(tag_for INPUT_CACHE_TAG=cache-api)" "cache-api"

run_step INPUT_CACHE_TAG=cache-api
if grep -q "ref=${REPO_URL}:cache-api,mode=max" "$WORK/argv"; then
  pass "the cache is written with the cache-mode input"
else
  fail "the cache is written with the cache-mode input" "$(tr '\n' ' ' < "$WORK/argv")"
fi

run_step ECR_CACHE_REPO=
if grep -q -- '--cache-from' "$WORK/argv" || ! grep -q '^cache-configured=false$' "$WORK/output"; then
  fail "with no cache repository the build runs with no cache flags" "$(cat "$WORK/output")"
else
  pass "with no cache repository the build runs with no cache flags"
fi

run_step STUB_REFUSE_EXPORT=true
if [ "$STEP_STATUS" -eq 0 ] && [ "$(cat "$WORK/calls")" = "1" ] && [ -n "$(ref_after --cache-to)" ] \
  && ! grep -q '^::warning::Build failed' "$WORK/log" \
  && grep -q '^cache-configured=true$' "$WORK/output"; then
  pass "a cache export the registry refuses with 403 leaves the build green and runs it once"
else
  fail "a cache export the registry refuses with 403 leaves the build green and runs it once" \
    "status=$STEP_STATUS calls=$(cat "$WORK/calls")"
fi

run_step STUB_FAIL_FIRST=true STUB_FAIL_CODE=7
if [ "$STEP_STATUS" -eq 0 ] && [ "$(cat "$WORK/calls")" = "2" ] \
  && ! grep -q -- '--cache-from' "$WORK/argv" && ! grep -q -- '--cache-to' "$WORK/argv" \
  && grep -q '^cache-configured=false$' "$WORK/output"; then
  pass "a failed cached build is retried once without the cache"
else
  fail "a failed cached build is retried once without the cache" \
    "status=$STEP_STATUS calls=$(cat "$WORK/calls")"
fi
retry_warning='::warning::Build failed (exit 7) with the layer cache on; building again without it.'
if grep -Fxq "$retry_warning" "$WORK/log" && [ "$(grep -c '^::warning::' "$WORK/log")" = "1" ]; then
  pass "the retry warning carries the build's exit code and names no cause"
else
  fail "the retry warning carries the build's exit code and names no cause" \
    "$(grep '^::warning::' "$WORK/log" || echo 'no warning')"
fi

echo "# $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
