#!/usr/bin/env bats
setup() {
	ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
	export HOME="$BATS_TEST_TMPDIR/home"
	export XDG_CONFIG_HOME="$HOME/.config"
	export XDG_STATE_HOME="$HOME/.local/state"
	export FIXTURE="$BATS_TEST_TMPDIR"
	umask 077
	mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME"
	touch "$HOME/.bashrc"
	chmod 700 "$BATS_TEST_TMPDIR" "$HOME"
	chmod 700 "$(dirname "$BATS_TEST_TMPDIR")"
	source "$ROOT/lib/backup.sh"
	RUN_ID=$(begin_run)
}
install() {
	bash -c 'source "$1/lib/backup.sh"; source "$1/lib/install-wrappers.sh"; install_wrappers "$2"' _ "$ROOT" "$RUN_ID"
}
@test "installs launchers and preserves argv" {
	printf '# user bash\nexport PATH="/custom/bin:$PATH"\n' >"$HOME/.bashrc"
	printf '# user zsh\n' >"$HOME/.zshrc"
	run install
	[ "$status" -eq 0 ]
	for command in dev-run dev-build dev-emulator dev-doctor dev-profile dev-rollback; do [ -x "$HOME/.local/bin/$command" ]; done
	[ ! -e "$HOME/.local/bin/dev-gate" ]
	run "$HOME/.local/bin/dev-profile" show
	[ "$status" -eq 0 ]
	[[ "$output" == *"preset=balanced"* ]]
	grep -Fq '# user bash' "$HOME/.bashrc"
	grep -Fq 'export PATH="/custom/bin:$PATH"' "$HOME/.bashrc"
	[ "$(grep -Fc '# >>> vaio-fe16 user wrappers >>>' "$HOME/.bashrc")" -eq 1 ]
	[ "$(grep -Fc '# >>> vaio-fe16 user wrappers >>>' "$HOME/.zshrc")" -eq 1 ]
}
@test "launcher sources command and preserves argument boundaries" {
	cat >"$ROOT/bin/dev-argv-test" <<'SH'
#!/usr/bin/env bash
printf '<%s>\n' "$@"
SH
	chmod 755 "$ROOT/bin/dev-argv-test"
	run bash -c 'source "$1/lib/backup.sh"; source "$1/lib/install-wrappers.sh"; _WRAPPER_COMMANDS=(dev-argv-test); install_wrappers "$2"' _ "$ROOT" "$RUN_ID"
	[ "$status" -eq 0 ]
	run "$HOME/.local/bin/dev-argv-test" "two words" '$literal' ""
	[ "$status" -eq 0 ]
	[ "$output" = $'<two words>\n<$literal>\n<>' ]
	rm "$ROOT/bin/dev-argv-test"
}
@test "second install is no-op for launchers, PATH blocks, and journal" {
	run install
	[ "$status" -eq 0 ]
	before=$(find "$HOME/.local/bin" -maxdepth 1 -type f -exec sha256sum {} + | sort)
	bashrc_before=$(sha256sum "$HOME/.bashrc")
	journal="$XDG_STATE_HOME/vaio-fe16-dev-setup/runs/$RUN_ID/manifest.jsonl"
	lines_before=$(wc -l <"$journal")
	run install
	[ "$status" -eq 0 ]
	[ "$(find "$HOME/.local/bin" -maxdepth 1 -type f -exec sha256sum {} + | sort)" = "$before" ]
	[ "$(sha256sum "$HOME/.bashrc")" = "$bashrc_before" ]
	[ "$(wc -l <"$journal")" -eq "$lines_before" ]
	[ "$(grep -Fc '# >>> vaio-fe16 user wrappers >>>' "$HOME/.bashrc")" -eq 1 ]
}
@test "preexisting executable backs up and generic rollback restores it" {
	mkdir -p "$HOME/.local/bin"
	printf '#!/bin/sh\nprintf "foreign command\\n"\n' >"$HOME/.local/bin/dev-profile"
	chmod 755 "$HOME/.local/bin/dev-profile"
	run install
	[ "$status" -eq 0 ]
	run "$HOME/.local/bin/dev-profile" show
	[ "$status" -eq 0 ]
	[[ "$output" == *"preset=balanced"* ]]
	run bash -c 'source "$1/lib/rollback.sh"; rollback_apply "$2"' _ "$ROOT" "$RUN_ID"
	[ "$status" -eq 0 ]
	run "$HOME/.local/bin/dev-profile"
	[ "$status" -eq 0 ]
	[ "$output" = 'foreign command' ]
}
@test "later user edit is not overwritten by install or rollback" {
	run install
	[ "$status" -eq 0 ]
	printf '# user replacement\n' >"$HOME/.local/bin/dev-profile"
	chmod 755 "$HOME/.local/bin/dev-profile"
	run install
	[ "$status" -ne 0 ]
	[ "$(cat "$HOME/.local/bin/dev-profile")" = '# user replacement' ]
	run bash -c 'source "$1/lib/rollback.sh"; rollback_apply "$2"' _ "$ROOT" "$RUN_ID"
	[ "$status" -ne 0 ]
	[ "$(cat "$HOME/.local/bin/dev-profile")" = '# user replacement' ]
}
@test "interrupted atomic install keeps old wrapper and leaves valid recovery journal" {
	mkdir -p "$HOME/.local/bin" "$FIXTURE/python"
	printf '# old wrapper\n' >"$HOME/.local/bin/dev-build"
	chmod 755 "$HOME/.local/bin/dev-build"
	cat >"$FIXTURE/python/sitecustomize.py" <<'PY'
import os
replace = os.replace
def fail_for_target(source, target, *args, **kwargs):
    if target == os.environ.get('VAIO_FAIL_REPLACE_TARGET'):
        raise OSError('injected interrupted atomic replacement')
    return replace(source, target, *args, **kwargs)
os.replace = fail_for_target
PY
	run env PYTHONPATH="$FIXTURE/python" VAIO_FAIL_REPLACE_TARGET=dev-build bash -c 'source "$1/lib/backup.sh"; source "$1/lib/install-wrappers.sh"; install_wrappers "$2"' _ "$ROOT" "$RUN_ID"
	[ "$status" -ne 0 ]
	[ "$(cat "$HOME/.local/bin/dev-build")" = '# old wrapper' ]
	run python3 "$ROOT/lib/manifest.py" verify "$RUN_ID"
	[ "$status" -eq 0 ]
	journal="$XDG_STATE_HOME/vaio-fe16-dev-setup/runs/$RUN_ID/manifest.jsonl"
	[ -s "$journal" ]
}
