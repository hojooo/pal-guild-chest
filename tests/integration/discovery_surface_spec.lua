local a = require("tests.support.assertions")
local audit = require("CrossplayGuildChestExpander.Scripts.audit")
local state_machine = require("CrossplayGuildChestExpander.Scripts.state_machine")

local forbidden_exports = {
    resize = true,
    append = true,
    mark_dirty = true,
    replicate = true,
    set_property = true,
    execute_in_game_thread = true,
}

local production_names = {
    "approval",
    "audit",
    "binding_manifest",
    "binding_symbols",
    "certification",
    "cgce",
    "command_router",
    "config",
    "conflict_detector",
    "constants",
    "container_resolver",
    "discovery_evidence",
    "discovery_probe",
    "fingerprint",
    "gate_a_evidence",
    "guild_repository",
    "json",
    "ledger",
    "logger",
    "main",
    "path_guard",
    "platform_preflight",
    "report",
    "revision_guard",
    "scheduler",
    "sha256",
    "snapshot",
    "state_machine",
    "ue4ss_adapter",
    "validator",
    "world_ready",
}

local production_modules = {}
for index, name in ipairs(production_names) do
    production_modules[index] = "CrossplayGuildChestExpander.Scripts." .. name
end

local function repository_production_names()
    local pipe = assert(io.popen(table.concat({
        "git ls-files --cached --others --exclude-standard --",
        '"CrossplayGuildChestExpander/Scripts/*.lua"',
    }, " ")))
    local names = {}
    for path in pipe:lines() do
        names[#names + 1] = assert(path:match("Scripts/([^/]+)%.lua$"))
    end
    assert(pipe:close())
    table.sort(names)
    return names
end

local forbidden_source_patterns = {
    "function%s+[%w_%.:]*resize%s*%(",
    "function%s+[%w_%.:]*append%s*%(",
    "function%s+[%w_%.:]*mark_dirty%s*%(",
    "function%s+[%w_%.:]*replicate%s*%(",
    "function%s+[%w_%.:]*set_property%s*%(",
    "function%s+[%w_%.:]*execute_in_game_thread%s*%(",
    "local%s+resize%s*=%s*function",
    "local%s+append%s*=%s*function",
    "local%s+mark_dirty%s*=%s*function",
    "local%s+replicate%s*=%s*function",
    "local%s+set_property%s*=%s*function",
    "local%s+execute_in_game_thread%s*=%s*function",
    "resize%s*=%s*function",
    "append%s*=%s*function",
    "mark_dirty%s*=%s*function",
    "replicate%s*=%s*function",
    "set_property%s*=%s*function",
    "execute_in_game_thread%s*=%s*function",
    "SetPropertyValue%s*%(",
    "ExecuteInGameThread%s*%(",
    "ContainerPtrToValuePtr%s*%(",
    "ImportText%s*%(",
    ":%s*Empty%s*%(",
    ":%s*set%s*%(",
}

local function read(path)
    local file = assert(io.open(path, "rb"))
    local content = file:read("*a")
    file:close()
    return content
end

describe("discovery build surface", function()
    it("keeps the production source catalog exact", function()
        a.deep_equal(production_names, repository_production_names())
    end)

    it("exports no write-capable adapter operation", function()
        for _, module_name in ipairs(production_modules) do
            local module = require(module_name)
            for key in pairs(module) do
                a.equal(false, forbidden_exports[key] == true)
            end
        end
    end)

    it("defines and calls no mutation primitive in any production Lua source", function()
        for _, name in ipairs(production_names) do
            local source = read("CrossplayGuildChestExpander/Scripts/" .. name .. ".lua")
            for _, pattern in ipairs(forbidden_source_patterns) do
                a.equal(nil, source:match(pattern))
            end
        end
    end)

    it("contains no mutating state node or edge identifier in production", function()
        local source = read("CrossplayGuildChestExpander/Scripts/state_machine.lua")
        for _, identifier in ipairs({
            "APPLYING",
            "VALIDATING",
            "COMPLETE",
            "FAILED_AFTER_MUTATION",
        }) do
            local pattern = "%f[%w_]" .. identifier .. "%f[^%w_]"
            a.equal(nil, source:match(pattern))
        end
    end)

    it("does not let callers inject a state or replace transition behavior", function()
        local machine = state_machine.new({ mutation_capability = false })

        local state_write_ok = pcall(function()
            rawset(machine, "_state", "injected")
        end)
        local method_write_ok = pcall(function()
            rawset(machine, "transition", function() return "injected" end)
        end)

        a.equal(false, state_write_ok)
        a.equal(false, method_write_ok)
        a.equal("function", type(machine))
        a.equal("DISABLED", state_machine.state(machine))
    end)

    it("loads the audit behind write traps without accessing any trap", function()
        local context = {
            world_id = "world/surface-test",
            game_revision = 12345,
            deployment_profile = "windows-dedicated-ps5-macos-required",
            target_slots = 358,
            include_guild_ids = {},
            exclude_guild_ids = {},
            list_guilds = function()
                return {}
            end,
            resolve_guild_chest = function()
                error("resolver must not run for an empty guild list")
            end,
            snapshot_container = function()
                error("snapshot must not run for an empty guild list")
            end,
        }
        setmetatable(context, {
            __index = function(_, key)
                if forbidden_exports[key] then
                    error("write-capable trap accessed")
                end
                return nil
            end,
        })

        local result = audit.to_table(audit.capture(context))

        a.deep_equal({}, result.guilds)
        a.deep_equal({}, result.blocking_errors)
    end)

    it("exposes audit data only through trusted module functions", function()
        local context = {
            world_id = "world/opaque-audit",
            game_revision = 12345,
            deployment_profile = "windows-dedicated-ps5-macos-required",
            target_slots = 358,
            include_guild_ids = {},
            exclude_guild_ids = {},
            list_guilds = function() return {} end,
            resolve_guild_chest = function() error("must not run") end,
            snapshot_container = function() error("must not run") end,
        }
        local handle = audit.capture(context)

        local direct_ok = pcall(function() return handle.world_id end)
        local rawset_ok = pcall(function() rawset(handle, "checksum", "shadow") end)

        a.equal("function", type(handle))
        a.equal(false, direct_ok)
        a.equal(false, rawset_ok)
        a.equal(audit.to_table(handle).checksum, audit.checksum(handle))
    end)
end)
