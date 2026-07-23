#!/usr/bin/env sh
set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
mode=${1:-}
output_path=${2:-"$repository_root/dist/CrossplayGuildChestExpander-1.1.0-discovery.zip"}
script_allowlist='approval.lua
audit.lua
binding_manifest.lua
binding_symbols.lua
certification.lua
cgce.lua
command_router.lua
config.lua
conflict_detector.lua
constants.lua
container_resolver.lua
discovery_evidence.lua
discovery_probe.lua
fingerprint.lua
gate_a_evidence.lua
guild_repository.lua
json.lua
ledger.lua
logger.lua
main.lua
path_guard.lua
platform_preflight.lua
report.lua
revision_guard.lua
scheduler.lua
sha256.lua
snapshot.lua
state_machine.lua
ue4ss_adapter.lua
validator.lua
world_ready.lua'

if [ "$mode" != "discovery" ] && [ "$mode" != "release" ]; then
    printf '%s\n' "usage: scripts/build-release.sh discovery|release [output.zip]" >&2
    exit 2
fi

if [ "$mode" = "release" ]; then
    "$repository_root/scripts/verify-package.sh" release
    exit 1
fi

"$repository_root/scripts/verify-package.sh" discovery

case "$output_path" in
    /*) ;;
    *) output_path="$PWD/$output_path" ;;
esac

if [ -e "$output_path" ]; then
    printf '%s\n' "CGCE-PKG-OUTPUT-EXISTS: refusing to overwrite $output_path" >&2
    exit 1
fi

output_directory=$(dirname -- "$output_path")
mkdir -p "$output_directory"
staging_root=$(mktemp -d "${TMPDIR:-/tmp}/cgce-discovery.XXXXXX")

cleanup() {
    case "$staging_root" in
        "${TMPDIR:-/tmp}"/cgce-discovery.*) find "$staging_root" -depth -delete ;;
        *) printf '%s\n' "CGCE-PKG-CLEANUP: unsafe staging path" >&2 ;;
    esac
}
trap cleanup EXIT HUP INT TERM

source_root="$repository_root/CrossplayGuildChestExpander"
target_root="$staging_root/CrossplayGuildChestExpander"
mkdir -p "$target_root/Scripts" "$target_root/config"

for relative in Info.json README.md CHANGELOG.md thumbnail.png config/config.default.json; do
    cp "$source_root/$relative" "$target_root/$relative"
done

for script_name in $script_allowlist; do
    cp "$source_root/Scripts/$script_name" "$target_root/Scripts/$script_name"
done

find "$staging_root" -type d -exec chmod 0755 {} \;
find "$staging_root" -type f -exec chmod 0644 {} \;
find "$staging_root" -exec touch -t 198001010000 {} \;

(
    cd "$staging_root"
    find CrossplayGuildChestExpander -type f -print \
        | LC_ALL=C sort \
        | zip -X -q "$output_path" -@
)

printf '%s\n' "DISCOVERY_ARCHIVE_BUILT $output_path"
