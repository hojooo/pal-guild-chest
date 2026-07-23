local a = require("tests.support.assertions")
local json = require("CrossplayGuildChestExpander.Scripts.json")
local sha256_module = require("CrossplayGuildChestExpander.Scripts.sha256")

local function read(path)
    local file = assert(io.open(path, "rb"))
    local content = file:read("*a")
    file:close()
    return content
end

local function shell_quote(value)
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function run(command)
    local pipe = assert(io.popen(command .. " 2>&1"))
    local output = pipe:read("*a")
    local ok, why, code = pipe:close()
    return ok == true and code == 0, output, why, code
end

local function must_run(command)
    local ok, output = run(command)
    if not ok then
        error(output, 0)
    end
end

local function write(path, content)
    local file = assert(io.open(path, "wb"))
    assert(file:write(content))
    assert(file:close())
end

local function temporary_path(suffix)
    local path = os.tmpname() .. suffix
    os.remove(path)
    return path
end

local function stage_package_repository()
    local root = temporary_path("-cgce-package-fixture")
    must_run("mkdir -p " .. shell_quote(root .. "/scripts"))
    must_run("mkdir -p " .. shell_quote(root .. "/third_party/lua-5.4.8/src"))
    must_run(table.concat({
        "cp -R CrossplayGuildChestExpander",
        shell_quote(root .. "/CrossplayGuildChestExpander"),
    }, " "))
    must_run(table.concat({
        "cp scripts/verify-package.sh scripts/build-release.sh",
        shell_quote(root .. "/scripts/"),
    }, " "))
    must_run(table.concat({
        "cp third_party/lua-5.4.8/src/lua",
        shell_quote(root .. "/third_party/lua-5.4.8/src/lua"),
    }, " "))
    return root
end

local function remove_tree(path)
    must_run("find " .. shell_quote(path) .. " -depth -delete")
end

local function sha256(path)
    return sha256_module.hex(read(path))
end

local function archive_entries(path)
    local ok, output = run("unzip -Z1 " .. shell_quote(path))
    a.equal(true, ok)
    local entries = {}
    for line in output:gmatch("[^\r\n]+") do
        entries[#entries + 1] = line
    end
    return entries
end

local packaged_scripts = {
    "approval.lua",
    "audit.lua",
    "binding_manifest.lua",
    "binding_symbols.lua",
    "certification.lua",
    "cgce.lua",
    "command_router.lua",
    "config.lua",
    "conflict_detector.lua",
    "constants.lua",
    "container_resolver.lua",
    "discovery_evidence.lua",
    "discovery_probe.lua",
    "fingerprint.lua",
    "gate_a_evidence.lua",
    "guild_repository.lua",
    "json.lua",
    "ledger.lua",
    "logger.lua",
    "main.lua",
    "path_guard.lua",
    "platform_preflight.lua",
    "report.lua",
    "revision_guard.lua",
    "scheduler.lua",
    "sha256.lua",
    "snapshot.lua",
    "state_machine.lua",
    "ue4ss_adapter.lua",
    "validator.lua",
    "world_ready.lua",
}

local function expected_archive_entries()
    local entries = {
        "CrossplayGuildChestExpander/CHANGELOG.md",
        "CrossplayGuildChestExpander/Info.json",
        "CrossplayGuildChestExpander/README.md",
        "CrossplayGuildChestExpander/config/config.default.json",
        "CrossplayGuildChestExpander/thumbnail.png",
    }
    for _, script in ipairs(packaged_scripts) do
        entries[#entries + 1] = "CrossplayGuildChestExpander/Scripts/" .. script
    end
    table.sort(entries)
    return entries
end

local function table_row_count(text, prefix)
    local count = 0
    for line in text:gmatch("[^\r\n]+") do
        if line:match("^| " .. prefix) then
            count = count + 1
        end
    end
    return count
end

local function exact_row_count(text, identifier)
    local count = 0
    local marker = "| " .. identifier .. " |"
    local start = 1
    while true do
        local found = text:find(marker, start, true)
        if found == nil then
            return count
        end
        count = count + 1
        start = found + #marker
    end
end

describe("Discovery package", function()
    it("declares one server-only Lua rule without claiming client compatibility", function()
        local info = json.decode(read("CrossplayGuildChestExpander/Info.json"))

        a.equal("Crossplay Guild Chest Expander — Discovery Build", info.ModName)
        a.equal("CrossplayGuildChestExpander", info.PackageName)
        a.equal("thumbnail.png", info.Thumbnail)
        a.equal("1.1.0-discovery", info.Version)
        a.equal(false, info.DebugMode)
        a.equal(0, info.MinRevision)
        a.equal("TBD", info.Author)
        a.deep_equal({ "UE4SS" }, info.Dependencies)
        a.deep_equal({ "UE4SS", "Utilities", "Discovery" }, info.Tags)
        a.deep_equal({ {
            Type = "Lua",
            IsServer = true,
            Targets = { "./Scripts" },
        } }, info.InstallRule)

        local encoded = json.encode(info)
        a.equal(nil, encoded:find("SteamWindows compatible", 1, true))
        a.equal(nil, encoded:find("PS5 compatible", 1, true))
        a.equal(nil, encoded:find("Mac compatible", 1, true))
    end)

    it("accepts only the non-release Discovery package", function()
        local discovery_ok, discovery_output = run("scripts/verify-package.sh discovery")
        a.equal(true, discovery_ok)
        a.equal(true, discovery_output:find("DISCOVERY_PACKAGE_VERIFIED", 1, true) ~= nil)

        local release_ok, release_output = run("scripts/verify-package.sh release")
        a.equal(false, release_ok)
        for _, blocker in ipairs({
            "non-zero MinRevision",
            "Gate A acceptance",
            "exact runtime manifest checksum",
            "pinned Steam Windows/PS5/Mac certification",
            "Tasks 11-13",
        }) do
            a.equal(true, release_output:find(blocker, 1, true) ~= nil)
        end
    end)

    it("rejects assignment-form mutation primitives in the standalone verifier and builder", function()
        local root = stage_package_repository()
        local source_path = root
            .. "/CrossplayGuildChestExpander/Scripts/approval.lua"
        local verifier = shell_quote(root .. "/scripts/verify-package.sh")
        local results = {}
        local snippets = {
            "local resize = function() end\nreturn {}\n",
            "local append = function() end\nreturn {}\n",
            "local mark_dirty = function() end\nreturn {}\n",
            "local replicate = function() end\nreturn {}\n",
            "local set_property = function() end\nreturn {}\n",
            "local execute_in_game_thread = function() end\nreturn {}\n",
            "return { call = function(target) target:set('x', 1) end }\n",
        }

        for _, snippet in ipairs(snippets) do
            write(source_path, snippet)
            local ok, output = run(verifier .. " discovery")
            results[#results + 1] = { ok = ok, output = output }
        end

        write(source_path, snippets[1])
        local output_path = root .. "/assignment-mutation.zip"
        local build_ok, build_output = run(table.concat({
            shell_quote(root .. "/scripts/build-release.sh"),
            "discovery",
            shell_quote(output_path),
        }, " "))
        local archive = io.open(output_path, "rb")
        local archive_created = archive ~= nil
        if archive ~= nil then archive:close() end
        remove_tree(root)

        for _, result in ipairs(results) do
            a.equal(false, result.ok)
            a.equal(true, result.output:find("CGCE-PKG-MUTATION-PRIMITIVE", 1, true) ~= nil)
        end
        a.equal(false, build_ok)
        a.equal(true, build_output:find("CGCE-PKG-MUTATION-PRIMITIVE", 1, true) ~= nil)
        a.equal(false, archive_created)
    end)

    it("rejects a missing allow-listed Lua module before verification or build", function()
        local root = stage_package_repository()
        assert(os.remove(root .. "/CrossplayGuildChestExpander/Scripts/approval.lua"))
        local verifier = shell_quote(root .. "/scripts/verify-package.sh")
        local verify_ok, verify_output = run(verifier .. " discovery")
        local output_path = root .. "/missing-module.zip"
        local build_ok, build_output = run(table.concat({
            shell_quote(root .. "/scripts/build-release.sh"),
            "discovery",
            shell_quote(output_path),
        }, " "))
        local archive = io.open(output_path, "rb")
        local archive_created = archive ~= nil
        if archive ~= nil then archive:close() end
        remove_tree(root)

        a.equal(false, verify_ok)
        a.equal(true, verify_output:find("CGCE-PKG-SCRIPT-SET", 1, true) ~= nil)
        a.equal(false, build_ok)
        a.equal(true, build_output:find("CGCE-PKG-SCRIPT-SET", 1, true) ~= nil)
        a.equal(false, archive_created)
    end)

    it("builds byte-for-byte deterministic allow-listed archives", function()
        local first = temporary_path("-cgce-discovery-a.zip")
        local second = temporary_path("-cgce-discovery-b.zip")

        local first_ok, first_output = run(
            "scripts/build-release.sh discovery " .. shell_quote(first)
        )
        local second_ok, second_output = run(
            "scripts/build-release.sh discovery " .. shell_quote(second)
        )
        a.equal(true, first_ok)
        a.equal(true, second_ok)
        a.equal(true, first_output:find("DISCOVERY_ARCHIVE_BUILT", 1, true) ~= nil)
        a.equal(true, second_output:find("DISCOVERY_ARCHIVE_BUILT", 1, true) ~= nil)
        a.equal(sha256(first), sha256(second))

        local entries = archive_entries(first)
        a.deep_equal(expected_archive_entries(), entries)
        local seen = {}
        local previous = ""
        for _, entry in ipairs(entries) do
            a.equal(true, entry > previous)
            previous = entry
            seen[entry] = true
            a.equal(nil, entry:lower():match("%.(pak|ucas|utoc|dll|dylib|so)$"))
            a.equal(nil, entry:find("private-artifacts", 1, true))
            a.equal(nil, entry:find("/tests/", 1, true))
            a.equal(nil, entry:find("/third_party/", 1, true))
            a.equal(nil, entry:lower():find("logicmods", 1, true))
        end
        a.equal(true, seen["CrossplayGuildChestExpander/Info.json"])
        a.equal(true, seen["CrossplayGuildChestExpander/thumbnail.png"])
        a.equal(true, seen["CrossplayGuildChestExpander/Scripts/gate_a_evidence.lua"])
        a.equal(nil, seen["CrossplayGuildChestExpander/Scripts/bindings/README.md"])

        os.remove(first)
        os.remove(second)
    end)

    it("never creates a release archive in the Discovery milestone", function()
        local output_path = temporary_path("-cgce-release.zip")
        local ok, output = run(
            "scripts/build-release.sh release " .. shell_quote(output_path)
        )
        a.equal(false, ok)
        a.equal(true, output:find("RELEASE_BUILD_BLOCKED", 1, true) ~= nil)
        a.equal(nil, io.open(output_path, "rb"))
    end)

    it("keeps private evidence ignored and mutation surfaces absent", function()
        local ignored, ignore_output = run("git check-ignore private-artifacts/example.json")
        a.equal(true, ignored)
        a.equal(true, ignore_output:find("private-artifacts/example.json", 1, true) ~= nil)

        local ok, tracked = run(
            "git ls-files --cached --others --exclude-standard -- CrossplayGuildChestExpander"
        )
        a.equal(true, ok)
        local lower = tracked:lower()
        for _, forbidden in ipairs({
            "/resizer.lua",
            "/replication.lua",
            "/mutation_guard.lua",
            "/client/",
            "/ui/",
            "/input/",
            "/logicmods/",
        }) do
            a.equal(nil, lower:find(forbidden, 1, true))
        end
    end)

    it("documents every requirement exactly once without promoting blocked evidence", function()
        local traceability = read("docs/requirements-traceability.md")
        local fr_ids = {
            "FR-001", "FR-002", "FR-003", "FR-004", "FR-005", "FR-006", "FR-007",
            "FR-010", "FR-011", "FR-012", "FR-013", "FR-014", "FR-015", "FR-016",
            "FR-017", "FR-020", "FR-021", "FR-022", "FR-023", "FR-030", "FR-031",
            "FR-032", "FR-033", "FR-034", "FR-035", "FR-036", "FR-037", "FR-038",
        }
        for _, identifier in ipairs(fr_ids) do
            a.equal(1, exact_row_count(traceability, identifier))
        end
        for index = 1, 17 do
            a.equal(1, exact_row_count(traceability, string.format("AT-%03d", index)))
        end
        for index = 1, 30 do
            a.equal(1, exact_row_count(traceability, string.format("DOD-%02d", index)))
        end
        for index = 1, 20 do
            a.equal(1, exact_row_count(traceability, string.format("SPIKE-%02d", index)))
        end
        a.equal(28, table_row_count(traceability, "FR%-"))
        a.equal(17, table_row_count(traceability, "AT%-"))
        a.equal(30, table_row_count(traceability, "DOD%-"))
        a.equal(20, table_row_count(traceability, "SPIKE%-"))

        for index = 1, 17 do
            local marker = string.format("| AT-%03d | BLOCKED_", index)
            a.equal(true, traceability:find(marker, 1, true) ~= nil)
        end
        for index = 1, 20 do
            local marker = string.format("| SPIKE-%02d | BLOCKED_", index)
            a.equal(true, traceability:find(marker, 1, true) ~= nil)
        end
    end)

    it("documents the complete three-client certification and rollback runbook", function()
        local runbook = read("docs/certification-runbook.md")
        for _, required in ipairs({
            "54 → 120 → 256 → 358",
            "Steam Windows",
            "PS5",
            "macOS",
            "Community Server",
            "DualSense",
            "D-pad",
            "last slot",
            "whole-world backup",
            "removal",
            "rollback",
            "six-hour soak",
            "CPU ≤ 1 percentage point",
            "memory ≤ 100 MB",
            "100-guild audit ≤ 5 seconds",
            "100 empty migrations ≤ 10 seconds",
            "54→358 migration ≤ 100 ms",
            "save-time increase ≤ 15%",
            "open-chest p95 ≤ baseline + 300 ms",
            "reconnect-time increase ≤ 10%",
            "BLOCKED",
            "Xbox is optional",
        }) do
            a.equal(true, runbook:find(required, 1, true) ~= nil)
        end
    end)
end)
