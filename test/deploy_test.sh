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

sessroot="${work}/session"
mkdir -p "${sessroot}/bin" "${sessroot}/home" "${sessroot}/runner-temp"
cat >"${sessroot}/bin/datumctl" <<'EOF2'
#!/usr/bin/env bash
case "$1" in
  login)
    mkdir -p "${HOME}/.datumctl" "${XDG_CONFIG_HOME}/datumctl/service-accounts"
    echo '{"token":"secret"}' >"${HOME}/.datumctl/credentials.json"
    echo '{"private_key":"secret"}' >"${XDG_CONFIG_HOME}/datumctl/service-accounts/key.json"
    ;;
  auth)
    printf 'User              Status\n'
    if ! grep -qx 'sa@example.iam' "${STUB_LOGOUTS}" 2>/dev/null; then
      printf 'sa@example.iam    Active\n'
    fi
    ;;
  logout) echo "$2" >>"${STUB_LOGOUTS}" ;;
  compute) [ "${STUB_MODE:-ok}" = fail ] && exit 3; exit 0 ;;
esac
EOF2
chmod +x "${sessroot}/bin/datumctl"

run_session_with_cleanup() {
  local mode=$1 realhome="${sessroot}/home"
  rm -rf "${realhome}" "${sessroot}/runner-temp" "${sessroot}/logouts"
  mkdir -p "${realhome}" "${sessroot}/runner-temp"
  : >"${sessroot}/out"
  : >"${sessroot}/logouts"
  env -i PATH="${sessroot}/bin:/usr/bin:/bin" HOME="${realhome}" \
    RUNNER_TEMP="${sessroot}/runner-temp" GITHUB_OUTPUT="${sessroot}/out" \
    bash "${root}/scripts/session-start.sh"
  sdir=$(sed -n 's/^dir=//p' "${sessroot}/out")
  stepenv=(env -i PATH="${sessroot}/bin:/usr/bin:/bin" HOME="${sdir}"
    XDG_CONFIG_HOME="${sdir}/.config" STUB_MODE="${mode}" STUB_LOGOUTS="${sessroot}/logouts")
  "${stepenv[@]}" datumctl login
  if [ -z "$(find "${sdir}" -name '*.json' 2>/dev/null)" ]; then
    fail "login wrote no credentials into the session directory"
  fi
  "${stepenv[@]}" datumctl compute deploy || true
  env -i PATH="${sessroot}/bin:/usr/bin:/bin" RUNNER_TEMP="${sessroot}/runner-temp" \
    SESSION_DIR="${sdir}" STUB_LOGOUTS="${sessroot}/logouts" \
    bash "${root}/scripts/session-end.sh" >"${sessroot}/end.log" 2>&1 || fail "session-end.sh failed"
}

for mode in ok fail; do
  current="removes the session after a ${mode} deploy"
  run_session_with_cleanup "${mode}"
  [ ! -e "${sdir}" ] || fail "session directory ${sdir} remains"
  [ -z "$(ls -A "${sessroot}/runner-temp")" ] || fail "runner temp not empty"
  [ -z "$(ls -A "${sessroot}/home")" ] || fail "real HOME was written to"
  grep -qx 'sa@example.iam' "${sessroot}/logouts" || fail "no logout for the signed-in user"
done

current="refuses to remove a directory outside the session area"
mkdir -p "${work}/precious"
status=0
env -i PATH=/usr/bin:/bin RUNNER_TEMP="${sessroot}/runner-temp" SESSION_DIR="${work}/precious" \
  bash "${root}/scripts/session-end.sh" >/dev/null 2>&1 || status=$?
[ "${status}" -ne 0 ] && [ -d "${work}/precious" ] || fail "removed a foreign directory"

current="refuses a session path containing '..'"
mkdir -p "${sessroot}/runner-temp/datum-session.x"
status=0
env -i PATH=/usr/bin:/bin RUNNER_TEMP="${sessroot}/runner-temp" \
  SESSION_DIR="${sessroot}/runner-temp/datum-session.x/../../../${work##*/}" \
  bash "${root}/scripts/session-end.sh" >/dev/null 2>&1 || status=$?
[ "${status}" -ne 0 ] && [ -d "${work}" ] || fail "accepted a path with '..'"

current="requires RUNNER_TEMP when a session is set"
status=0
env -i PATH=/usr/bin:/bin SESSION_DIR="${sessroot}/runner-temp/datum-session.x" \
  bash "${root}/scripts/session-end.sh" >"${work}/log" 2>&1 || status=$?
[ "${status}" -ne 0 ] && [ -d "${sessroot}/runner-temp/datum-session.x" ] || fail "ran without RUNNER_TEMP"
assert_log "RUNNER_TEMP is required"

current="does nothing when no session was started"
env -i PATH=/usr/bin:/bin RUNNER_TEMP="${sessroot}/runner-temp" SESSION_DIR= \
  bash "${root}/scripts/session-end.sh" || fail "failed with no session"

current="passes the runner's Docker config through and never touches it"
dockerhome="${sessroot}/dockerhome"
rm -rf "${dockerhome}" "${sessroot}/runner-temp" "${sessroot}/out"
mkdir -p "${dockerhome}/.docker" "${sessroot}/runner-temp"
echo '{"auths":{"registry.example":{"auth":"c2VjcmV0"}}}' >"${dockerhome}/.docker/config.json"
before=$(cksum <"${dockerhome}/.docker/config.json")
: >"${sessroot}/out"
env -i PATH="${sessroot}/bin:/usr/bin:/bin" HOME="${dockerhome}" \
  RUNNER_TEMP="${sessroot}/runner-temp" GITHUB_OUTPUT="${sessroot}/out" \
  bash "${root}/scripts/session-start.sh"
[ "$(sed -n 's/^docker-config=//p' "${sessroot}/out")" = "${dockerhome}/.docker" ] || fail "docker-config is not the real home's .docker"
sdir=$(sed -n 's/^dir=//p' "${sessroot}/out")
env -i PATH="${sessroot}/bin:/usr/bin:/bin" RUNNER_TEMP="${sessroot}/runner-temp" SESSION_DIR="${sdir}" \
  bash "${root}/scripts/session-end.sh" >/dev/null 2>&1 || fail "session-end failed"
[ "$(cksum <"${dockerhome}/.docker/config.json")" = "${before}" ] || fail "action changed the Docker config"
: >"${sessroot}/out"
env -i PATH="${sessroot}/bin:/usr/bin:/bin" HOME="${dockerhome}" DOCKER_CONFIG="${sessroot}/custom-docker" \
  RUNNER_TEMP="${sessroot}/runner-temp" GITHUB_OUTPUT="${sessroot}/out" \
  bash "${root}/scripts/session-start.sh"
[ "$(sed -n 's/^docker-config=//p' "${sessroot}/out")" = "${sessroot}/custom-docker" ] || fail "an existing DOCKER_CONFIG is not honoured"
awk '/name: Deploy workload/{f=1} /name: End session/{f=0} f&&/^ +DOCKER_CONFIG: [$][{][{] steps.session.outputs.docker-config [}][}]$/{ok=1} END{exit !ok}' "${root}/action.yaml" || fail "Deploy step does not get the passed-through DOCKER_CONFIG"
[ "$(grep -cE '^ +DOCKER_CONFIG: [$][{][{] steps.session.outputs.docker-config [}][}]$' "${root}/action.yaml")" -eq 3 ] || fail "want DOCKER_CONFIG set on 3 steps"
! grep -qE 'docker (login|logout)|rm .*docker' "${root}"/scripts/*.sh || fail "a script writes or removes Docker credentials"

current="wires every datumctl step to the session and ends it on failure"
action="${root}/action.yaml"
[ "$(grep -cE '^ +HOME: [$][{][{] steps.session.outputs.dir [}][}]$' "${action}")" -eq 3 ] || fail "want HOME set on 3 steps"
[ "$(grep -cE '^ +XDG_CONFIG_HOME: [$][{][{] steps.session.outputs.dir [}][}]/.config$' "${action}")" -eq 3 ] || fail "want XDG_CONFIG_HOME set on 3 steps"
awk '/name: End session/{f=1} f&&/if: always\(\)/{ok=1} END{exit !ok}' "${action}" || fail "End session lacks if: always()"
awk '/name: End session/{f=1} f&&/session-end.sh/{ok=1} END{exit !ok}' "${action}" || fail "End session does not run session-end.sh"

current="signs in again before the e2e destroy"
e2e="${root}/.github/workflows/e2e.yaml"
awk '/setup-datumctl-action@/{s=NR} /datumctl compute destroy/{d=NR} END{exit !(s && d && s < d)}' "${e2e}" || fail "e2e destroys without signing in"

if [ "${failures}" -gt 0 ]; then
  echo "${failures} assertion(s) failed" >&2
  exit 1
fi
echo "all deploy.sh tests passed"
