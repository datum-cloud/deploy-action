#!/usr/bin/env bash
# Deploys a workload to Datum Cloud Compute with `datumctl compute deploy`.
#
# Reads the action inputs from INPUT_* environment variables (see action.yaml),
# writes the `url` and `workload` step outputs to GITHUB_OUTPUT, and appends a
# summary to GITHUB_STEP_SUMMARY. Expects datumctl, signed in, and the compute
# plugin on PATH.
set -euo pipefail

error() {
  echo "::error::$*" >&2
  exit 1
}

# append_lines FLAG VALUE appends --FLAG=LINE to args for each non-blank line
# of VALUE. Values are passed one per line so that they may contain commas.
append_lines() {
  local flag=$1 line
  while IFS= read -r line || [ -n "${line}" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -n "${line}" ] && args+=("--${flag}=${line}")
  done <<<"$2"
  return 0
}

# append_if_set FLAG VALUE appends --FLAG=VALUE when VALUE is not empty, so an
# unset input leaves the workload's current setting in place on a redeploy.
append_if_set() {
  [ -n "$2" ] && args+=("--$1=$2")
  return 0
}

[ -n "${INPUT_PROJECT:-}" ] || error "input 'project' is required"
[ -n "${INPUT_WORKLOAD:-}" ] || error "input 'workload' is required"
[ -n "${INPUT_IMAGE:-}" ] || error "input 'image' is required"

# The name is written to GITHUB_OUTPUT and passed as a positional argument, so
# a newline or a leading '-' must never reach either.
if ! [[ "${INPUT_WORKLOAD}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
  error "input 'workload' must be lowercase letters, digits and '-', starting and ending with a letter or digit"
fi

if [ -z "${INPUT_LOCATIONS:-}${INPUT_CITIES:-}${INPUT_LOCATION_SELECTOR:-}" ]; then
  error "one of 'locations', 'cities' or 'location-selector' is required"
fi

case "${INPUT_HTTP2:-}" in
  '' | true | false) ;;
  *) error "input 'http2' must be 'true', 'false' or empty, got '${INPUT_HTTP2}'" ;;
esac

rollout_timeout="${INPUT_ROLLOUT_TIMEOUT:-15m}"
if ! [[ "${rollout_timeout}" =~ ^[1-9][0-9]*[smhd]?$ ]]; then
  error "input 'rollout-timeout' must be a positive number with an optional s, m, h or d suffix, such as 90s, 15m or 1h, got '${rollout_timeout}'"
fi

args=(compute deploy "${INPUT_WORKLOAD}"
  "--project=${INPUT_PROJECT}"
  "--image=${INPUT_IMAGE}"
  --yes)
append_if_set build "${INPUT_BUILD_CONTEXT:-}"
append_if_set location "${INPUT_LOCATIONS:-}"
append_if_set city "${INPUT_CITIES:-}"
append_if_set location-selector "${INPUT_LOCATION_SELECTOR:-}"
append_if_set http-port "${INPUT_HTTP_PORT:-}"
append_if_set http2 "${INPUT_HTTP2:-}"
append_if_set min "${INPUT_MIN_INSTANCES:-}"
append_if_set max "${INPUT_MAX_INSTANCES:-}"
append_if_set instance-type "${INPUT_INSTANCE_TYPE:-}"
append_if_set runtime-class "${INPUT_RUNTIME_CLASS:-}"
append_if_set network "${INPUT_NETWORK:-}"
append_lines env "${INPUT_ENV:-}"
append_lines env-from-secret "${INPUT_ENV_FROM_SECRETS:-}"
append_lines env-from-configmap "${INPUT_ENV_FROM_CONFIGMAPS:-}"
append_lines secret "${INPUT_SECRET_MOUNTS:-}"
append_lines configmap "${INPUT_CONFIGMAP_MOUNTS:-}"
append_lines label "${INPUT_LABELS:-}"

log=$(mktemp)
trap 'rm -f "${log}"' EXIT

# SIGINT detaches datumctl from the rollout without cancelling it; the rollout
# keeps going on Datum Cloud after the step fails. timeout exits 124 after the
# SIGINT, or 137 when datumctl ignored it and was killed 30s later.
status=0
timeout --signal=INT --kill-after=30s "${rollout_timeout}" \
  datumctl "${args[@]}" 2>&1 | tee "${log}" || status=${PIPESTATUS[0]}

if [ "${status}" -eq 124 ] || [ "${status}" -eq 137 ]; then
  error "the deploy of '${INPUT_WORKLOAD}' did not finish within ${rollout_timeout}; a rollout already started continues on Datum Cloud. Check it with: datumctl compute workloads describe ${INPUT_WORKLOAD} --project ${INPUT_PROJECT}"
elif [ "${status}" -ne 0 ]; then
  error "datumctl compute deploy failed with exit status ${status}"
fi

# A published deploy prints the workload's URL alone on its last line.
url=$(grep -Eo '^[[:space:]]*https://[^[:space:]]+[[:space:]]*$' "${log}" | tail -n1 | tr -d '[:space:]' || true)

{
  echo "workload=${INPUT_WORKLOAD}"
  echo "url=${url}"
} >>"${GITHUB_OUTPUT}"

{
  echo "### Deployed \`${INPUT_WORKLOAD}\` to Datum Cloud"
  echo
  echo "| | |"
  echo "|---|---|"
  echo "| Project | \`${INPUT_PROJECT}\` |"
  echo "| Image | \`${INPUT_IMAGE}\` |"
  if [ -n "${url}" ]; then
    echo "| URL | ${url} |"
  else
    echo "| URL | not published |"
  fi
} >>"${GITHUB_STEP_SUMMARY:-/dev/null}"
