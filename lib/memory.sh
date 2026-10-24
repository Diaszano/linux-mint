#!/usr/bin/env bash

_MEMORY_LIB=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

_memory_fail() {
  printf 'Erro: %s\n' "$1" >&2
  return 1
}

_memory_inventory() {
  declare -F preflight_install_inventory >/dev/null || source "$_MEMORY_LIB/preflight.sh"
  preflight_install_inventory || {
    _memory_fail 'inventário de memória indeterminado; nenhuma alteração aplicada.'
    return 1
  }
  [[ ${PREFLIGHT_PACKAGES_STATE:-unknown} == known ]] || {
    _memory_fail 'inventário de pacotes indeterminado.'
    return 1
  }
  [[ ${PREFLIGHT_SERVICES:-} != *unknown* && ${PREFLIGHT_CONFLICT_SERVICES:-} != *unknown* ]] || {
    _memory_fail 'inventário de serviços indeterminado.'
    return 1
  }
}

_memory_package_contract() {
  local module=$1 candidate
  case $module in
  zram)
    candidate=$(apt-cache policy zram-tools 2>/dev/null) || return 1
    [[ $candidate == *'Candidate: 0.3.3.1-1.1'* ]] || _memory_fail 'pacote zram-tools não revisado; configure manualmente.'
    ;;
  earlyoom)
    candidate=$(apt-cache policy earlyoom 2>/dev/null) || return 1
    [[ $candidate == *'Candidate: 1.7-2'* ]] || _memory_fail 'pacote earlyoom não revisado; configure manualmente.'
    ;;
  *) return 1 ;;
  esac
}

_memory_has_zram() {
  local device type size priority extra
  [[ ${PREFLIGHT_ZRAM:-} == *zram* ]] || return 1
  while read -r device type size priority extra; do
    if [[ -n $extra && $size =~ ^[0-9]+([.,][0-9]+)?[KMGTPEB]?$ && $priority =~ ^[0-9]+([.,][0-9]+)?[KMGTPEB]?$ && $extra =~ ^-?[0-9]+$ ]]; then
      priority=$extra
      extra=''
    fi
    [[ $device == /dev/zram* && -n $type && $size =~ ^[0-9]+([.,][0-9]+)?[KMGTPEB]?$ && $priority =~ ^-?[0-9]+$ && -z $extra ]] && return 0
  done <<<"${PREFLIGHT_SWAPS:-}"
  return 1
}

_memory_zram_capable() {
  modprobe -n zram >/dev/null 2>&1 || [[ -d /sys/module/zram ]]
}

_memory_conflict() {
  local module=$1 evidence=${PREFLIGHT_CONFLICT_SERVICES,,} package status device type size priority extra
  while IFS=$'\t' read -r package status _; do
    [[ $status == *' ok installed' ]] || continue
    case "$module:$package" in
    zram:*zram* | zram:*zswap* | zram:systemd-swap | zram:swapspace | zram:dphys-swapfile)
      _memory_fail "gerenciador de swap existente impede zram: $package" || return 1
      ;;
    earlyoom:earlyoom | earlyoom:systemd-oomd | earlyoom:oomd | earlyoom:nohang | earlyoom:low-memory-monitor)
      _memory_fail "gerenciador OOM existente impede earlyoom: $package" || return 1
      ;;
    esac
  done <<<"${PREFLIGHT_PACKAGES:-}"
  case $module in
  zram)
    [[ -z ${PREFLIGHT_ZRAM:-} ]] || {
      _memory_fail 'zram existente; preserve a configuração atual.'
      return 1
    }
    [[ ${PREFLIGHT_SWAPS,,} != *zram* ]] || {
      _memory_fail 'swap zram ativo; preserve a configuração atual.'
      return 1
    }
    [[ $evidence != *zram* && $evidence != *swap-policy* ]] || {
      _memory_fail 'unidade ou política zram existente; preserve a configuração atual.'
      return 1
    }
    while read -r device type size priority extra; do
      [[ -n $device && $device != none ]] || continue
      if [[ -n $extra && $size =~ ^[0-9]+([.,][0-9]+)?[KMGTPEB]?$ && $priority =~ ^[0-9]+([.,][0-9]+)?[KMGTPEB]?$ && $extra =~ ^-?[0-9]+$ ]]; then
        priority=$extra
        extra=''
      fi
      [[ $device == /* && -n $type && $size =~ ^[0-9]+([.,][0-9]+)?[KMGTPEB]?$ && $priority =~ ^-?[0-9]+$ && -z $extra ]] || {
        _memory_fail 'estado do swap indeterminado.'
        return 1
      }
      ((priority < 100)) || {
        _memory_fail 'prioridade de swap existente impede zram.'
        return 1
      }
    done <<<"${PREFLIGHT_SWAPS:-}"
    ;;
  earlyoom)
    [[ $evidence != *earlyoom* && $evidence != *oomd* && $evidence != *nohang* && $evidence != *oom-manager* ]] || {
      _memory_fail 'gerenciador OOM existente; preserve a política atual.'
      return 1
    }
    ;;
  esac
}

memory_plan() {
  local module='' signature
  MEMORY_SWAPPINESS=''
  while (($#)); do
    case $1 in
    --zram | --earlyoom)
      [[ -z $module ]] || {
        _memory_fail 'selecione somente uma ação de memória.'
        return 2
      }
      module=${1#--}
      ;;
    --swappiness)
      (($# >= 2)) && [[ $2 =~ ^(0|[1-9][0-9]{0,2})$ ]] && ((10#$2 <= 200)) || {
        _memory_fail 'valor swappiness inválido.'
        return 2
      }
      [[ -z $module ]] || {
        _memory_fail 'selecione somente uma ação de memória.'
        return 2
      }
      module=swappiness
      MEMORY_SWAPPINESS=$2
      shift
      ;;
    *)
      _memory_fail "opção de memória desconhecida: $1"
      return 2
      ;;
    esac
    shift
  done
  _memory_inventory || return 1
  if [[ -z $module ]]; then
    printf 'memória: preserve (preserving) swap, zram, OOM e sysctls existentes.\n'
    return 0
  fi
  case $module in
  zram | earlyoom)
    _memory_conflict "$module" || return 1
    if [[ $module == zram ]]; then
      _memory_zram_capable || {
        _memory_fail 'módulo zram indisponível no kernel atual.'
        return 1
      }
    fi
    if [[ $module == zram ]]; then
      [[ ${PREFLIGHT_SWAPS:-} == *$'\t'* ]] || printf 'Aviso: nenhum disk swap detectado; nenhum será criado.\n'
      printf 'zram-tools: ALGO=lz4 PERCENT=50 PRIORITY=100; zramswap.service\n'
    else printf 'earlyoom: instalação opt-in, sem gerenciador OOM existente.\n'; fi
    ;;
  swappiness)
    _memory_has_zram || {
      _memory_fail 'swappiness exige zram ativo e compatível.'
      return 1
    }
    printf 'vm.swappiness=%s\n' "$MEMORY_SWAPPINESS"
    ;;
  esac
  MEMORY_PLAN_MODULE=$module
  signature=$(printf '%s\0' "$module" "$MEMORY_SWAPPINESS" "$PREFLIGHT_PACKAGES" "$PREFLIGHT_SERVICES" "$PREFLIGHT_SWAPS" "$PREFLIGHT_ZRAM" | sha256sum)
  MEMORY_PLAN_TOKEN=${signature%% *}
}

memory_apply() {
  local run=${1:-} module=${2:-} token=${3:-} config unit prior_enabled prior_active mask_set=no result=0 package APT_MEMORY_MASKED_UNIT=''
  [[ -n $run && $module =~ ^(zram|earlyoom|swappiness)$ && -n $token && $token == "${MEMORY_PLAN_TOKEN:-}" && $module == "${MEMORY_PLAN_MODULE:-}" ]] || {
    _memory_fail 'memory_apply exige módulo e token da prévia confirmada.'
    return 2
  }
  _memory_inventory || return 1
  case $module in
  zram | earlyoom)
    _memory_conflict "$module" || return 1
    _memory_package_contract "$module" || return 1
    ;;
  swappiness) _memory_has_zram || {
    _memory_fail 'swappiness exige zram ativo e compatível.'
    return 1
  } ;;
  esac
  case $module in zram)
    unit=zramswap.service
    package=zram-tools
    ;;
  earlyoom)
    unit=earlyoom.service
    package=earlyoom
    ;;
  esac
  if [[ $module == zram ]]; then _memory_zram_capable || {
    _memory_fail 'módulo zram indisponível no kernel atual.'
    return 1
  }; fi
  if [[ $module == swappiness ]]; then
    python3 "$_MEMORY_LIB/memory_file.py" audit "$run" swappiness sysctl-before "{\"value\":\"$(sysctl -n vm.swappiness)\"}" || return 1
    config=$(printf 'vm.swappiness=%s\n' "$MEMORY_SWAPPINESS")
    printf '%s' "$config" | python3 "$_MEMORY_LIB/memory_file.py" install "$run" swappiness || return 1
    sudo sysctl --system >/dev/null || return 1
    [[ $(sysctl -n vm.swappiness) == "$MEMORY_SWAPPINESS" ]] || return 1
    python3 "$_MEMORY_LIB/memory_file.py" audit "$run" swappiness sysctl-applied "{\"value\":\"$(sysctl -n vm.swappiness)\"}" || return 1
    return 0
  fi
  if [[ $module == zram || $module == earlyoom ]]; then
    prior_enabled=$(systemctl is-enabled "$unit" 2>/dev/null || true)
    prior_active=no
    systemctl is-active --quiet "$unit" && prior_active=yes
    [[ $prior_active == no && $prior_enabled != masked && $prior_enabled != masked-runtime ]] || {
      _memory_fail "unidade $unit já está ativa ou mascarada; preserve seu estado."
      return 1
    }
    python3 "$_MEMORY_LIB/memory_file.py" audit "$run" "$module" before "{\"enabled\":\"$prior_enabled\",\"active\":\"$prior_active\"}" || return 1
    # Mask only the unit whose package is being installed, so maintainer scripts
    # cannot start an unreviewed configuration during the APT transaction.
    sudo systemctl mask --runtime "$unit" >/dev/null || return 1
    mask_set=yes
    APT_MEMORY_MASKED_UNIT=$unit
    python3 "$_MEMORY_LIB/memory_file.py" audit "$run" "$module" masked "{\"enabled\":\"$prior_enabled\",\"active\":\"$prior_active\"}" || {
      [[ $prior_enabled == masked || $prior_enabled == masked-runtime ]] || sudo systemctl unmask --runtime "$unit" >/dev/null || true
      return 1
    }
  fi
  apt_plan "$module" "$package" || {
    [[ $mask_set == yes && $prior_enabled != masked && $prior_enabled != masked-runtime ]] && sudo systemctl unmask --runtime "$unit" >/dev/null || true
    return 1
  }
  apt_apply "$run" "$module" --confirmed "$APT_PLAN_TOKEN" "$package" || result=$?
  APT_MEMORY_MASKED_UNIT=''
  if ((result)); then
    if [[ $mask_set == yes && $prior_enabled != masked && $prior_enabled != masked-runtime ]]; then sudo systemctl unmask --runtime "$unit" >/dev/null || true; fi
    return "$result"
  fi
  if [[ $module == zram ]]; then
    config=$'ALGO=lz4\nPERCENT=50\nPRIORITY=100\n'
    printf '%s' "$config" | python3 "$_MEMORY_LIB/memory_file.py" install "$run" zram || {
      [[ $prior_enabled == masked || $prior_enabled == masked-runtime ]] || sudo systemctl unmask --runtime "$unit" >/dev/null || true
      return 1
    }
    python3 "$_MEMORY_LIB/memory_file.py" audit "$run" zram activating '{"unit":"zramswap.service"}' || {
      [[ $prior_enabled == masked || $prior_enabled == masked-runtime ]] || sudo systemctl unmask --runtime "$unit" >/dev/null || true
      return 1
    }
  fi
  [[ $prior_enabled == masked || $prior_enabled == masked-runtime ]] || sudo systemctl unmask --runtime "$unit" >/dev/null || return 1
  sudo systemctl enable --now "$unit" || return 1
  [[ $(systemctl is-active "$unit" 2>/dev/null) == active ]] || return 1
  if [[ $module == zram ]]; then [[ $(swapon --show=NAME --noheadings | grep -c '^/dev/zram') -gt 0 ]] || return 1; fi
  python3 "$_MEMORY_LIB/memory_file.py" audit "$run" "$module" active "{\"enabled\":\"$(systemctl is-enabled "$unit" 2>/dev/null)\",\"active\":\"active\"}" || return 1
  return 0
}
