#!/usr/bin/env bats

setup() {
    ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
}

@test "emulator wrapper fails closed when an SDK is absent in the disposable VM" {
    run env ANDROID_SDK_ROOT="$BATS_TEST_TMPDIR/absent-sdk" \
        ANDROID_HOME="$BATS_TEST_TMPDIR/absent-sdk" "$ROOT/bin/dev-emulator" --list
    [ "$status" != 0 ]
    [[ "$output" == *'Android Emulator'* || "$output" == *'SDK'* ]]
}
