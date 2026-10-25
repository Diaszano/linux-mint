#!/usr/bin/env bash

profile_number() { [[ $1 =~ ^(0|[1-9][0-9]{0,11})$ ]]; }

profile_load_table() {
    local file=$1 row name cpu high max swap tasks found=0
    declare -A seen=()
    PROFILE_ROWS=()
    [[ -f $file && ! -L $file ]] || return 1
    while IFS= read -r row || [[ -n $row ]]; do
        [[ -n $row && $row != \#* ]] || continue
        [[ $row =~ ^(build|emulator|heavy)$'\t'([1-9][0-9]{0,2})$'\t'([1-9][0-9]?)$'\t'([1-9][0-9]?)$'\t'(0|[1-9][0-9]?)$'\t'([1-9][0-9]{0,3})$ ]] || return 1
        IFS=$'\t' read -r name cpu high max swap tasks <<<"$row"
        [[ ! ${seen[$name]:-} ]] || return 1
        seen[$name]=1
        ((cpu <= 800 && max <= 22 && swap <= 22 && tasks <= 4096 && high < max)) || return 1
        PROFILE_ROWS+=("$row")
        found=1
    done <"$file"
    ((found))
}

profile_choice_read() {
    local path=$1
    local -a rows=()
    # Shared output consumed by dev-profile and dev-run after sourcing this library.
    # shellcheck disable=SC2034
    PROFILE_CHOICE=balanced
    [[ -e $path || -L $path ]] || return 0
    [[ -f $path && ! -L $path && -O $path && $(stat -c %a -- "$path") == 600 ]] || return 1
    mapfile -t rows <"$path" || return 1
    [[ ${#rows[@]} == 1 && ${rows[0]} == balanced ]] || return 1
    # Shared output consumed by dev-profile and dev-run after sourcing this library.
    # shellcheck disable=SC2034
    PROFILE_CHOICE=${rows[0]}
}

profile_table_path() {
    local root=$1 path=${XDG_CONFIG_HOME:-$HOME/.config}/vaio-dev/profiles.conf
    if [[ -e $path || -L $path ]]; then
        [[ -f $path && ! -L $path && -O $path && $(stat -c %a -- "$path") == 600 ]] || return 1
        printf '%s\n' "$path"
    else
        printf '%s\n' "$root/config/profiles.conf"
    fi
}
