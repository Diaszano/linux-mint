#!/usr/bin/env bash

rollback_preview() {
    python3 "$(dirname "${BASH_SOURCE[0]}")/manifest.py" rollback-preview "$1"
}

rollback_apply() {
    python3 "$(dirname "${BASH_SOURCE[0]}")/manifest.py" rollback-apply "$1"
}
