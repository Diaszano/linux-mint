#!/usr/bin/env bash

_MISE_LIB=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/backup.sh
source "$_MISE_LIB/backup.sh"
# shellcheck source=lib/packages.sh
source "$_MISE_LIB/packages.sh"

_mise_fail() {
  printf 'mise: %s\n' "$1" >&2
  return 1
}

_mise_config() {
  local key value count=0 file="$_MISE_LIB/../config/mise-release.conf"
  MISE_VERSION='' MISE_ASSET='' MISE_BASE_URL='' MISE_PUBLIC_KEY=''
  [[ -f $file && ! -L $file ]] || {
    _mise_fail 'pinned release configuration is missing or unsafe.'
    return 1
  }
  while IFS='=' read -r key value || [[ -n $key ]]; do
    [[ -z $key || $key == \#* ]] && continue
    [[ -n $value && $value != *=* ]] || {
      _mise_fail 'invalid release configuration.'
      return 1
    }
    case $key in
    version)
      [[ -z $MISE_VERSION ]] || return 1
      MISE_VERSION=$value
      ;;
    asset)
      [[ -z $MISE_ASSET ]] || return 1
      MISE_ASSET=$value
      ;;
    base_url)
      [[ -z $MISE_BASE_URL ]] || return 1
      MISE_BASE_URL=$value
      ;;
    public_key)
      [[ -z $MISE_PUBLIC_KEY ]] || return 1
      MISE_PUBLIC_KEY=$value
      ;;
    *)
      _mise_fail 'unknown release configuration key.'
      return 1
      ;;
    esac
    ((count += 1))
  done <"$file"
  [[ $count == 4 && $MISE_VERSION == v2026.10.18 &&
    $MISE_ASSET == "mise-$MISE_VERSION-linux-x64" &&
    $MISE_BASE_URL == "https://github.com/jdx/mise/releases/download/$MISE_VERSION" &&
    $MISE_PUBLIC_KEY == RWTC3g8W3z4RZK3V3qv7fa1QY4JEWyBtqIHW+85QlJpZc5yG+uNYNBSZ ]] ||
    {
      _mise_fail 'release configuration does not match the pinned trust policy.'
      return 1
    }
}

_mise_target() { printf '%s/.local/bin/mise' "${HOME:?HOME is required}"; }

_mise_find_existing() {
  local target path
  target=$(_mise_target) || return 1
  if [[ -e $target || -L $target ]]; then
    [[ -f $target && -x $target && ! -L $target ]] || {
      _mise_fail "existing target is not a regular executable and will not be replaced: $target"
      return 2
    }
    MISE_EXEC_PATH=$target
    return 0
  fi
  path=$(type -P mise 2>/dev/null || true)
  [[ -n $path && -x $path ]] || return 1
  MISE_EXEC_PATH=$(realpath -e -- "$path") || {
    _mise_fail 'existing mise path cannot be resolved safely.'
    return 2
  }
}

mise_plan() {
  local owner status
  _mise_config || return 1
  if _mise_find_existing; then
    owner=$(stat -Lc '%U' -- "$MISE_EXEC_PATH") || return 1
    printf 'mise: reusing existing path=%s owner=%s; it will not be overwritten.\n' "$MISE_EXEC_PATH" "$owner"
    return 0
  else
    status=$?
    [[ $status == 1 ]] || return "$status"
  fi
  printf 'mise: pinned=%s asset=%s destination=%s\n' "$MISE_VERSION" "$MISE_ASSET" "$(_mise_target)"
  if ! command -v minisign >/dev/null 2>&1; then printf 'required package=minisign (distribution package)\n'; fi
  printf 'manual: if release verification fails, install mise manually from the verified official release.\n'
}

_mise_prepare_shell_files() {
  local file
  local bashrc="$HOME/.bashrc" zshrc="$HOME/.zshrc"
  [[ -f $bashrc && ! -L $bashrc && -O $bashrc ]] || {
    _mise_fail "an owned regular ~/.bashrc is required; create or inspect it before retrying."
    return 1
  }
  if [[ -e $zshrc || -L $zshrc ]]; then
    [[ -f $zshrc && ! -L $zshrc && -O $zshrc ]] || {
      _mise_fail "existing ~/.zshrc is not an owned regular file; inspect it before retrying."
      return 1
    }
  fi
}

_mise_install_shell_blocks() {
  local run=$1 local_bin=$2 block
  local bashrc="$HOME/.bashrc" zshrc="$HOME/.zshrc"
  if [[ $local_bin == yes ]]; then
    block=$'# >>> vaio-fe16 mise >>>\nexport PATH="$HOME/.local/bin:$PATH"\neval "$(mise activate bash)"\n# <<< vaio-fe16 mise <<<\n'
  else
    block=$'# >>> vaio-fe16 mise >>>\neval "$(mise activate bash)"\n# <<< vaio-fe16 mise <<<\n'
  fi
  install_owned_block "$run" mise "$bashrc" '# >>> vaio-fe16 mise >>>' '# <<< vaio-fe16 mise <<<' "$block" || return 1
  if [[ -f $zshrc ]]; then
    if [[ $local_bin == yes ]]; then
      block=$'# >>> vaio-fe16 mise >>>\nexport PATH="$HOME/.local/bin:$PATH"\neval "$(mise activate zsh)"\n# <<< vaio-fe16 mise <<<\n'
    else
      block=$'# >>> vaio-fe16 mise >>>\neval "$(mise activate zsh)"\n# <<< vaio-fe16 mise <<<\n'
    fi
    install_owned_block "$run" mise "$zshrc" '# >>> vaio-fe16 mise >>>' '# <<< vaio-fe16 mise <<<' "$block" || return 1
  fi
}

_mise_ensure_minisign() {
  local run=$1
  command -v minisign >/dev/null 2>&1 && return 0
  apt_plan mise minisign || {
    _mise_fail 'minisign is unavailable; install the signed distribution package manually, then retry.'
    return 1
  }
  apt_apply "$run" mise --confirmed "$APT_PLAN_TOKEN" minisign || {
    _mise_fail 'could not install the signed distribution minisign package; no mise artifact was installed.'
    return 1
  }
  command -v minisign >/dev/null 2>&1 || {
    _mise_fail 'minisign remains unavailable; install it manually from the signed distribution repository.'
    return 1
  }
}

_mise_download_verify() {
  local run=$1 target dir artifact sums signature digest version_output
  target=$(_mise_target)
  for tool in curl sha256sum python3; do
    command -v "$tool" >/dev/null 2>&1 || {
      _mise_fail "required verification tool missing: $tool"
      return 1
    }
  done
  dir=$(mktemp -d "${TMPDIR:-/tmp}/mise-release.XXXXXXXXXX") || return 1
  chmod 700 "$dir"
  artifact="$dir/$MISE_ASSET"
  sums="$dir/SHASUMS256.txt"
  signature="$dir/SHASUMS256.txt.minisig"
  if ! curl --proto '=https' --proto-redir '=https' --tlsv1.2 --fail --silent --show-error --location \
    --output "$sums" "$MISE_BASE_URL/SHASUMS256.txt" ||
    ! curl --proto '=https' --proto-redir '=https' --tlsv1.2 --fail --silent --show-error --location \
      --output "$signature" "$MISE_BASE_URL/SHASUMS256.txt.minisig" ||
    ! curl --proto '=https' --proto-redir '=https' --tlsv1.2 --fail --silent --show-error --location \
      --output "$artifact" "$MISE_BASE_URL/$MISE_ASSET"; then
    rm -rf -- "$dir"
    _mise_fail 'release download failed; no mise binary was installed. Install manually from the verified official release.'
    return 1
  fi
  if ! minisign -Vm "$sums" -x "$signature" -P "$MISE_PUBLIC_KEY"; then
    rm -rf -- "$dir"
    _mise_fail 'signed checksum manifest verification failed; no mise binary was installed. Install manually from the verified official release.'
    return 1
  fi
  digest=$(
    python3 - "$sums" "$MISE_ASSET" <<'PY'
import re
import sys
matches = []
for line in open(sys.argv[1], encoding='ascii'):
    fields = line.rstrip('\n').split(maxsplit=1)
    if len(fields) == 2:
        name = fields[1]
        if name.startswith('*'):
            name = name[1:]
        if name.startswith('./'):
            name = name[2:]
        if name == sys.argv[2]:
            matches.append(fields[0])
if len(matches) != 1 or not re.fullmatch(r'[0-9a-fA-F]{64}', matches[0]):
    raise SystemExit('missing or ambiguous asset checksum')
print(matches[0].lower())
PY
  ) || {
    rm -rf -- "$dir"
    _mise_fail 'signed manifest has no unique checksum for the pinned asset; no mise binary was installed. manual instructions: install only the official release after verifying its signature and hash.'
    return 1
  }
  if ! (cd "$dir" && printf '%s  %s\n' "$digest" "$MISE_ASSET" | sha256sum --check --status -); then
    rm -rf -- "$dir"
    _mise_fail 'mise artifact hash does not match the signed checksum manifest; no binary was installed. manual instructions: install only the official release after verifying its signature and hash.'
    return 1
  fi
  python3 "$_MISE_LIB/manifest.py" append "$run" \
    "{\"event\":\"artifact\",\"module\":\"mise\",\"version\":\"$MISE_VERSION\",\"name\":\"$MISE_ASSET\",\"url\":\"$MISE_BASE_URL\",\"sha256\":\"$digest\"}" || {
    rm -rf -- "$dir"
    _mise_fail 'could not journal verified mise artifact; no binary was installed.'
    return 1
  }
  chmod 755 "$artifact"
  version_output=$("$artifact" --version 2>&1) || {
    rm -rf -- "$dir"
    _mise_fail 'verified artifact failed its version check; no binary was installed.'
    return 1
  }
  [[ $version_output == *"${MISE_VERSION#v}"* ]] || {
    rm -rf -- "$dir"
    _mise_fail 'verified artifact reports a different version; no binary was installed.'
    return 1
  }
  install_owned_file_exclusive "$run" mise "$artifact" "$target" || {
    rm -rf -- "$dir"
    _mise_fail 'mise destination changed or is not safely writable; existing files were preserved.'
    return 1
  }
  rm -rf -- "$dir"
}

mise_apply() {
  local run=${1:-} local_bin=no status
  [[ $EUID -ne 0 && $(id -u) == "$EUID" ]] || {
    _mise_fail 'run as the normal user, not root.'
    return 1
  }
  [[ -n $run ]] || {
    _mise_fail 'usage: mise_apply RUN_ID'
    return 2
  }
  _mise_config || return 1
  _mise_prepare_shell_files || return 1
  if _mise_find_existing; then
    [[ $MISE_EXEC_PATH == "$(_mise_target)" ]] && local_bin=yes
  else
    status=$?
    [[ $status == 1 ]] || return "$status"
    _mise_ensure_minisign "$run" || return 1
    _mise_download_verify "$run" || return 1
    MISE_EXEC_PATH=$(_mise_target)
    local_bin=yes
  fi
  _mise_install_shell_blocks "$run" "$local_bin"
}
