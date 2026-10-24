#!/usr/bin/env bash

preflight_host() {
  local os_release key value os_id='' os_version='' ubuntu_codename='' arch threads mem_total='' controllers='' source_device='' storage_type='' free_kb='' virt='' renderer='' line
  os_release=$(cat /etc/os-release) || return 1
  while IFS='=' read -r key value; do
    value=${value#\"}
    value=${value%\"}
    case "$key" in
      ID) os_id=$value ;;
      VERSION_ID) os_version=$value ;;
      UBUNTU_CODENAME) ubuntu_codename=$value ;;
    esac
  done <<< "$os_release"
  arch=$(uname -m) || return 1
  if [[ $os_id != linuxmint || ! $os_version =~ ^22([.]|$) || $ubuntu_codename != noble || $arch != x86_64 ]]; then
    printf 'Erro: requer Linux Mint 22.x (Noble) x86_64.\n' >&2
    return 1
  fi
  threads=$(nproc) || return 1
  [[ $threads =~ ^[1-9][0-9]*$ ]] || return 1
  while read -r key value _; do
    if [[ $key == MemTotal: ]]; then mem_total=$value; break; fi
  done < <(cat /proc/meminfo)
  [[ $mem_total =~ ^[1-9][0-9]*$ ]] || return 1
  free_kb=$(df -Pk / | awk 'NR == 2 {print $4}') || return 1
  [[ $free_kb =~ ^[0-9]+$ ]] || return 1
  source_device=$(findmnt -n -o SOURCE / 2>/dev/null) || source_device=unknown
  storage_type=$(lsblk -ndo ROTA "$source_device" 2>/dev/null) || storage_type=unknown
  case "$storage_type" in 0) storage_type=ssd ;; 1) storage_type=hdd ;; esac
  controllers=$(cat /sys/fs/cgroup/cgroup.controllers 2>/dev/null) || controllers=unavailable
  if [[ $(cat /proc/cpuinfo 2>/dev/null) =~ (^|[[:space:]])(svm|vmx)([[:space:]]|$) ]]; then
    virt=${BASH_REMATCH[2]}
  else
    virt=none
  fi
  renderer=$(glxinfo -B 2>/dev/null | sed -n 's/^[[:space:]]*OpenGL renderer string: //p' | head -n 1) || renderer=
  [[ -n $renderer ]] || renderer=unavailable
  printf 'os_id=%s\nos_version=%s\nubuntu_codename=%s\narch=%s\ncpu_threads=%s\nmem_total_kb=%s\nstorage_device=%s\nstorage_type=%s\nstorage_free_kb=%s\ncgroup_controllers=%s\ncpu_virtualization=%s\nkvm_access=%s\nmesa_renderer=%s\n' \
    "$os_id" "$os_version" "$ubuntu_codename" "$arch" "$threads" "$mem_total" "$source_device" "$storage_type" "$free_kb" "$controllers" "$virt" "$([[ -r /dev/kvm && -w /dev/kvm ]] && echo yes || echo no)" "$renderer"
  for line in git cmake ninja python3 mise docker; do
    if command -v "$line" >/dev/null 2>&1; then
      printf 'tool_%s=present\n' "$line"
    else
      printf 'tool_%s=absent\n' "$line"
    fi
  done
}

preflight_package() {
  local status
  status=$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null) || { echo unknown; return; }
  case "$status" in
    *' ok installed') echo yes ;;
    *' ok not-installed'|*' ok config-files') echo no ;;
    *) echo unknown ;;
  esac
}

preflight_unit() {
  local status result=0
  status=$(systemctl "$@" 2>/dev/null) || result=$?
  case "$result:$status" in
    0:active|0:reloading) echo yes ;;
    3:inactive|3:failed|3:activating|3:deactivating|3:maintenance|0:inactive) echo no ;;
    *) echo unknown ;;
  esac
}

preflight_units() {
  local scope=$1 query inventory listing unit load active sub
  local -a args=()
  [[ $scope == user ]] && args+=(--user)
  for query in list-units list-unit-files; do
    if [[ $query == list-units ]]; then inventory=units; else inventory=unit_files; fi
    if listing=$(systemctl "${args[@]}" "$query" --all --no-legend --plain --no-pager 2>/dev/null); then
      printf '%s_%s=known\n' "$scope" "$inventory"
      while read -r unit load active sub _; do
        [[ $unit =~ (zram|swap|oom) ]] || continue
        if [[ $query == list-units ]]; then
          printf '%s_unit=%s load=%s active=%s sub=%s\n' "$scope" "$unit" "$load" "$active" "$sub"
        else
          printf '%s_unit_file=%s state=%s\n' "$scope" "$unit" "$load"
        fi
      done <<< "$listing"
    else
      printf '%s_%s=unknown\n' "$scope" "$inventory"
    fi
  done
}

preflight_conflicts() {
  local zram_tools zram_generator earlyoom docker_io docker_ce swap_devices docker_provider swap_records device type size priority
  zram_tools=$(preflight_package zram-tools)
  zram_generator=$(preflight_package systemd-zram-generator)
  earlyoom=$(preflight_package earlyoom)
  docker_io=$(preflight_package docker.io)
  docker_ce=$(preflight_package docker-ce)
  if swap_records=$(swapon --show --noheadings --raw --output NAME,TYPE,SIZE,PRIO 2>/dev/null); then
    swap_devices=$(awk '{print $1}' <<< "$swap_records" | paste -sd, -)
  else
    swap_records=''
    swap_devices=unknown
  fi
  [[ -n $swap_devices ]] || swap_devices=none
  docker_provider=none
  if [[ $docker_io == yes && $docker_ce == yes ]]; then
    docker_provider=conflict
  elif [[ $docker_io == unknown || $docker_ce == unknown ]]; then
    docker_provider=unknown
  elif [[ $docker_io == yes ]]; then
    docker_provider=docker.io
  elif [[ $docker_ce == yes ]]; then
    docker_provider=docker-ce
  fi
  printf 'zram_tools_installed=%s\nzram_generator_installed=%s\nzramswap_active=%s\nzram_unit_active=%s\nswap_devices=%s\nearlyoom_installed=%s\nearlyoom_active=%s\nsystemd_oomd_active=%s\nuser_oomd_active=%s\ndocker_provider=%s\n' \
    "$zram_tools" "$zram_generator" "$(preflight_unit is-active zramswap.service)" "$(preflight_unit is-active systemd-zram-setup@zram0.service)" "$swap_devices" "$earlyoom" "$(preflight_unit is-active earlyoom.service)" "$(preflight_unit is-active systemd-oomd.service)" "$(preflight_unit --user is-active systemd-oomd.service)" "$docker_provider"
  while read -r device type size priority; do
    [[ -n $device ]] || continue
    printf 'swap_device=%s type=%s size=%s priority=%s\n' "$device" "$type" "$size" "$priority"
  done <<< "$swap_records"
  preflight_units system
  preflight_units user
}

# Inspect metadata as data: custom unit names can still invoke a known manager.
# shortcut: opaque custom launchers hide their purpose; extend detection after reviewing their source.
# shellcheck disable=SC2034
preflight_install_inventory() {
  local scope query listing unit _ metadata status version package content key value states evidence
  local -a args=() sorted_units=()
  local -A units=()
  PREFLIGHT_PACKAGES=unknown PREFLIGHT_SWAPS=unknown PREFLIGHT_ZRAM=unknown PREFLIGHT_SERVICES=unknown PREFLIGHT_CONFLICT_SERVICES=unknown
  PREFLIGHT_PACKAGES=$(dpkg-query -W -f='${binary:Package}\t${Status}\t${Version}\n' 2>/dev/null) || return 1
  [[ -n $PREFLIGHT_PACKAGES ]] || return 1
  while IFS=$'\t' read -r package status version; do
    [[ $package =~ ^[a-z0-9][a-z0-9+.:~-]*$ && -n $version ]] || return 1
    case "$status" in
      *' ok installed'|*' ok config-files'|*' ok not-installed') ;;
      *) [[ ${1:-} == audit ]] || return 1 ;;
    esac
  done <<< "$PREFLIGHT_PACKAGES"
  PREFLIGHT_SWAPS=$(swapon --show --noheadings --raw --output NAME,TYPE,SIZE,PRIO 2>/dev/null) || return 1
  PREFLIGHT_ZRAM=$(zramctl --noheadings --raw --output NAME,DISKSIZE 2>/dev/null) || return 1
  PREFLIGHT_SERVICES=''
  PREFLIGHT_CONFLICT_SERVICES=''
  for scope in system user; do
    args=(--"$scope")
    units=()
    for query in list-units list-unit-files; do
      listing=$(systemctl "${args[@]}" "$query" --all --no-legend --plain --no-pager 2>/dev/null) || return 1
      while read -r unit _; do
        [[ -n $unit ]] || continue
        [[ $unit =~ ^[A-Za-z0-9_.@:\\-]+\.(service|swap|target|socket|timer|path|mount|automount|device|slice|scope)$ ]] || return 1
        case "$unit" in *.service|*.swap) units[$unit]=1 ;; esac
      done <<< "$listing"
    done
    mapfile -t sorted_units < <(printf '%s\n' "${!units[@]}" | LC_ALL=C sort)
    for unit in "${sorted_units[@]}"; do
      [[ -n $unit ]] || continue
      if [[ $unit == *@.service ]]; then
        content=$(systemctl "${args[@]}" cat "$unit" --no-pager 2>/dev/null) || return 1
        metadata=$'Id='"$unit"$'\nActiveState=template'
        [[ ! ${content,,} =~ (zram|zswap) ]] || metadata+=$'\nManagerEvidence=zram'
        [[ ! ${content,,} =~ (earlyoom|oomd|nohang|low-memory-monitor|out.of.memory|memory.pressure) ]] || metadata+=$'\nManagerEvidence=oom-manager'
      else
        metadata=$(systemctl "${args[@]}" show "$unit" --no-pager \
          -p Id -p Description -p ExecStart -p ExecStartPre -p ExecStartPost \
          -p LoadState -p ActiveState -p UnitFileState 2>/dev/null) || return 1
      fi
      [[ $metadata == *'Id='* && $metadata == *'ActiveState='* ]] || return 1
      [[ $metadata != *'LoadState=error'* && $metadata != *'LoadState=bad-setting'* ]] || return 1
      if [[ $metadata == *'LoadState=not-found'* ]]; then
        [[ $metadata == *'ActiveState=inactive'* ]] || return 1
        continue
      fi
      evidence=''
      [[ ! ${metadata,,} =~ (zram|zswap) ]] || evidence+=' zram'
      [[ ! ${metadata,,} =~ /(swapon|swapoff)([[:space:];]|$) ]] || evidence+=' swap-policy'
      [[ ! ${metadata,,} =~ (earlyoom|oomd|nohang|low-memory-monitor|oom[[:space:]_-]*(killer|manager)|out.of.memory|memory.pressure) ]] || evidence+=' oom-manager'
      [[ ! ${unit,,} =~ (^|[._-])oom([._@-]|$) ]] || evidence+=' oom-manager'
      states=''
      while IFS='=' read -r key value; do
        case "$key" in
          ActiveState|UnitFileState|LoadState)
            [[ $value =~ ^[a-z-]*$ ]] || return 1
            if [[ $key == ActiveState ]]; then
              case "$value" in active|inactive|failed|activating|deactivating|reloading|refreshing|maintenance|template) ;; *) return 1 ;; esac
            fi
            states+="$key=$value"$'\n' ;;
        esac
      done <<< "$metadata"
      # Retain state and matched categories, never arbitrary service command arguments.
      PREFLIGHT_SERVICES+="$scope:$unit"$'\n'"$states""ManagerEvidence=$evidence"$'\n'
      if [[ -n $evidence || ${unit,,} =~ (zram|swap|oom) ]]; then
        PREFLIGHT_CONFLICT_SERVICES+="$scope:$unit"$'\n'"$states""ManagerEvidence=$evidence"$'\n'
      fi
    done
  done
}
