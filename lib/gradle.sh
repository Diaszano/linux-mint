#!/usr/bin/env bash

_GRADLE_LIB=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/backup.sh
source "$_GRADLE_LIB/backup.sh"

_GRADLE_BEGIN='# >>> vaio-fe16 gradle >>>'
_GRADLE_END='# <<< vaio-fe16 gradle <<<'
_GRADLE_BLOCK=$'# >>> vaio-fe16 gradle >>>\norg.gradle.jvmargs=-Xmx3g -XX:MaxMetaspaceSize=768m\norg.gradle.workers.max=4\norg.gradle.caching=true\norg.gradle.daemon.idletimeout=900000\n# <<< vaio-fe16 gradle <<<\n'

_gradle_fail() {
  printf 'Erro: %s\n' "$1" >&2
  return 1
}

_gradle_safe_path() {
  local path=$1 owner mode uid=$EUID
  while :; do
    read -r owner mode < <(stat -Lc '%u %a' -- "$path") || return 1
    [[ $owner == "$uid" || $owner == 0 ]] || {
      _gradle_fail 'um diretório no caminho do Gradle pertence a outro usuário.'
      return 1
    }
    [[ $mode =~ ^[0-7]+$ ]] && (((8#$mode & 0022) == 0 || (8#$mode & 01000) != 0)) || {
      _gradle_fail 'um diretório no caminho do Gradle tem permissões inseguras.'
      return 1
    }
    [[ $path == / ]] && return 0
    path=${path%/*}
    [[ -n $path ]] || path=/
  done
}

_gradle_state() {
  local mode
  _GRADLE_HOME_DIR=${GRADLE_USER_HOME:-$HOME/.gradle}
  [[ $_GRADLE_HOME_DIR == /* && $_GRADLE_HOME_DIR != *$'\n'* ]] || {
    _gradle_fail 'GRADLE_USER_HOME deve ser um caminho absoluto.'
    return 1
  }
  if [[ -d $_GRADLE_HOME_DIR && ! -L $_GRADLE_HOME_DIR ]]; then
    [[ -O $_GRADLE_HOME_DIR ]] || {
      _gradle_fail 'GRADLE_USER_HOME pertence a outro usuário.'
      return 1
    }
    _GRADLE_HOME_DIR=$(realpath -e -- "$_GRADLE_HOME_DIR") || return 1
    _gradle_safe_path "$_GRADLE_HOME_DIR" || return 1
    mode=$(stat -c '%a' -- "$_GRADLE_HOME_DIR") || return 1
    [[ $mode =~ ^[0-7]+$ ]] && (((8#$mode & 0022) == 0)) || {
      _gradle_fail 'GRADLE_USER_HOME tem permissões inseguras.'
      return 1
    }
  elif [[ -e $_GRADLE_HOME_DIR || -L $_GRADLE_HOME_DIR ]]; then
    _gradle_fail 'GRADLE_USER_HOME não é um diretório seguro.'
    return 1
  fi
  _GRADLE_TARGET=$_GRADLE_HOME_DIR/gradle.properties
  _GRADLE_BEFORE=missing
  _GRADLE_IDENTITY=missing
  if [[ -e $_GRADLE_TARGET || -L $_GRADLE_TARGET ]]; then
    [[ -f $_GRADLE_TARGET && ! -L $_GRADLE_TARGET && -O $_GRADLE_TARGET ]] || {
      _gradle_fail 'gradle.properties deve ser um arquivo regular pertencente ao usuário.'
      return 1
    }
    mode=$(stat -c '%a' -- "$_GRADLE_TARGET") || return 1
    [[ $mode =~ ^[0-7]+$ ]] && (((8#$mode & 0022) == 0)) || {
      _gradle_fail 'gradle.properties tem permissões inseguras.'
      return 1
    }
    _GRADLE_BEFORE=$(sha256sum -- "$_GRADLE_TARGET") || return 1
    _GRADLE_BEFORE=${_GRADLE_BEFORE%% *}
    _GRADLE_IDENTITY=$(stat -c '%u:%g:%a:%i:%Y:%Z' -- "$_GRADLE_TARGET") || return 1
  fi
  _GRADLE_TOKEN=$(printf '%s\0' "$_GRADLE_TARGET" "$_GRADLE_BEFORE" "$_GRADLE_IDENTITY" | sha256sum)
  _GRADLE_TOKEN=${_GRADLE_TOKEN%% *}
}

_gradle_conflicts() {
  [[ $_GRADLE_BEFORE != missing ]] || return 0
  local starts=0 ends=0 in_block=0 line existing expected
  local pattern='^[[:space:]]*org(\\)?[.]gradle(\\)?[.](jvmargs|workers(\\)?[.]max|caching|daemon(\\)?[.]idletimeout)[[:space:]]*([=:]|[[:space:]])'
  while IFS= read -r line || [[ -n $line ]]; do
    if [[ $line == "$_GRADLE_BEGIN" ]]; then
      starts=$((starts + 1))
      ((starts == 1)) || {
        _gradle_fail 'marcadores Gradle duplicados.'
        return 1
      }
      in_block=1
      continue
    fi
    if [[ $line == "$_GRADLE_END" ]]; then
      ends=$((ends + 1))
      ((ends == 1 && in_block == 1)) || {
        _gradle_fail 'bloco Gradle malformado.'
        return 1
      }
      in_block=0
      continue
    fi
    ((in_block == 0)) || continue
    if [[ $line =~ $pattern ]]; then
      _gradle_fail 'propriedade Gradle conflitante fora do bloco gerenciado.'
      return 1
    fi
  done <"$_GRADLE_TARGET"
  ((starts == ends && in_block == 0)) || {
    _gradle_fail 'bloco Gradle malformado.'
    return 1
  }
  if ((starts == 1)); then
    existing=$(awk -v begin="$_GRADLE_BEGIN" -v end="$_GRADLE_END" '$0 == begin { in_block=1 } in_block { print } $0 == end { exit }' "$_GRADLE_TARGET")
    expected=${_GRADLE_BLOCK%$'\n'}
    [[ $existing == "$expected" ]] || {
      _gradle_fail 'bloco Gradle gerenciado foi editado; revisão manual necessária.'
      return 1
    }
  fi
}

gradle_plan() {
  case ${1:-} in
  '')
    (($# == 0)) || return 2
    printf 'Dica por projeto: use dev-build ./gradlew assembleDebug --no-daemon\n'
    printf 'Nenhum arquivo Gradle será alterado por esta recomendação.\n'
    ;;
  --global)
    (($# == 1)) || return 2
    _gradle_state || return 1
    _gradle_conflicts || return 1
    GRADLE_PLAN_TOKEN=$_GRADLE_TOKEN
    printf 'Prévia global: %s\n' "$_GRADLE_TARGET"
    printf '%s' "$_GRADLE_BLOCK"
    printf 'plan_token=%s\n' "$GRADLE_PLAN_TOKEN"
    ;;
  *)
    _gradle_fail 'opção gradle_plan inválida.'
    return 2
    ;;
  esac
}

gradle_global_apply() {
  local run=${1:-} token=${4:-} temporary
  [[ $# -eq 4 && ${2:-} == --gradle-global && ${3:-} == --confirmed && -n $token ]] || {
    _gradle_fail 'aplicação exige --gradle-global e confirmação do token da prévia.'
    return 2
  }
  [[ $run =~ ^[0-9]{20}-[0-9a-f]{16}$ ]] || {
    _gradle_fail 'identificador de execução inválido.'
    return 2
  }
  _gradle_state || return 1
  _gradle_conflicts || return 1
  [[ $token == "$_GRADLE_TOKEN" ]] || {
    _gradle_fail 'Gradle mudou após a prévia; gere e confirme uma nova prévia.'
    return 1
  }
  [[ -d $_GRADLE_HOME_DIR && ! -L $_GRADLE_HOME_DIR ]] || {
    _gradle_fail 'crie GRADLE_USER_HOME antes de aplicar as propriedades globais.'
    return 1
  }
  if [[ $_GRADLE_BEFORE == missing ]]; then
    temporary=$(mktemp "${TMPDIR:-/tmp}/vaio-gradle.XXXXXXXXXX") || return 1
    printf '%s' "$_GRADLE_BLOCK" >"$temporary"
    chmod 600 -- "$temporary"
    local result=0
    install_owned_file_exclusive "$run" gradle "$temporary" "$_GRADLE_TARGET" || result=$?
    rm -f -- "$temporary"
    return "$result"
  fi
  install_owned_block "$run" gradle "$_GRADLE_TARGET" "$_GRADLE_BEGIN" "$_GRADLE_END" "$_GRADLE_BLOCK"
}
