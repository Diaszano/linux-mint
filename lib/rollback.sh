#!/usr/bin/env bash

rollback_preview() {
    local lib_dir
    lib_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    python3 "$lib_dir/memory_file.py" rollback "$1" preview || return 1
    python3 "$lib_dir/manifest.py" rollback-preview "$1"
}

rollback_owned_preview() {
    [[ ${1:-} =~ ^[0-9]{20}-[0-9a-f]{16}$ ]] || return 2
    rollback_preview "$1"
}

rollback_apply() {
    local lib_dir
    lib_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    python3 "$lib_dir/memory_file.py" rollback "$1" apply || return 1
    python3 "$lib_dir/manifest.py" rollback-apply "$1"
}
