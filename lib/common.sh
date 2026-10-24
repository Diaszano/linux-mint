#!/usr/bin/env bash

error() {
  printf 'Erro: %s\n' "$*" >&2
}

require_normal_user() {
  if [[ $(id -u) == 0 ]]; then
    error 'Execute como usuário comum, não como root.'
    return 1
  fi
}
