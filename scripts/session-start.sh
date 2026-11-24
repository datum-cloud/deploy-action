#!/usr/bin/env bash
set -euo pipefail

: "${RUNNER_TEMP:?RUNNER_TEMP is required}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

dir=$(mktemp -d "${RUNNER_TEMP%/}/datum-session.XXXXXX")
chmod 700 "${dir}"
mkdir -p "${dir}/.config"

{
  echo "dir=${dir}"
  echo "docker-config=${DOCKER_CONFIG:-${HOME}/.docker}"
} >>"${GITHUB_OUTPUT}"
