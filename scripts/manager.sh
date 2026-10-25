#!/bin/sh
# Invoke with sh scripts/manager.sh; no package installation or shell evaluation.
set -eu
if ! command -v pwsh >/dev/null 2>&1; then
    printf '%s\n' 'PowerShell 7 (pwsh) is required. See docs/deployment-quickstart.md.' >&2
    exit 127
fi
manager_script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec pwsh -NoLogo -NoProfile -File "$manager_script_dir/manager.ps1" "$@"
