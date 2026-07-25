#!/usr/bin/env sh
set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
output_path=${1:-"$repository_root/dist/CGCE-Windows-Discovery-Handoff.zip"}
handoff_paths='tests/windows/Contract.Tests.ps1
tests/windows/Files.Tests.ps1
tests/windows/fixtures/FakePalServer.cmd
tests/windows/Lifecycle.Tests.ps1
tests/windows/Run-CgceDiscoverySmokeTests.ps1
tests/windows/Run-CgceDiscoveryTests.ps1
tests/windows/Runtime.Tests.ps1
tests/windows/Smoke.Tests.ps1
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

fail() {
    printf '%s\n' "$1" >&2
    exit 1
}

"$repository_root/scripts/verify-discovery-handoff.sh"

dirty=$(git -C "$repository_root" status --porcelain=v1 -- \
    tools/windows-discovery \
    tests/windows \
    scripts/verify-discovery-handoff.sh \
    scripts/build-discovery-handoff.sh)
if [ -n "$dirty" ]; then
    fail "CGCE-HANDOFF-DIRTY: included source paths must be tracked and clean"
fi

case "$output_path" in
    /*) ;;
    *) output_path="$PWD/$output_path" ;;
esac
sidecar_path="$output_path.sha256"
sidecar_temp="$sidecar_path.tmp"
if [ -e "$output_path" ] || [ -e "$sidecar_path" ] || \
    [ -e "$sidecar_temp" ]; then
    fail "CGCE-HANDOFF-OUTPUT-EXISTS: refusing to overwrite output"
fi

output_directory=$(dirname -- "$output_path")
mkdir -p "$output_directory"
staging_root=$(mktemp -d "${TMPDIR:-/tmp}/cgce-windows-discovery.XXXXXX")

cleanup() {
    case "$staging_root" in
        "${TMPDIR:-/tmp}"/cgce-windows-discovery.*)
            find "$staging_root" -depth -delete
            ;;
        *)
            printf '%s\n' \
                "CGCE-HANDOFF-CLEANUP: unsafe staging path" >&2
            ;;
    esac
    if [ -e "$sidecar_temp" ]; then
        find "$sidecar_temp" -delete
    fi
}
trap cleanup EXIT HUP INT TERM

archive_root_name=CGCE-Windows-Discovery-Handoff
target_root="$staging_root/$archive_root_name"
mkdir -p "$target_root"

for relative in $handoff_paths; do
    source="$repository_root/$relative"
    destination="$target_root/$relative"
    mkdir -p "$(dirname -- "$destination")"
    cp "$source" "$destination"
done

(
    cd "$target_root"
    printf '%s\n' "$handoff_paths" |
        LC_ALL=C LANG=C sort |
        while IFS= read -r relative; do
            LC_ALL=C LANG=C shasum -a 256 "$relative"
        done
) > "$target_root/source-manifest.sha256"

find "$staging_root" -type d -exec chmod 0755 {} \;
find "$staging_root" -type f -exec chmod 0644 {} \;
TZ=UTC find "$staging_root" -exec touch -t 198001010000 {} \;

(
    cd "$staging_root"
    LC_ALL=C LANG=C find "$archive_root_name" -type f -print |
        LC_ALL=C LANG=C sort |
        zip -X -q "$output_path" -@
)

output_name=${output_path##*/}
(
    cd "$output_directory"
    LC_ALL=C LANG=C shasum -a 256 "$output_name"
) > "$sidecar_temp"
if [ -e "$sidecar_path" ]; then
    fail "CGCE-HANDOFF-OUTPUT-EXISTS: sidecar appeared during build"
fi
mv "$sidecar_temp" "$sidecar_path"

printf '%s\n' "WINDOWS_DISCOVERY_HANDOFF_BUILT $output_path"
