#!/usr/bin/env bash

_vaio_manifest() {
  python3 "$(dirname "${BASH_SOURCE[0]}")/manifest.py" "$@"
}

begin_run() {
  _vaio_manifest init
}

snapshot_file() {
  _vaio_manifest snapshot "$@"
}

install_owned_file() {
  _vaio_manifest install "$@"
}

install_owned_file_exclusive() {
  _vaio_manifest install-exclusive "$@"
}

install_owned_block() {
  local run=$1 module=$2 target=$3 begin=$4 end=$5 block=$6
  printf '%s' "$block" | _vaio_manifest install-block "$run" "$module" "$target" "$begin" "$end"
}
record_failure() {
  local run=${1:-} module=${2:-} phase=${3:-} exit_code=${4:-}
  [[ $module =~ ^[a-z][a-z0-9_-]{0,63}$ && $phase =~ ^(preflight|preview|apply|verify|rollback)$ &&
    $exit_code =~ ^[1-9][0-9]{0,2}$ ]] || return 2
  ((10#$exit_code <= 255)) || return 2
  _vaio_manifest append "$run" \
    "{\"event\":\"failure\",\"module\":\"$module\",\"phase\":\"$phase\",\"exit_code\":$exit_code}"
}
