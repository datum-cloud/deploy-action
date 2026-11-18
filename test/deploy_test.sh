#!/usr/bin/env bash
# Tests scripts/deploy.sh against a stub datumctl that records its arguments.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
script="${root}/scripts/deploy.sh"
work=$(mktemp -d)
trap 'rm -rf "${work}"' EXIT

mkdir -p "${work}/bin"
cat >"${work}/bin/datumctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"${STUB_ARGS}"
case "${STUB_MODE:-ok}" in
  ok) printf 'Waiting for rollout.\n\nPublishing...\n\n  https://api-abc123.datumproxy.net\n' ;;
  no-url) printf 'Waiting for rollout.\n' ;;
  fail) echo 'Error: quota exceeded' >&2; exit 3 ;;
  hang) exec sleep 30 ;;
esac
EOF
chmod +x "${work}/bin/datumctl"

failures=0
fail() {
  echo "FAIL: ${current}: $*" >&2
  failures=$((failures + 1))
}

# run executes deploy.sh with the base inputs plus the given VAR=VALUE
# overrides, capturing its status, combined output, outputs and arguments.
run() {
  : >"${work}/output"
  : >"${work}/summary"
  rm -f "${work}/args"
  status=0
  env -i PATH="${work}/bin:/usr/bin:/bin" \
    STUB_ARGS="${work}/args" \
    GITHUB_OUTPUT="${work}/output" \
    GITHUB_STEP_SUMMARY="${work}/summary" \
    INPUT_PROJECT=demo-project \
    INPUT_WORKLOAD=api \
    INPUT_IMAGE=ghcr.io/example/api:1.0.0 \
    INPUT_CITIES=DFW \
    INPUT_ROLLOUT_TIMEOUT=15m \
    "$@" \
    bash "${script}" >"${work}/log" 2>&1 || status=$?
}

assert_status() { [ "${status}" -eq "$1" ] || fail "status ${status}, want $1; log: $(cat "${work}/log")"; }
assert_arg() { grep -qxF -- "$1" "${work}/args" || fail "missing argument '$1'"; }
refute_arg() { ! grep -qE -- "$1" "${work}/args" || fail "unexpected argument matching '$1'"; }
assert_output() { grep -qxF -- "$1" "${work}/output" || fail "missing output '$1'"; }
assert_log() { grep -qF -- "$1" "${work}/log" || fail "log lacks '$1'"; }
refute_called() { [ ! -e "${work}/args" ] || fail "datumctl was called"; }

current="deploys with required inputs and reports the URL"
run
assert_status 0
assert_arg compute
assert_arg deploy
assert_arg api
assert_arg --project=demo-project
assert_arg --image=ghcr.io/example/api:1.0.0
assert_arg --city=DFW
assert_arg --yes
refute_arg '^--(http2|min|max|http-port|instance-type|runtime-class|network|build)'
assert_output url=https://api-abc123.datumproxy.net
assert_output workload=api
grep -qF 'https://api-abc123.datumproxy.net' "${work}/summary" || fail "summary lacks URL"

current="passes each line of multi-line inputs as one flag"
run INPUT_ENV=$'LOG_LEVEL=debug\n\n  ORIGINS=a.example,b.example  \nOLD-' \
  INPUT_LABELS=$'team=platform\ntier=api' \
  INPUT_ENV_FROM_SECRETS='api-keys:SECRET_' \
  INPUT_SECRET_MOUNTS='tls:/etc/tls' \
  INPUT_CONFIGMAP_MOUNTS='app:/etc/app' \
  INPUT_ENV_FROM_CONFIGMAPS='app-config'
assert_status 0
assert_arg --env=LOG_LEVEL=debug
assert_arg --env=ORIGINS=a.example,b.example
assert_arg --env=OLD-
assert_arg --label=team=platform
assert_arg --label=tier=api
assert_arg --env-from-secret=api-keys:SECRET_
assert_arg --env-from-configmap=app-config
assert_arg --secret=tls:/etc/tls
assert_arg --configmap=app:/etc/app
[ "$(grep -c '^--env=' "${work}/args")" -eq 3 ] || fail "want 3 --env flags"

current="passes optional scalar inputs"
run INPUT_HTTP_PORT=8080 INPUT_HTTP2=true INPUT_MIN_INSTANCES=2 INPUT_MAX_INSTANCES=5 \
  INPUT_INSTANCE_TYPE=datumcloud-d1-standard-2 INPUT_RUNTIME_CLASS=general-purpose \
  INPUT_NETWORK=backend INPUT_BUILD_CONTEXT=./api INPUT_LOCATIONS=us-east-1,eu-west-1 \
  INPUT_LOCATION_SELECTOR='topology.datum.net/region in (us-east-1)'
assert_status 0
assert_arg --http-port=8080
assert_arg --http2=true
assert_arg --min=2
assert_arg --max=5
assert_arg --instance-type=datumcloud-d1-standard-2
assert_arg --runtime-class=general-purpose
assert_arg --network=backend
assert_arg --build=./api
assert_arg --location=us-east-1,eu-west-1
assert_arg '--location-selector=topology.datum.net/region in (us-east-1)'

current="passes an explicit http2=false so HTTP/2 can be switched off"
run INPUT_HTTP2=false
assert_status 0
assert_arg --http2=false

current="reports an empty URL when the workload is not published"
run STUB_MODE=no-url
assert_status 0
assert_output url=
grep -qF 'not published' "${work}/summary" || fail "summary lacks 'not published'"

current="requires a location"
run INPUT_CITIES=
assert_status 1
assert_log "one of 'locations', 'cities' or 'location-selector' is required"
refute_called

current="requires an image"
run INPUT_IMAGE=
assert_status 1
assert_log "input 'image' is required"
refute_called

current="rejects a workload name that is not a DNS label"
for name in $'api\nurl=https://evil.example' '--help' 'API' 'api-'; do
  run INPUT_WORKLOAD="${name}"
  assert_status 1
  assert_log "input 'workload' must be lowercase letters"
  refute_called
done

current="rejects a non-boolean http2"
run INPUT_HTTP2=yes
assert_status 1
assert_log "input 'http2' must be 'true', 'false' or empty"
refute_called

current="rejects a malformed rollout timeout"
run INPUT_ROLLOUT_TIMEOUT=10minutes
assert_status 1
assert_log "input 'rollout-timeout' must be a positive number"
refute_called

current="fails when datumctl fails"
run STUB_MODE=fail
assert_status 1
assert_log "Error: quota exceeded"
assert_log "datumctl compute deploy failed with exit status 3"
[ ! -s "${work}/output" ] || fail "outputs written after a failed deploy"

current="fails when the rollout exceeds the timeout"
run STUB_MODE=hang INPUT_ROLLOUT_TIMEOUT=1s
assert_status 1
assert_log "did not finish within 1s"
[ ! -s "${work}/output" ] || fail "outputs written after a timed-out deploy"

if [ "${failures}" -gt 0 ]; then
  echo "${failures} assertion(s) failed" >&2
  exit 1
fi
echo "all deploy.sh tests passed"
