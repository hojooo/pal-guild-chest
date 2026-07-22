local a = require("tests.support.assertions")
local audit = require("CrossplayGuildChestExpander.Scripts.audit")
local guild_repository = require("CrossplayGuildChestExpander.Scripts.guild_repository")
local json = require("CrossplayGuildChestExpander.Scripts.json")
local revision_guard = require("CrossplayGuildChestExpander.Scripts.revision_guard")
local runtime_binding_fixture = require("tests.support.runtime_binding_fixture")
local ue4ss_adapter = require("CrossplayGuildChestExpander.Scripts.ue4ss_adapter")
local world_ready = require("CrossplayGuildChestExpander.Scripts.world_ready")

local function ready_epoch(runtime)
    local detector = world_ready.start({
        adapter = runtime.adapter,
        binding_session = runtime.binding_session,
        schedule = function()
            error("an immediately ready world must not schedule a timer")
        end,
        cancel = function()
            error("an immediately ready world must not cancel a timer")
        end,
    })
    a.equal("READY", world_ready.status(detector).state)
    local epoch = world_ready.epoch(detector)
    a.equal("function", type(epoch))
    return detector, epoch
end

local function list(runtime, epoch, extra)
    local options = {
        adapter = runtime.adapter,
        binding_session = runtime.binding_session,
        world_epoch = epoch,
    }
    for key, value in pairs(extra or {}) do
        options[key] = value
    end
    return guild_repository.list(options)
end

local function expect_problem(code, field, operation)
    local ok, err = pcall(operation)
    a.equal(false, ok)
    a.equal("table", type(err))
    a.equal(code, err.code)
    a.equal(field, err.field)
    a.equal("string", type(err.detail))
    a.equal(nil, err.detail:find("0x", 1, true))
    return err
end

local forbidden_counter_names = {
    "function_invoke",
    "raw_property_write",
    "tarray_write",
    "element_set",
    "element_other_access",
    "array_empty",
    "array_index_write",
    "array_callback_non_nil",
    "constructor",
    "tostring",
    "raw_eq",
}

local function assert_zero_forbidden(runtime)
    local counters = runtime.fake.counters()
    for _, name in ipairs(forbidden_counter_names) do
        a.equal(0, counters[name])
    end
end

local function assert_detached(value, seen)
    seen = seen or {}
    if type(value) ~= "table" then
        local kind = type(value)
        a.equal(true, kind == "string" or kind == "number" or kind == "boolean")
        return
    end
    a.equal(nil, getmetatable(value))
    a.equal(false, seen[value] == true)
    seen[value] = true
    for key, item in pairs(value) do
        a.equal(true, type(key) == "string" or type(key) == "number")
        assert_detached(item, seen)
    end
end

local function find_guild(value, guild_id)
    for _, record in ipairs(value.guilds) do
        if record.guild_id == guild_id then
            return record
        end
    end
    error("guild not found")
end

local function has_error(errors, code)
    for _, value in ipairs(errors) do
        if value.code == code then
            return true
        end
    end
    return false
end

describe("guild_repository exact selected-world traversal", function()
    it("returns a detached deterministic projection sorted by opaque guild ID", function()
        local runtime = runtime_binding_fixture.new()
        runtime:add_guild("guild/z", "Zulu", "container/z")
        runtime:add_guild("guild/a", "", nil)
        runtime:add_guild("guild/m", "Middle", "container/m")
        local detector, epoch = ready_epoch(runtime)

        local first = list(runtime, epoch)
        a.deep_equal({
            { guild_id = "guild/a", guild_name = "" },
            { guild_id = "guild/m", guild_name = "Middle", chest_container_id = "container/m" },
            { guild_id = "guild/z", guild_name = "Zulu", chest_container_id = "container/z" },
        }, first)
        assert_detached(first)

        first[1].guild_id = "forged"
        first[2].chest_container_id = nil
        local second = list(runtime, epoch)
        a.equal("guild/a", second[1].guild_id)
        a.equal("container/m", second[2].chest_container_id)
        a.equal(json.encode(second), json.encode(list(runtime, epoch)))

        a.equal(true, world_ready.close(detector))
        assert_zero_forbidden(runtime)
    end)

    it("allows an empty current-world guild list with no loaded guild instances", function()
        local runtime = runtime_binding_fixture.new()
        local detector, epoch = ready_epoch(runtime)

        a.equal("[]", json.encode(list(runtime, epoch)))

        a.equal(true, world_ready.close(detector))
        assert_zero_forbidden(runtime)
    end)

    it("rejects a null guild-list property instead of treating it as an empty TArray", function()
        local runtime = runtime_binding_fixture.new()
        runtime:set_guild_list_null()
        local detector, epoch = ready_epoch(runtime)

        expect_problem("CGCE-GUILD-LIST", "guild_list", function()
            list(runtime, epoch)
        end)

        a.equal(true, world_ready.close(detector))
        assert_zero_forbidden(runtime)
    end)

    it("keeps a null chest ID unresolved and lets audit classify it as not initialized", function()
        local runtime = runtime_binding_fixture.new()
        runtime:add_guild("guild/new", "New", nil)
        local detector, epoch = ready_epoch(runtime)
        local resolve_calls = 0
        local snapshot_calls = 0

        local captured = audit.to_table(audit.capture({
            world_id = "test-world-alpha",
            game_revision = runtime.manifest.game_revision,
            deployment_profile = "windows-dedicated-ps5-macos-required",
            target_slots = 358,
            include_guild_ids = {},
            exclude_guild_ids = {},
            list_guilds = function()
                return list(runtime, epoch)
            end,
            resolve_guild_chest = function()
                resolve_calls = resolve_calls + 1
                error("a null chest ID must not be resolved")
            end,
            snapshot_container = function()
                snapshot_calls = snapshot_calls + 1
                error("a null chest ID must not be snapshotted")
            end,
        }))

        a.equal("not_initialized", captured.guilds[1].status)
        a.equal(nil, captured.guilds[1].chest_container_id)
        a.equal(0, resolve_calls)
        a.equal(0, snapshot_calls)
        a.deep_equal({}, captured.blocking_errors)
        a.equal(true, world_ready.close(detector))
        assert_zero_forbidden(runtime)
    end)

    it("preserves duplicate chest IDs so audit blocks every referencing guild", function()
        local runtime = runtime_binding_fixture.new()
        runtime:add_guild("guild/b", "B", "container/shared")
        runtime:add_guild("guild/a", "A", "container/shared")
        local detector, epoch = ready_epoch(runtime)
        local resolve_calls = 0

        local captured = audit.to_table(audit.capture({
            world_id = "test-world-alpha",
            game_revision = runtime.manifest.game_revision,
            deployment_profile = "windows-dedicated-ps5-macos-required",
            target_slots = 358,
            include_guild_ids = {},
            exclude_guild_ids = {},
            list_guilds = function()
                return list(runtime, epoch)
            end,
            resolve_guild_chest = function()
                resolve_calls = resolve_calls + 1
                error("duplicate chest IDs must block before resolution")
            end,
            snapshot_container = function()
                error("duplicate chest IDs must block before snapshot")
            end,
        }))

        a.equal("blocked", find_guild(captured, "guild/a").status)
        a.equal("blocked", find_guild(captured, "guild/b").status)
        a.equal(true, has_error(find_guild(captured, "guild/a").errors, "CGCE-AUD-DUPLICATE-CONTAINER"))
        a.equal(true, has_error(find_guild(captured, "guild/b").errors, "CGCE-AUD-DUPLICATE-CONTAINER"))
        a.equal(true, has_error(captured.blocking_errors, "CGCE-AUD-DUPLICATE-CONTAINER"))
        a.equal(0, resolve_calls)
        a.equal(true, world_ready.close(detector))
        assert_zero_forbidden(runtime)
    end)

    it("rejects guild handles absent from or duplicated in the exact class inventory", function()
        local missing = runtime_binding_fixture.new()
        missing:add_guild("guild/missing", "Missing", "container/missing", { loaded = false })
        local missing_detector, missing_epoch = ready_epoch(missing)
        expect_problem("CGCE-GUILD-CLASS-RELATION", "guilds[1]", function()
            list(missing, missing_epoch)
        end)
        a.equal(true, world_ready.close(missing_detector))
        assert_zero_forbidden(missing)

        local duplicate = runtime_binding_fixture.new()
        local duplicated = duplicate:add_guild("guild/duplicate", "Duplicate", "container/duplicate")
        duplicate:duplicate_guild_inventory(duplicated)
        local duplicate_detector, duplicate_epoch = ready_epoch(duplicate)
        expect_problem("CGCE-GUILD-CLASS-RELATION", "guilds[1]", function()
            list(duplicate, duplicate_epoch)
        end)
        a.equal(true, world_ready.close(duplicate_detector))
        assert_zero_forbidden(duplicate)
    end)

    it("rejects duplicate guild IDs", function()
        local runtime = runtime_binding_fixture.new()
        runtime:add_guild("guild/shared", "First", "container/a")
        runtime:add_guild("guild/shared", "Second", "container/b")
        local detector, epoch = ready_epoch(runtime)

        expect_problem("CGCE-GUILD-DUPLICATE-ID", "guild_id", function()
            list(runtime, epoch)
        end)

        a.equal(true, world_ready.close(detector))
        assert_zero_forbidden(runtime)
    end)

    it("rejects malformed guild scalar projections without stringifying raw values", function()
        local cases = {
            {
                field = "guilds[1].guild_id",
                mutate = function(runtime, guild) runtime:set_guild_id(guild, "") end,
            },
            {
                field = "guilds[1].guild_id",
                mutate = function(runtime, guild) runtime:set_guild_id(guild, string.char(255)) end,
            },
            {
                field = "guilds[1].guild_id",
                mutate = function(runtime, guild) runtime:set_guild_id(guild, 123) end,
            },
            {
                field = "guilds[1].guild_name",
                mutate = function(runtime, guild) runtime:set_guild_name(guild, nil) end,
            },
            {
                field = "guilds[1].chest_container_id",
                mutate = function(runtime, guild) runtime:set_guild_chest_id(guild, "") end,
            },
            {
                field = "guilds[1].chest_container_id",
                mutate = function(runtime, guild) runtime:set_guild_chest_id(guild, false) end,
            },
        }

        for _, case in ipairs(cases) do
            local runtime = runtime_binding_fixture.new()
            local guild = runtime:add_guild("guild/valid", "Valid", "container/valid")
            case.mutate(runtime, guild)
            local detector, epoch = ready_epoch(runtime)
            expect_problem("CGCE-GUILD-PROJECTION", case.field, function()
                list(runtime, epoch)
            end)
            a.equal(true, world_ready.close(detector))
            assert_zero_forbidden(runtime)
        end
    end)

    it("fails closed when the guild list or a projected field changes between fresh collections", function()
        local armed = false
        local changing_guild
        local field_runtime = runtime_binding_fixture.new({
            on_get_property = function(runtime, property)
                if armed and rawequal(property, runtime.raw.descriptors.guild_id_property) then
                    armed = false
                    runtime:set_guild_id(changing_guild, "guild/changed")
                end
            end,
        })
        changing_guild = field_runtime:add_guild("guild/original", "Original", "container/original")
        local field_detector, field_epoch = ready_epoch(field_runtime)
        armed = true
        expect_problem("CGCE-GUILD-DRIFT", "guilds[1].guild_id", function()
            list(field_runtime, field_epoch)
        end)
        a.equal(true, world_ready.close(field_detector))
        assert_zero_forbidden(field_runtime)

        local list_armed = false
        local first_guild
        local second_guild
        local list_runtime = runtime_binding_fixture.new({
            on_get_property = function(runtime, property)
                if list_armed and rawequal(property, runtime.raw.descriptors.guild_list_property) then
                    list_armed = false
                    runtime:set_guild_list({ first_guild, second_guild })
                end
            end,
        })
        first_guild = list_runtime:add_guild("guild/a", "A", "container/a")
        second_guild = list_runtime:add_guild(
            "guild/b",
            "B",
            "container/b",
            { listed = false }
        )
        local list_detector, list_epoch = ready_epoch(list_runtime)
        list_armed = true
        expect_problem("CGCE-GUILD-DRIFT", "guild_list", function()
            list(list_runtime, list_epoch)
        end)
        a.equal(true, world_ready.close(list_detector))
        assert_zero_forbidden(list_runtime)
    end)

    it("freshly rejects selected-world and manager relation drift during traversal", function()
        local duplicate_armed = false
        local runtime = runtime_binding_fixture.new({
            on_get_property = function(value, property)
                if duplicate_armed
                    and rawequal(property, value.raw.descriptors.guild_list_property) then
                    duplicate_armed = false
                    value:duplicate_guild_manager_inventory()
                end
            end,
        })
        runtime:add_guild("guild/a", "A", "container/a")
        local detector, epoch = ready_epoch(runtime)
        duplicate_armed = true

        expect_problem("CGCE-GUILD-MANAGER-RELATION", "guild_manager", function()
            list(runtime, epoch)
        end)

        a.equal(true, world_ready.close(detector))
        assert_zero_forbidden(runtime)

        local selected_armed = false
        local selected_runtime = runtime_binding_fixture.new({
            on_get_property = function(value, property)
                if selected_armed
                    and rawequal(property, value.raw.descriptors.guild_list_property) then
                    selected_armed = false
                    value:add_selected_world()
                end
            end,
        })
        selected_runtime:add_guild("guild/a", "A", "container/a")
        local selected_detector, selected_epoch = ready_epoch(selected_runtime)
        selected_armed = true

        expect_problem(
            "CGCE-GUILD-SELECTED-WORLD-RELATION",
            "selected_world",
            function()
                list(selected_runtime, selected_epoch)
            end
        )

        a.equal(true, world_ready.close(selected_detector))
        assert_zero_forbidden(selected_runtime)
    end)

    it("revalidates the paired world epoch after both stable collections", function()
        local armed = false
        local chest_reads = 0
        local runtime = runtime_binding_fixture.new({
            on_get_property = function(value, property)
                if armed
                    and rawequal(
                        property,
                        value.raw.descriptors.guild_chest_container_id_property
                    ) then
                    chest_reads = chest_reads + 1
                    if chest_reads == 2 then
                        armed = false
                        value:supersede_session()
                    end
                end
            end,
        })
        runtime:add_guild("guild/a", "A", "container/a")
        local detector, epoch = ready_epoch(runtime)
        armed = true

        expect_problem("CGCE-WORLD-EPOCH-STALE", "epoch", function()
            list(runtime, epoch)
        end)
        a.equal(2, chest_reads)

        a.equal(true, world_ready.close(detector))
        assert_zero_forbidden(runtime)
    end)

    it("binds the epoch to the exact adapter and binding session", function()
        local other = runtime_binding_fixture.new()
        local runtime = runtime_binding_fixture.new()
        runtime:add_guild("guild/a", "A", nil)
        local detector, epoch = ready_epoch(runtime)

        expect_problem("CGCE-WORLD-AUTHORITY", "adapter", function()
            guild_repository.list({
                adapter = other.adapter,
                binding_session = runtime.binding_session,
                world_epoch = epoch,
            })
        end)
        expect_problem("CGCE-WORLD-AUTHORITY", "binding_session", function()
            guild_repository.list({
                adapter = runtime.adapter,
                binding_session = other.binding_session,
                world_epoch = epoch,
            })
        end)

        a.equal(true, world_ready.close(detector))
        assert_zero_forbidden(runtime)
        assert_zero_forbidden(other)
    end)

    it("rejects unknown options and forged handles and exports only list", function()
        local runtime = runtime_binding_fixture.new()
        local detector, epoch = ready_epoch(runtime)

        expect_problem("CGCE-GUILD-OPTIONS", "unexpected", function()
            list(runtime, epoch, { unexpected = true })
        end)
        expect_problem("CGCE-WORLD-EPOCH", "epoch", function()
            list(runtime, function() end)
        end)
        expect_problem("CGCE-GUILD-OPTIONS", "options", function()
            guild_repository.list(setmetatable({}, {}))
        end)

        local exports = {}
        for name in pairs(guild_repository) do
            exports[#exports + 1] = name
        end
        table.sort(exports)
        a.deep_equal({ "list" }, exports)

        a.equal(true, world_ready.close(detector))
        assert_zero_forbidden(runtime)
    end)

    it("uses module-load captured world, binding, adapter, and JSON operations", function()
        local runtime = runtime_binding_fixture.new()
        runtime:add_guild("guild/a", "A", nil)
        local detector, epoch = ready_epoch(runtime)
        local replaced = {}
        local replacements = {
            { world_ready, "assert_current" },
            { world_ready, "world_id" },
            { revision_guard, "descriptor" },
            { ue4ss_adapter, "capabilities" },
            { ue4ss_adapter, "resolve_exact" },
            { ue4ss_adapter, "inventory_loaded" },
            { ue4ss_adapter, "read_property" },
            { ue4ss_adapter, "same_object" },
            { json, "array" },
            { json, "encode" },
        }
        for _, replacement in ipairs(replacements) do
            replaced[#replaced + 1] = { replacement[1], replacement[2], replacement[1][replacement[2]] }
            replacement[1][replacement[2]] = function()
                error("mutable public module slot must not be used")
            end
        end

        local ok, err = xpcall(function()
            a.deep_equal({ { guild_id = "guild/a", guild_name = "A" } }, list(runtime, epoch))
        end, debug.traceback)
        for _, replacement in ipairs(replaced) do
            replacement[1][replacement[2]] = replacement[3]
        end
        if not ok then
            error(err, 0)
        end

        a.equal(true, world_ready.close(detector))
        assert_zero_forbidden(runtime)
    end)
end)
