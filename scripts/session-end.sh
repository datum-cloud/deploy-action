#!/usr/bin/env bash
set -uo pipefail

dir="${SESSION_DIR:-}"
[ -n "${dir}" ] || exit 0

: "${RUNNER_TEMP:?RUNNER_TEMP is required}"

case "${dir}" in
  *..*)
    echo "::error::refusing to remove '${dir}': path contains '..'" >&2
    exit 1
    ;;
  "${RUNNER_TEMP%/}"/datum-session.*) ;;
  *)
    echo "::error::refusing to remove '${dir}': not a session directory under RUNNER_TEMP" >&2
    exit 1
    ;;
esac

session_users() {
  HOME="${dir}" XDG_CONFIG_HOME="${dir}/.config" timeout 60s datumctl auth list 2>/dev/null |
    awk 'NR > 1 && NF > 0 { print $1 }'
}

if [ -d "${dir}" ] && command -v datumctl >/dev/null 2>&1; then
  users=$(session_users) || users=
  for user in ${users}; do
    HOME="${dir}" XDG_CONFIG_HOME="${dir}/.config" timeout 60s datumctl logout "${user}" >/dev/null 2>&1 || true
  done
fi

rm -rf "${dir}"
if [ -e "${dir}" ]; then
  echo "::error::could not remove the Datum Cloud session directory" >&2
  exit 1
fi
