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
  status=$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null) || status=
  [[ $status == 'install ok installed' ]] && echo yes || echo no
}

preflight_unit() {
  local status
  status=$(systemctl "$@" 2>/dev/null) || status=unknown
  [[ $status == active ]] && echo yes || echo no
}

preflight_conflicts() {
  local zram_tools zram_generator earlyoom docker_io docker_ce swap_devices docker_provider
  zram_tools=$(preflight_package zram-tools)
  zram_generator=$(preflight_package systemd-zram-generator)
  earlyoom=$(preflight_package earlyoom)
  docker_io=$(preflight_package docker.io)
  docker_ce=$(preflight_package docker-ce)
  swap_devices=$(swapon --show --noheadings --output NAME,TYPE,SIZE,PRIO 2>/dev/null | awk '{print $1}' | paste -sd, -) || swap_devices=unknown
  [[ -n $swap_devices ]] || swap_devices=none
  docker_provider=none
  if [[ $docker_io == yes && $docker_ce == yes ]]; then
    docker_provider=conflict
  elif [[ $docker_io == yes ]]; then
    docker_provider=docker.io
  elif [[ $docker_ce == yes ]]; then
    docker_provider=docker-ce
  fi
  printf 'zram_tools_installed=%s\nzram_generator_installed=%s\nzramswap_active=%s\nzram_unit_active=%s\nswap_devices=%s\nearlyoom_installed=%s\nearlyoom_active=%s\nsystemd_oomd_active=%s\nuser_oomd_active=%s\ndocker_provider=%s\n' \
    "$zram_tools" "$zram_generator" "$(preflight_unit is-active zramswap.service)" "$(preflight_unit is-active systemd-zram-setup@zram0.service)" "$swap_devices" "$earlyoom" "$(preflight_unit is-active earlyoom.service)" "$(preflight_unit is-active systemd-oomd.service)" "$(preflight_unit --user is-active systemd-oomd.service)" "$docker_provider"
}
