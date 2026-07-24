#!/usr/bin/env sh
set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
handoff_paths='tests/windows/Contract.Tests.ps1
tests/windows/Files.Tests.ps1
tests/windows/fixtures/FakePalServer.cmd
tests/windows/Lifecycle.Tests.ps1
tests/windows/Run-CgceDiscoveryTests.ps1
tests/windows/Runtime.Tests.ps1
tests/windows/TestHarness.ps1
tools/windows-discovery/CgceDiscovery.Common.psm1
tools/windows-discovery/Export-CgceDiscoveryEvidence.ps1
tools/windows-discovery/Invoke-CgceDiscovery.ps1
tools/windows-discovery/modules/CgceDiscovery.Contract.psm1
tools/windows-discovery/modules/CgceDiscovery.Files.psm1
tools/windows-discovery/modules/CgceDiscovery.Runtime.psm1
tools/windows-discovery/Prepare-CgceDiscovery.ps1
tools/windows-discovery/probe/CGCEDiscoveryInventory/scripts/main.lua
tools/windows-discovery/README.md
tools/windows-discovery/Restore-CgceProduction.ps1
tools/windows-discovery/schemas/control-evidence.schema.json
tools/windows-discovery/schemas/export-manifest.schema.json
tools/windows-discovery/schemas/run-state.schema.json'
repository_only_paths='scripts/verify-discovery-handoff.sh
scripts/build-discovery-handoff.sh'

fail() {
    printf '%s\n' "$1" >&2
    exit 1
}

is_allowed_handoff_path() {
    candidate=$1
    for allowed in $handoff_paths; do
        if [ "$candidate" = "$allowed" ]; then
            return 0
        fi
    done
    return 1
}

"$repository_root/scripts/verify-package.sh" discovery

for relative in $handoff_paths $repository_only_paths; do
    (
        cd "$repository_root"
        git ls-files --error-unmatch -- "$relative" >/dev/null 2>&1
    ) \
        || fail "CGCE-HANDOFF-TRACKED: required source is not tracked: $relative"
    path="$repository_root/$relative"
    [ -f "$path" ] \
        || fail "CGCE-HANDOFF-MISSING: required source is missing: $relative"
    [ ! -L "$path" ] \
        || fail "CGCE-HANDOFF-SYMLINK: source symlink is forbidden: $relative"
done

if find \
    "$repository_root/tools/windows-discovery" \
    "$repository_root/tests/windows" \
    -type l -print | grep -q .; then
    fail "CGCE-HANDOFF-SYMLINK: handoff tree contains a symlink"
fi

find \
    "$repository_root/tools/windows-discovery" \
    "$repository_root/tests/windows" \
    -type f -print |
    LC_ALL=C LANG=C sort |
    while IFS= read -r path; do
        relative=${path#"$repository_root"/}
        if ! is_allowed_handoff_path "$relative"; then
            fail "CGCE-HANDOFF-ALLOWLIST: unrecognized source: $relative"
        fi
        lower=$(printf '%s' "$relative" | tr '[:upper:]' '[:lower:]')
        case "$lower" in
            *.dll)
                fail "CGCE-HANDOFF-BINARY: DLL entry is forbidden: $relative"
                ;;
        esac
    done

probe="$repository_root/tools/windows-discovery/probe/CGCEDiscoveryInventory/scripts/main.lua"
if LC_ALL=C grep -E \
    '(ExecuteInGameThread|SetPropertyValue|ProcessConsoleExec)' \
    "$probe" >/dev/null; then
    fail "CGCE-HANDOFF-PROBE: mutation or console surface is forbidden"
fi

find "$repository_root/tools/windows-discovery" \
    -type f \( -name '*.ps1' -o -name '*.psm1' \) -print |
    LC_ALL=C LANG=C sort |
    while IFS= read -r source; do
        if LC_ALL=C grep -E \
            '(Enter-PSSession|Invoke-Command|New-PSSession|New-NetFirewallRule|Set-NetFirewallRule|Set-Service|Start-Service)' \
            "$source" >/dev/null; then
            relative=${source#"$repository_root"/}
            fail "CGCE-HANDOFF-REMOTE-CONTROL: forbidden operator command: $relative"
        fi
    done

printf '%s\n' "WINDOWS_DISCOVERY_HANDOFF_VERIFIED"
