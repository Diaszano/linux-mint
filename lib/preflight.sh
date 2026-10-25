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
  local scope query listing unit _ metadata status version package content key value states evidence classification
  local -a args=() sorted_units=()
  local -A units=()
  PREFLIGHT_PACKAGES=unknown PREFLIGHT_PACKAGES_STATE=unknown PREFLIGHT_SWAPS=unknown PREFLIGHT_ZRAM=unknown PREFLIGHT_SERVICES=unknown PREFLIGHT_CONFLICT_SERVICES=unknown
  if ! PREFLIGHT_PACKAGES=$(dpkg-query -W -f='${binary:Package}\t${Status}\t${Version}\n' 2>/dev/null); then
    PREFLIGHT_PACKAGES=unknown
    return 1
  fi
  [[ -n $PREFLIGHT_PACKAGES ]] || return 1
  while IFS=$'\t' read -r package status version; do
    [[ $package =~ ^[a-z0-9][a-z0-9+.:~-]*$ && -n $version ]] || return 1
    case "$status" in
      *' ok installed'|*' ok config-files'|*' ok not-installed') ;;
      *) [[ ${1:-} == audit ]] || return 1 ;;
    esac
  done <<< "$PREFLIGHT_PACKAGES"
  PREFLIGHT_PACKAGES_STATE=known
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
      content=''
      if [[ $unit == *@.service ]]; then
        content=$(systemctl "${args[@]}" cat "$unit" --no-pager 2>/dev/null) || return 1
        metadata=$'Id='"$unit"$'\nActiveState=template'
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
      classification=${metadata,,}$'\n'${content,,}
      [[ ! $classification =~ (zram|zswap) ]] || evidence+=' zram'
      [[ ! $classification =~ /(swapon|swapoff)([[:space:];]|$) ]] || evidence+=' swap-policy'
      [[ ! $classification =~ (earlyoom|oomd|nohang|low-memory-monitor|oom[[:space:]_-]*(killer|manager)|out.of.memory|memory.pressure) ]] || evidence+=' oom-manager'
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

_preflight_doctor_fact() {
  local component=$1 field=$2 value=$3
  value=${value//$'\t'/ }
  value=${value//$'\r'/ }
  value=${value//$'\n'/ }
  printf '%s\t%s\t%s\n' "$component" "$field" "$value"
}

_preflight_doctor_power_supply_facts() {
  local root=$1 path field online found=no
  DOCTOR_POWER_SUPPLY_STATUS='NOT INSTALLED'
  DOCTOR_POWER_SUPPLY=''
  for path in "$root"/*/online; do
    [[ -e $path || -L $path ]] || continue
    found=yes
    field=${path%/*}
    field=${field##*/}
    if IFS= read -r online 2>/dev/null <"$path" && [[ $online == 0 || $online == 1 ]]; then
      [[ $DOCTOR_POWER_SUPPLY_STATUS == WARN ]] || DOCTOR_POWER_SUPPLY_STATUS=PASS
    else
      online=unknown
      DOCTOR_POWER_SUPPLY_STATUS=WARN
    fi
    if [[ -n $DOCTOR_POWER_SUPPLY ]]; then
      DOCTOR_POWER_SUPPLY+=" $field=$online"
    else
      DOCTOR_POWER_SUPPLY="$field=$online"
    fi
  done
  [[ $found == yes ]] || DOCTOR_POWER_SUPPLY=none
}

_preflight_doctor_thermal_status() {
  local temperature=$1 power_profile=$2 power_supply=$3
  if [[ $temperature == PASS && ( $power_profile == PASS || $power_supply == PASS ) \
      && $power_profile != WARN && $power_supply != WARN ]]; then
    printf 'PASS\n'
  elif [[ $temperature == 'NOT INSTALLED' && $power_profile == 'NOT INSTALLED' \
      && $power_supply == 'NOT INSTALLED' ]]; then
    printf 'NOT INSTALLED\n'
  else
    printf 'WARN\n'
  fi
}

preflight_doctor_facts() {
  local release key value os_id='' os_version='' codename='' arch threads memory cpu_model controllers virt='none'
  local swaps='' zram='' kvm_access=no kvm_ok='NOT INSTALLED' emulator='NOT INSTALLED' sdk renderer='NOT INSTALLED'
  local temperature='NOT INSTALLED' power='NOT INSTALLED' gradle mise docker_info='NOT INSTALLED' runs
  local status path field online swappiness page_cluster temperature_status power_profile_status power_supply_status power_supply

  if release=$(cat /etc/os-release 2>/dev/null); then
    while IFS='=' read -r key value; do
      value=${value#\"}
      value=${value%\"}
      case $key in
        ID) os_id=$value ;;
        VERSION_ID) os_version=$value ;;
        UBUNTU_CODENAME) codename=$value ;;
      esac
    done <<<"$release"
  fi
  arch=$(uname -m 2>/dev/null || echo unknown)
  threads=$(nproc 2>/dev/null || echo unknown)
  memory=$(awk '$1 == "MemTotal:" {print $2; exit}' /proc/meminfo 2>/dev/null || true)
  cpu_model=$(awk -F: '$1 ~ /^[[:space:]]*model name[[:space:]]*$/ {sub(/^[[:space:]]+/, "", $2); print $2; exit}' /proc/cpuinfo 2>/dev/null || true)
  if [[ $os_id == linuxmint && $os_version =~ ^22([.]|$) && $codename == noble && $arch == x86_64 ]]; then
    status=PASS
  else
    status=WARN
  fi
  _preflight_doctor_fact host status "$status"
  _preflight_doctor_fact host os_id "${os_id:-unknown}"
  _preflight_doctor_fact host os_version "${os_version:-unknown}"
  _preflight_doctor_fact host ubuntu_codename "${codename:-unknown}"
  _preflight_doctor_fact host architecture "$arch"
  _preflight_doctor_fact host cpu_threads "$threads"
  _preflight_doctor_fact host cpu_model "${cpu_model:-unknown}"
  _preflight_doctor_fact host memory_total_kb "${memory:-unknown}"

  if command -v swapon >/dev/null 2>&1 && swaps=$(swapon --show --noheadings --raw --output NAME,TYPE,SIZE,PRIO 2>/dev/null); then
    [[ -n $swaps ]] && status=PASS || status=WARN
  else
    swaps='unknown'
    status=WARN
  fi
  _preflight_doctor_fact swap status "$status"
  _preflight_doctor_fact swap devices "${swaps:-none}"
  IFS= read -r swappiness </proc/sys/vm/swappiness 2>/dev/null || swappiness=unknown
  IFS= read -r page_cluster </proc/sys/vm/page-cluster 2>/dev/null || page_cluster=unknown
  _preflight_doctor_fact swap vm_swappiness "$swappiness"
  _preflight_doctor_fact swap vm_page_cluster "$page_cluster"

  zram_managers=()
  if command -v dpkg-query >/dev/null 2>&1; then
    local package package_status
    for package in zram-tools systemd-zram-generator; do
      package_status=$(dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null || true)
      [[ $package_status == installed ]] && zram_managers+=("$package")
    done
  fi
  if command -v zramctl >/dev/null 2>&1 && zram=$(zramctl --noheadings --raw --output NAME,DISKSIZE 2>/dev/null); then
    if [[ -n $zram ]]; then
      status=PASS
    elif ((${#zram_managers[@]})); then
      status=WARN
    else
      status='NOT INSTALLED'
    fi
  else
    zram='unavailable'
    if ((${#zram_managers[@]})); then status=WARN; else status='NOT INSTALLED'; fi
  fi
  _preflight_doctor_fact zram status "$status"
  _preflight_doctor_fact zram devices "${zram:-none}"
  _preflight_doctor_fact zram manager_packages "${zram_managers[*]:-none}"

  if [[ $(grep -E -m1 -o '(^|[[:space:]])(svm|vmx)([[:space:]]|$)' /proc/cpuinfo 2>/dev/null | tr -d ' ' || true) =~ (svm|vmx) ]]; then
    virt=${BASH_REMATCH[1]}
  fi
  [[ -r /dev/kvm && -w /dev/kvm ]] && kvm_access=yes
  command -v kvm-ok >/dev/null 2>&1 && { kvm-ok >/dev/null 2>&1 && kvm_ok=PASS || kvm_ok=FAIL; }
  sdk=${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}
  if [[ -n $sdk && -x $sdk/emulator/emulator ]]; then
    emulator=$sdk/emulator/emulator
  elif command -v emulator >/dev/null 2>&1; then
    emulator=$(command -v emulator)
  fi
  if [[ $emulator != 'NOT INSTALLED' ]]; then
    "$emulator" -accel-check >/dev/null 2>&1 && emulator=PASS || emulator=FAIL
  fi
  if [[ $virt != none && $kvm_access == yes && $kvm_ok == PASS && $emulator == PASS ]]; then
    status=PASS
  elif [[ $virt == none || $kvm_access == no || $kvm_ok == FAIL || $emulator == FAIL ]]; then
    status=FAIL
  else
    status='NOT INSTALLED'
  fi
  _preflight_doctor_fact kvm status "$status"
  _preflight_doctor_fact kvm cpu_virtualization "$virt"
  _preflight_doctor_fact kvm device_access "$kvm_access"
  _preflight_doctor_fact kvm kvm_ok "$kvm_ok"
  _preflight_doctor_fact kvm emulator_accel_check "$emulator"
  _preflight_doctor_fact kvm manual 'Enable AMD-V/SVM in UEFI and grant the user access to /dev/kvm; install the official Android Emulator and rerun -accel-check.'

  if command -v glxinfo >/dev/null 2>&1; then
    renderer=$(glxinfo -B 2>/dev/null | sed -n 's/^[[:space:]]*OpenGL renderer string: //p' | head -n 1)
    [[ -n $renderer ]] && status=PASS || { renderer=unavailable; status=WARN; }
  else
    status='NOT INSTALLED'
  fi
  _preflight_doctor_fact mesa status "$status"
  _preflight_doctor_fact mesa renderer "$renderer"

  temperature_status='NOT INSTALLED'
  power_profile_status='NOT INSTALLED'
  power_supply_status='NOT INSTALLED'
  power_supply='none'
  if command -v sensors >/dev/null 2>&1; then
    temperature=$(sensors 2>/dev/null || true)
    [[ $temperature =~ [[:space:]][+-]?[0-9]+([.][0-9]+)?°C([[:space:]]|$) ]] && temperature_status=PASS || temperature_status=WARN
  fi
  if command -v powerprofilesctl >/dev/null 2>&1; then
    if power=$(powerprofilesctl get 2>/dev/null) && [[ -n $power ]]; then
      power_profile_status=PASS
    else
      power=unavailable
      power_profile_status=WARN
    fi
  fi
  _preflight_doctor_power_supply_facts /sys/class/power_supply
  power_supply_status=$DOCTOR_POWER_SUPPLY_STATUS
  power_supply=$DOCTOR_POWER_SUPPLY
  status=$(_preflight_doctor_thermal_status "$temperature_status" "$power_profile_status" "$power_supply_status")
  _preflight_doctor_fact thermal_power status "$status"
  _preflight_doctor_fact thermal_power temperature_status "$temperature_status"
  _preflight_doctor_fact thermal_power sensors "$temperature"
  _preflight_doctor_fact thermal_power power_profile_status "$power_profile_status"
  _preflight_doctor_fact thermal_power power "$power"
  _preflight_doctor_fact thermal_power power_supply_status "$power_supply_status"
  _preflight_doctor_fact thermal_power power_supply "$power_supply"

  controllers=$(cat /sys/fs/cgroup/cgroup.controllers 2>/dev/null || echo unavailable)
  if [[ " $controllers " == *' cpu '* && " $controllers " == *' memory '* && " $controllers " == *' pids '* ]]; then
    status=PASS
  else
    status=WARN
  fi
  _preflight_doctor_fact cgroup_controllers status "$status"
  _preflight_doctor_fact cgroup_controllers available "$controllers"

  gradle=$(command -v gradle 2>/dev/null || true)
  [[ -n $gradle ]] && status=PASS || { gradle='NOT INSTALLED'; status='NOT INSTALLED'; }
  _preflight_doctor_fact gradle status "$status"
  _preflight_doctor_fact gradle path "$gradle"

  mise=$(command -v mise 2>/dev/null || true)
  [[ -n $mise ]] || [[ ! -x $HOME/.local/bin/mise ]] || mise=$HOME/.local/bin/mise
  [[ -n $mise ]] && status=PASS || { mise='NOT INSTALLED'; status='NOT INSTALLED'; }
  _preflight_doctor_fact mise status "$status"
  _preflight_doctor_fact mise path "$mise"

  if [[ -n $sdk && -d $sdk ]]; then
    status=PASS
  elif [[ -n $sdk ]]; then
    status=WARN
  else
    sdk='NOT INSTALLED'
    status='NOT INSTALLED'
  fi
  _preflight_doctor_fact sdk status "$status"
  _preflight_doctor_fact sdk path "$sdk"

  if command -v docker >/dev/null 2>&1; then
    if docker_info=$(docker info --format '{{.CgroupDriver}}|{{.CgroupVersion}}|{{json .SecurityOptions}}' 2>/dev/null); then
      status=PASS
    else
      docker_info='engine unavailable'
      status=WARN
    fi
  else
    docker_info='NOT INSTALLED'
    status='NOT INSTALLED'
  fi
  _preflight_doctor_fact docker status "$status"
  _preflight_doctor_fact docker info "$docker_info"

  if runs=$(PYTHONDONTWRITEBYTECODE=1 python3 "$(dirname "${BASH_SOURCE[0]}")/manifest.py" list 2>/dev/null); then
    status=PASS
  else
    runs='unavailable'
    status=WARN
  fi
  _preflight_doctor_fact run_manifest status "$status"
  _preflight_doctor_fact run_manifest runs "$runs"
}
