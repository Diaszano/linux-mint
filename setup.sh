#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/preflight.sh"
source "$SCRIPT_DIR/lib/packages.sh"
source "$SCRIPT_DIR/lib/memory.sh"
source "$SCRIPT_DIR/lib/gradle.sh"
source "$SCRIPT_DIR/lib/docker.sh"

usage() {
  cat <<'EOF'
Uso: setup.sh [--check | --dry-run] [opções]
  --only LISTA        Seleciona somente módulos separados por vírgula
  --skip LISTA        Ignora módulos separados por vírgula
  --zram              Seleciona zram
  --docker            Seleciona Docker
  --earlyoom          Seleciona earlyoom
  --gradle-global     Seleciona propriedades globais do Gradle
  --swappiness 0..200 Seleciona ajuste de vm.swappiness
  --skip-mise         Ignora mise
  --no-docker         Alias de --skip docker
  --no-earlyoom       Alias de --skip earlyoom
  --yes               Confirma apenas módulos já selecionados
EOF
}

valid_module() {
  case "$1" in
    baseline|kvm|mise|wrappers|zram|docker|earlyoom|gradle-global|swappiness) return 0 ;;
    *) error "Módulo desconhecido: $1"; return 2 ;;
  esac
}

add_modules() {
  local kind=$1 list=$2 module
  local -a modules
  IFS=, read -r -a modules <<< "$list"
  [[ -n $list && $list != ,* && $list != *, && $list != *,,* ]] || { error 'Lista de módulos inválida.'; return 2; }
  for module in "${modules[@]}"; do
    valid_module "$module" || return 2
    if [[ $kind == only ]]; then only[$module]=1; else skip[$module]=1; fi
  done
}

declare -A only=() skip=() selected=()
mode=preview
swappiness=
while (($#)); do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --check|--dry-run)
      if [[ $mode != preview && $mode != "${1#--}" ]]; then
        error '--check e --dry-run são mutuamente exclusivos.'
        exit 2
      fi
      mode=${1#--} ;;
    --only|--skip)
      (($# >= 2)) || { error "Valor ausente para $1"; exit 2; }
      add_modules "${1#--}" "$2" || exit 2
      shift ;;
    --zram|--docker|--earlyoom|--gradle-global) selected[${1#--}]=1 ;;
    --swappiness)
      (($# >= 2)) || { error 'Valor ausente para --swappiness'; exit 2; }
      if [[ ! $2 =~ ^(0|[1-9][0-9]{0,2})$ ]] || ((10#$2 > 200)); then
        error 'Swappiness deve estar entre 0 e 200.'
        exit 2
      fi
      swappiness=$2
      selected[swappiness]=1
      shift ;;
    --skip-mise) skip[mise]=1 ;;
    --no-docker) skip[docker]=1 ;;
    --no-earlyoom) skip[earlyoom]=1 ;;
    --yes) : ;;
    *) error "Opção desconhecida: $1"; exit 2 ;;
  esac
  shift
done

for module in "${!only[@]}" "${!selected[@]}"; do
  if [[ -v skip[$module] ]]; then
    error "Módulo selecionado e ignorado: $module"
    exit 2
  fi
done
if [[ -v only[swappiness] && -z $swappiness ]]; then
  error 'Use --swappiness VALOR para selecionar o ajuste.'
  exit 2
fi

require_normal_user || exit 1
host_facts=$(preflight_host) || exit 1
printf '%s\n' "$host_facts"
preflight_conflicts
[[ $mode == check ]] && exit 0

if ((${#only[@]})); then
  for module in "${!only[@]}"; do selected[$module]=1; done
else
  for module in baseline kvm mise wrappers; do selected[$module]=1; done
fi
for module in "${!skip[@]}"; do unset 'selected[$module]'; done

if [[ -v selected[zram] ]]; then memory_plan --zram || exit 1; fi
if [[ -v selected[earlyoom] ]]; then memory_plan --earlyoom || exit 1; fi
if [[ -v selected[swappiness] ]]; then memory_plan --swappiness "$swappiness" || exit 1; fi
if [[ -v selected[gradle-global] ]]; then gradle_plan --global || exit 1; fi
if [[ -v selected[docker] ]]; then docker_plan || exit 1; fi

printf 'Prévia de operações (nenhuma alteração será feita):\n'
for module in baseline kvm mise wrappers zram docker earlyoom gradle-global swappiness; do
  [[ -v selected[$module] ]] || continue
  printf 'module=%s\n' "$module"
  case "$module" in
    baseline|kvm|zram)
      mapfile -t packages < <(package_selection "$module")
      printf 'packages=%s\n' "${packages[*]}" ;;
  esac
  case "$module" in
    baseline) printf 'command=sudo apt-get install [pacotes básicos após simulação]\n' ;;
    kvm) printf 'command=sudo apt-get install [pacotes KVM após simulação]\n' ;;
    mise) printf 'file=%s/.local/bin/mise\n' "$HOME" ;;
    wrappers) printf 'file=%s/.local/bin/dev-*\n' "$HOME" ;;
    zram) printf 'command=sudo apt-get install zram-tools\nfile=/etc/default/zramswap\n' ;;
    docker) printf 'command=sudo apt-get install [Docker provider packages after preview]\n' ;;
    earlyoom) printf 'availability=unavailable: constrained-build priority is not guaranteed\n' ;;
    gradle-global) printf 'file=%s/gradle.properties\n' "${GRADLE_USER_HOME:-$HOME/.gradle}" ;;
    swappiness) printf 'file=/etc/sysctl.d/[arquivo gerenciado]\nvm.swappiness=%s\n' "$swappiness" ;;
  esac
done
