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
