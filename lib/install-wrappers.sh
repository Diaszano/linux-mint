#!/usr/bin/env bash

_INSTALL_WRAPPERS_LIB=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=lib/backup.sh
source "$_INSTALL_WRAPPERS_LIB/backup.sh"

_WRAPPER_COMMANDS=(dev-run dev-build dev-emulator dev-doctor dev-profile dev-rollback)
_WRAPPER_BEGIN='# >>> vaio-fe16 user wrappers >>>'
_WRAPPER_END='# <<< vaio-fe16 user wrappers <<<'
_WRAPPER_BLOCK=$'# >>> vaio-fe16 user wrappers >>>\ncase ":$PATH:" in\n *":$HOME/.local/bin:"*) ;;\n *) export PATH="$HOME/.local/bin:$PATH" ;;\nesac\n# <<< vaio-fe16 user wrappers <<<\n'

_wrappers_fail() {
	printf 'install-wrappers: %s\n' "$1" >&2
	return 1
}

_wrappers_safe_path() {
	local path=$1 owner mode
	while :; do
		[[ ! -L $path ]] || return 1
		read -r owner mode < <(stat -c '%u %a' -- "$path") || return 1
		[[ $owner == "$EUID" || $owner == 0 ]] || return 1
		[[ $mode =~ ^[0-7]+$ ]] || return 1
		(((8#$mode & 0022) == 0 || (8#$mode & 01000) != 0)) || return 1
		[[ $path == / ]] && return 0
		path=${path%/*}
		[[ -n $path ]] || path=/
	done
}

_wrappers_check_rc() {
	local path=$1
	[[ ! -e $path && ! -L $path ]] && return 0
	[[ -f $path && ! -L $path && -O $path ]] || return 1
	_wrappers_safe_path "$(dirname "$path")"
}

install_wrappers() {
	local run=${1:-} root home local_bin tmp_dir rc command source launcher target
	[[ $# == 1 && $run =~ ^[0-9]{20}-[0-9a-f]{16}$ ]] || {
		_wrappers_fail 'a valid RUN_ID is required.'
		return 2
	}
	home=${HOME:-}
	[[ $home == /* && -d $home && -O $home && ! -L $home ]] || {
		_wrappers_fail 'HOME must be an owned absolute directory.'
		return 1
	}
	_wrappers_safe_path "$home" || {
		_wrappers_fail 'HOME path has unsafe ownership or permissions.'
		return 1
	}
	root=$(cd "$_INSTALL_WRAPPERS_LIB/.." && pwd -P) || return 1
	python3 "$_INSTALL_WRAPPERS_LIB/manifest.py" verify "$run" >/dev/null || {
		_wrappers_fail 'run journal is missing or invalid.'
		return 1
	}
	for rc in "$home/.bashrc" "$home/.zshrc"; do
		_wrappers_check_rc "$rc" || {
			_wrappers_fail "unsafe shell startup file: $rc"
			return 1
		}
	done
	[[ ! -L $home/.local && ! -L $home/.local/bin ]] || {
		_wrappers_fail 'user bin path must not contain symlinks.'
		return 1
	}
	umask 077
	mkdir -p -- "$home/.local/bin" || {
		_wrappers_fail 'cannot create user bin directory.'
		return 1
	}
	local_bin=$home/.local/bin
	_wrappers_safe_path "$local_bin" || {
		_wrappers_fail "user bin path has unsafe ownership or permissions: $local_bin"
		return 1
	}
	for command in "${_WRAPPER_COMMANDS[@]}"; do
		source=$root/bin/$command
		[[ -f $source && ! -L $source && -x $source && -O $source ]] || {
			_wrappers_fail "source command is missing or unsafe: $source"
			return 1
		}
		target=$local_bin/$command
		if [[ -e $target || -L $target ]]; then
			[[ -f $target && ! -L $target && -O $target ]] || {
				_wrappers_fail "existing command is not a user-owned regular file: $target"
				return 1
			}
		fi
	done
	tmp_dir=$(mktemp -d /tmp/vaio-wrappers.XXXXXXXX) || {
		_wrappers_fail 'cannot create a private temporary directory.'
		return 1
	}
	chmod 700 "$tmp_dir" || {
		rm -rf -- "$tmp_dir"
		return 1
	}
	install_owned_block "$run" wrappers "$home/.bashrc" "$_WRAPPER_BEGIN" "$_WRAPPER_END" "$_WRAPPER_BLOCK" || {
		rm -rf -- "$tmp_dir"
		return 1
	}
	if [[ -f $home/.zshrc ]]; then
		install_owned_block "$run" wrappers "$home/.zshrc" "$_WRAPPER_BEGIN" "$_WRAPPER_END" "$_WRAPPER_BLOCK" || {
			rm -rf -- "$tmp_dir"
			return 1
		}
	fi
	for command in "${_WRAPPER_COMMANDS[@]}"; do
		source=$root/bin/$command
		printf -v launcher '%q' "$source"
		printf '#!/usr/bin/env bash\nset -Eeuo pipefail\nexec %s "$@"\n' "$launcher" >"$tmp_dir/$command" || {
			rm -rf -- "$tmp_dir"
			_wrappers_fail "cannot prepare user command: $command"
			return 1
		}
		chmod 755 "$tmp_dir/$command" || {
			rm -rf -- "$tmp_dir"
			return 1
		}
		install_owned_file "$run" wrappers "$tmp_dir/$command" "$local_bin/$command" || {
			rm -rf -- "$tmp_dir"
			_wrappers_fail "cannot install user command: $command"
			return 1
		}
	done
	rm -rf -- "$tmp_dir"
}
