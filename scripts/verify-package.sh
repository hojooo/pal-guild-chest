#!/usr/bin/env sh
set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
package_root="$repository_root/CrossplayGuildChestExpander"
lua_runtime="$repository_root/third_party/lua-5.4.8/src/lua"
mode=${1:-}
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
    printf '%s\n' "usage: scripts/verify-package.sh discovery|release" >&2
    exit 2
fi

if [ "$mode" = "release" ]; then
    printf '%s\n' \
        "RELEASE_BUILD_BLOCKED: non-zero MinRevision is absent" \
        "RELEASE_BUILD_BLOCKED: Gate A acceptance is absent" \
        "RELEASE_BUILD_BLOCKED: exact runtime manifest checksum is absent" \
        "RELEASE_BUILD_BLOCKED: pinned Steam Windows/PS5/Mac certification is absent" \
        "RELEASE_BUILD_BLOCKED: Tasks 11-13 are incomplete" >&2
    exit 1
fi

if [ ! -x "$lua_runtime" ]; then
    printf '%s\n' "package verification requires the vendored Lua 5.4.8 runtime" >&2
    exit 1
fi

if find "$package_root" -type l -print | grep -q .; then
    printf '%s\n' "CGCE-PKG-SYMLINK: package symlinks are forbidden" >&2
    exit 1
fi

find "$package_root" -type f -print | LC_ALL=C sort | while IFS= read -r path; do
    relative=${path#"$package_root"/}
    lower=$(printf '%s' "$relative" | tr '[:upper:]' '[:lower:]')
    case "$relative" in
        Info.json|README.md|CHANGELOG.md|thumbnail.png|config/config.default.json|Scripts/bindings/README.md)
            ;;
        Scripts/*.lua)
            script_name=${relative#Scripts/}
            case "$script_name" in
                */*)
                    printf '%s\n' "CGCE-PKG-ALLOWLIST: nested Lua source is forbidden: $relative" >&2
                    exit 1
                    ;;
            esac
            script_allowed=false
            for allowed_script in $script_allowlist; do
                if [ "$script_name" = "$allowed_script" ]; then
                    script_allowed=true
                fi
            done
            if [ "$script_allowed" != "true" ]; then
                printf '%s\n' "CGCE-PKG-ALLOWLIST: unrecognized Lua source: $relative" >&2
                exit 1
            fi
            ;;
        *)
            printf '%s\n' "CGCE-PKG-ALLOWLIST: unrecognized package source: $relative" >&2
            exit 1
            ;;
    esac
    case "$lower" in
        *.pak|*.ucas|*.utoc|*.dll|*.dylib|*.so)
            printf '%s\n' "CGCE-PKG-CLIENT-ASSET: $relative" >&2
            exit 1
            ;;
        *logicmods*|*'/client/'*|*'/ui/'*|*'/input/'*)
            printf '%s\n' "CGCE-PKG-CLIENT-SURFACE: $relative" >&2
            exit 1
            ;;
        *resizer.lua|*replication.lua|*mutation_guard.lua)
            printf '%s\n' "CGCE-PKG-MUTATION-SURFACE: $relative" >&2
            exit 1
            ;;
        *.png)
            if [ "$relative" != "thumbnail.png" ]; then
                printf '%s\n' "CGCE-PKG-IMAGE-ASSET: only thumbnail.png is allowed" >&2
                exit 1
            fi
            ;;
    esac
    case "$relative" in
        Scripts/*.lua)
            if LC_ALL=C grep -E \
                '(function[[:space:]]+[A-Za-z0-9_.:]*(resize|append|mark_dirty|replicate|set_property|execute_in_game_thread)[[:space:]]*\(|(resize|append|mark_dirty|replicate|set_property|execute_in_game_thread)[[:space:]]*=[[:space:]]*function|(SetPropertyValue|ExecuteInGameThread|ContainerPtrToValuePtr|ImportText)[[:space:]]*\(|:[[:space:]]*(Empty|set)[[:space:]]*\()' \
                "$path" >/dev/null; then
                printf '%s\n' "CGCE-PKG-MUTATION-PRIMITIVE: $relative" >&2
                exit 1
            fi
            ;;
    esac
done

for allowed_script in $script_allowlist; do
    if [ ! -f "$package_root/Scripts/$allowed_script" ]; then
        printf '%s\n' \
            "CGCE-PKG-SCRIPT-SET: missing allow-listed Lua source: Scripts/$allowed_script" >&2
        exit 1
    fi
done

cd "$repository_root"
"$lua_runtime" - "$package_root/Info.json" "$package_root/thumbnail.png" <<'LUA'
package.path = "./?.lua;./?/init.lua;" .. package.path

local json = require("CrossplayGuildChestExpander.Scripts.json")
local info_path, thumbnail_path = arg[1], arg[2]

local function fail(code, detail)
    io.stderr:write(code, ": ", detail, "\n")
    os.exit(1)
end

local function read(path)
    local file = io.open(path, "rb")
    if file == nil then
        fail("CGCE-PKG-MISSING", path)
    end
    local bytes = file:read("*a")
    file:close()
    return bytes
end

local ok, info = pcall(json.decode, read(info_path))
if not ok or type(info) ~= "table" or json.encode(info):sub(1, 1) ~= "{" then
    fail("CGCE-PKG-INFO", "Info.json must be a JSON object")
end

local fields = {
    "ModName", "PackageName", "Thumbnail", "Version", "DebugMode",
    "MinRevision", "Author", "Dependencies", "Tags", "InstallRule",
}
local allowed = {}
for _, field in ipairs(fields) do allowed[field] = true end
for key in pairs(info) do
    if type(key) ~= "string" or not allowed[key] then
        fail("CGCE-PKG-INFO", "Info.json has an unknown key")
    end
end
for _, field in ipairs(fields) do
    if info[field] == nil then
        fail("CGCE-PKG-INFO", "Info.json is missing " .. field)
    end
end

local expected = {
    ModName = "Crossplay Guild Chest Expander — Discovery Build",
    PackageName = "CrossplayGuildChestExpander",
    Thumbnail = "thumbnail.png",
    Version = "1.1.0-discovery",
    DebugMode = false,
    MinRevision = 0,
    Author = "TBD",
}
for field, value in pairs(expected) do
    if info[field] ~= value then
        fail("CGCE-PKG-INFO", field .. " does not match the Discovery contract")
    end
end

local function exact_array(value, expected_values, field)
    if type(value) ~= "table" or #value ~= #expected_values then
        fail("CGCE-PKG-INFO", field .. " must be an exact dense array")
    end
    local count = 0
    for key in pairs(value) do
        if type(key) ~= "number" or math.type(key) ~= "integer" or key < 1 then
            fail("CGCE-PKG-INFO", field .. " must be an exact dense array")
        end
        count = count + 1
    end
    if count ~= #expected_values then
        fail("CGCE-PKG-INFO", field .. " must be an exact dense array")
    end
    for index, expected_value in ipairs(expected_values) do
        if value[index] ~= expected_value then
            fail("CGCE-PKG-INFO", field .. " contains an unsupported entry")
        end
    end
end

exact_array(info.Dependencies, { "UE4SS" }, "Dependencies")
exact_array(info.Tags, { "UE4SS", "Utilities", "Discovery" }, "Tags")
if type(info.InstallRule) ~= "table" or #info.InstallRule ~= 1 then
    fail("CGCE-PKG-INSTALL-RULE", "exactly one install rule is required")
end
local rule = info.InstallRule[1]
if type(rule) ~= "table" or rule.Type ~= "Lua" or rule.IsServer ~= true then
    fail("CGCE-PKG-INSTALL-RULE", "the sole install rule must be server-only Lua")
end
local rule_keys = { Type = true, IsServer = true, Targets = true }
for key in pairs(rule) do
    if type(key) ~= "string" or not rule_keys[key] then
        fail("CGCE-PKG-INSTALL-RULE", "the install rule has an unknown key")
    end
end
exact_array(rule.Targets, { "./Scripts" }, "InstallRule.Targets")

local thumbnail = read(thumbnail_path)
if #thumbnail < 24 or #thumbnail > 1024 * 1024
    or thumbnail:sub(1, 8) ~= "\137PNG\r\n\26\n" then
    fail("CGCE-PKG-THUMBNAIL", "thumbnail.png must be a real PNG smaller than 1 MiB")
end

io.write("DISCOVERY_PACKAGE_VERIFIED\n")
LUA
