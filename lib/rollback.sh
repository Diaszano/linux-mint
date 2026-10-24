#!/usr/bin/env bash

rollback_preview() {
    local lib_dir
    lib_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    python3 "$lib_dir/memory_file.py" rollback "$1" preview || return 1
    python3 "$lib_dir/manifest.py" rollback-preview "$1"
}

rollback_apply() {
    local lib_dir
    lib_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    python3 "$lib_dir/memory_file.py" rollback "$1" apply || return 1
    python3 "$lib_dir/manifest.py" rollback-apply "$1"
}
