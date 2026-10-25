#!/usr/bin/env bash

error() {
  printf 'Error: %s\n' "$*" >&2
}

require_normal_user() {
  if [[ $(id -u) == 0 ]]; then
    error 'Run as a regular user, not as root.'
    return 1
  fi
}

manual_recovery_notice() {
  local run=${1:-} rollback_command=${2:-dev-rollback}
  [[ $run =~ ^[0-9]{20}-[0-9a-f]{16}$ ]] || return 2
  printf -v rollback_command '%q' "$rollback_command"
  printf 'run_id=%s\n' "$run" >&2
  printf 'manual_recovery=%s %q --dry-run, then review the manifest before any rollback apply\n' \
    "$rollback_command" "$run" >&2
}
