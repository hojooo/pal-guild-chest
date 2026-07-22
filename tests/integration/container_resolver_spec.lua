local a = require("tests.support.assertions")
local audit = require("CrossplayGuildChestExpander.Scripts.audit")
local container_resolver = require("CrossplayGuildChestExpander.Scripts.container_resolver")
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

local function resolve(runtime, epoch, guild_id, container_id)
    return container_resolver.resolve(
        runtime.adapter,
        runtime.binding_session,
        epoch,
        guild_id,
        container_id
    )
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

local function sorted_keys(value)
    local result = {}
    for key in pairs(value) do
        result[#result + 1] = key
    end
    table.sort(result)
    return result
end

local function has_error(errors, code, field)
    for _, value in ipairs(errors) do
        if value.code == code and (field == nil or value.field == field) then
            return true
        end
    end
    return false
end

describe("container_resolver exact epoch-bound guild chest resolution", function()
    it("returns nil for nil and JSON-null IDs before reading any authority", function()
        local runtime = runtime_binding_fixture.new()
        local detector, epoch = ready_epoch(runtime)
        local before = runtime.fake.counters()

        a.equal(nil, resolve(runtime, epoch, "guild/a", nil))
        a.equal(nil, resolve(runtime, epoch, "guild/a", json.null))
        a.deep_equal(before, runtime.fake.counters())

        a.equal(true, world_ready.close(detector))
        assert_zero_forbidden(runtime)
    end)

    it("returns only the exact guild chest envelope and a current opaque token", function()
        local chest_scans = 0
        local armed = false
        local runtime = runtime_binding_fixture.new({
            on_find_all = function(_, short_name)
                if armed and short_name == "CGCETestGuildChest" then
                    chest_scans = chest_scans + 1
                end
            end,
        })
        runtime:add_guild_chest("container/a", "guild/a")
        local detector, epoch = ready_epoch(runtime)
        armed = true

        local result = resolve(runtime, epoch, "guild/a", "container/a")

        a.deep_equal({ "container", "container_id", "is_guild_chest", "owner_guild_id" },
            sorted_keys(result))
        a.equal("container/a", result.container_id)
        a.equal("guild/a", result.owner_guild_id)
        a.equal(true, result.is_guild_chest)
        a.equal("function", type(result.container))
        a.equal(false, runtime.fake.is_raw(result.container))
        a.equal(nil, debug.getupvalue(result.container, 1))
        a.equal(3, chest_scans)

        a.equal(true, container_resolver.assert_current(
            result.container,
            runtime.adapter,
            runtime.binding_session,
            epoch
        ))
        a.equal(6, chest_scans)

        a.equal(true, world_ready.close(detector))
        assert_zero_forbidden(runtime)
    end)

    it("ignores same-ID general containers outside the exact guild-chest class", function()
        local general
        local general_reads = 0
        local runtime = runtime_binding_fixture.new({
            on_get_property = function(_, _, object)
                if general ~= nil and rawequal(object, general) then
                    general_reads = general_reads + 1
                end
            end,
        })
        general = runtime:add_general_container("container/shared", "guild/a")
        local detector, epoch = ready_epoch(runtime)

        a.equal(nil, resolve(runtime, epoch, "guild/a", "container/shared"))
        a.equal(0, general_reads)

        a.equal(true, world_ready.close(detector))
        assert_zero_forbidden(runtime)
    end)

    it("detects a global exact-class duplicate before filtering by manager", function()
        local runtime = runtime_binding_fixture.new()
        local foreign_manager = runtime:add_loaded_container_manager()
        runtime:add_guild_chest("container/shared", "guild/a")
        runtime:add_guild_chest("container/shared", "guild/foreign", {
            manager = foreign_manager,
        })
        local detector, epoch = ready_epoch(runtime)

        expect_problem("CGCE-CRES-ID-AMBIGUOUS", "container_id", function()
            resolve(runtime, epoch, "guild/a", "container/shared")
        end)

        a.equal(true, world_ready.close(detector))
        assert_zero_forbidden(runtime)
    end)

    it("scans the full exact inventory and rejects malformed IDs", function()
        local runtime = runtime_binding_fixture.new()
        runtime:add_guild_chest("container/a", "guild/a")
        runtime:add_guild_chest(false, "guild/other")
        local detector, epoch = ready_epoch(runtime)

        expect_problem("CGCE-CRES-ID-PROJECTION", "container_id", function()
            resolve(runtime, epoch, "guild/a", "container/a")
        end)

        a.equal(true, world_ready.close(detector))
        assert_zero_forbidden(runtime)
    end)

    it("rejects a unique guild chest attached to a foreign manager", function()
        local runtime = runtime_binding_fixture.new()
        local foreign_manager = runtime:add_loaded_container_manager()
        runtime:add_guild_chest("container/foreign", "guild/a", {
            manager = foreign_manager,
        })
        local detector, epoch = ready_epoch(runtime)

        expect_problem("CGCE-CRES-WORLD-MISMATCH", "container_manager", function()
            resolve(runtime, epoch, "guild/a", "container/foreign")
        end)

        a.equal(true, world_ready.close(detector))
        assert_zero_forbidden(runtime)
    end)

    it("returns an owner-mismatch envelope for audit but permanently rejects its token", function()
        local runtime = runtime_binding_fixture.new()
        local chest = runtime:add_guild_chest("container/bad", "guild/other")
        local detector, epoch = ready_epoch(runtime)
        local resolved = resolve(runtime, epoch, "guild/bad", "container/bad")
        local snapshot_calls = 0

        a.equal("guild/other", resolved.owner_guild_id)
        expect_problem("CGCE-CRES-OWNER-MISMATCH", "owner_guild_id", function()
            container_resolver.assert_current(
                resolved.container,
                runtime.adapter,
                runtime.binding_session,
                epoch
            )
        end)

        runtime:set_container_owner_guild_id(chest, "guild/bad")
        expect_problem("CGCE-CRES-TOKEN", "container", function()
            container_resolver.assert_current(
                resolved.container,
                runtime.adapter,
                runtime.binding_session,
                epoch
            )
        end)

        local captured = audit.to_table(audit.capture({
            world_id = "test-world-alpha",
            game_revision = runtime.manifest.game_revision,
            deployment_profile = "windows-dedicated-ps5-macos-required",
            target_slots = 358,
            include_guild_ids = {},
            exclude_guild_ids = {},
            list_guilds = function()
                return {
                    {
                        guild_id = "guild/bad",
                        guild_name = "Bad",
                        chest_container_id = "container/bad",
                    },
                }
            end,
            resolve_guild_chest = function(guild_id, container_id)
                runtime:set_container_owner_guild_id(chest, "guild/other")
                return resolve(runtime, epoch, guild_id, container_id)
            end,
            snapshot_container = function()
                snapshot_calls = snapshot_calls + 1
                error("owner-mismatched tokens must not reach snapshot projection")
            end,
        }))

        a.equal("blocked", captured.guilds[1].status)
        a.equal(true, has_error(
            captured.guilds[1].errors,
            "CGCE-AUD-OWNER-MISMATCH",
            "owner_guild_id"
        ))
        a.equal(true, has_error(captured.blocking_errors, "CGCE-AUD-OWNER-MISMATCH"))
        a.equal(0, snapshot_calls)

        a.equal(true, world_ready.close(detector))
        assert_zero_forbidden(runtime)
    end)

    it("fails when the stable scans observe owner drift", function()
        local armed = false
        local chest_scans = 0
        local chest
        local runtime = runtime_binding_fixture.new({
            on_find_all = function(value, short_name)
                if armed and short_name == "CGCETestGuildChest" then
                    chest_scans = chest_scans + 1
                    if chest_scans == 2 then
                        value:set_container_owner_guild_id(chest, "guild/changed")
                    end
                end
            end,
        })
        chest = runtime:add_guild_chest("container/a", "guild/a")
        local detector, epoch = ready_epoch(runtime)
        armed = true

        expect_problem("CGCE-CRES-RELATION-CHANGED", "owner_guild_id", function()
            resolve(runtime, epoch, "guild/a", "container/a")
        end)
        a.equal(2, chest_scans)

        a.equal(true, world_ready.close(detector))
        assert_zero_forbidden(runtime)
    end)

    it("catches an owner mutation after the second scan captured its tail value", function()
        local armed = false
        local owner_reads = 0
        local chest
        local runtime = runtime_binding_fixture.new({
            on_get_property = function(value, property, object)
                if armed
                    and rawequal(object, chest)
                    and rawequal(
                        property,
                        value.raw.descriptors.container_owner_guild_id_property
                    ) then
                    owner_reads = owner_reads + 1
                    if owner_reads == 2 then
                        value:set_container_owner_guild_id(chest, "guild/changed")
                    end
                end
            end,
        })
        chest = runtime:add_guild_chest("container/a", "guild/a")
        local detector, epoch = ready_epoch(runtime)
        armed = true

        expect_problem("CGCE-CRES-RELATION-CHANGED", "owner_guild_id", function()
            resolve(runtime, epoch, "guild/a", "container/a")
        end)
        a.equal(3, owner_reads)

        a.equal(true, world_ready.close(detector))
        assert_zero_forbidden(runtime)
    end)

    it("catches an ID mutation after the second scan captured its tail value", function()
        local armed = false
        local id_reads = 0
        local chest
        local runtime = runtime_binding_fixture.new({
            on_get_property = function(value, property, object)
                if armed
                    and rawequal(object, chest)
                    and rawequal(property, value.raw.descriptors.container_id_property) then
                    id_reads = id_reads + 1
                    if id_reads == 2 then
                        value:set_container_id(chest, "container/changed")
                    end
                end
            end,
        })
        chest = runtime:add_guild_chest("container/a", "guild/a")
        local detector, epoch = ready_epoch(runtime)
        armed = true

        expect_problem("CGCE-CRES-RELATION-CHANGED", "container_id", function()
            resolve(runtime, epoch, "guild/a", "container/a")
        end)
        a.equal(3, id_reads)

        a.equal(true, world_ready.close(detector))
        assert_zero_forbidden(runtime)
    end)

    it("catches a foreign chest becoming a duplicate after the second scan", function()
        local armed = false
        local foreign_id_reads = 0
        local foreign
        local runtime = runtime_binding_fixture.new({
            on_get_property = function(value, property, object)
                if armed
                    and rawequal(object, foreign)
                    and rawequal(property, value.raw.descriptors.container_id_property) then
                    foreign_id_reads = foreign_id_reads + 1
                    if foreign_id_reads == 2 then
                        value:set_container_id(foreign, "container/target")
                    end
                end
            end,
        })
        runtime:add_guild_chest("container/target", "guild/a")
        foreign = runtime:add_guild_chest("container/foreign", "guild/other")
        local detector, epoch = ready_epoch(runtime)
        armed = true

        expect_problem("CGCE-CRES-ID-AMBIGUOUS", "container_id", function()
            resolve(runtime, epoch, "guild/a", "container/target")
        end)
        a.equal(3, foreign_id_reads)

        a.equal(true, world_ready.close(detector))
        assert_zero_forbidden(runtime)
    end)

    it("catches a manager mutation after the second scan captured its tail value", function()
        local armed = false
        local manager_reads = 0
        local chest
        local foreign_manager
        local runtime = runtime_binding_fixture.new({
            on_get_property = function(value, property, object)
                if armed
                    and rawequal(object, chest)
                    and rawequal(
                        property,
                        value.raw.descriptors.guild_chest_container_manager_property
                    ) then
                    manager_reads = manager_reads + 1
                    if manager_reads == 2 then
                        value:set_container_object_manager(chest, foreign_manager)
                    end
                end
            end,
        })
        foreign_manager = runtime:add_loaded_container_manager()
        chest = runtime:add_guild_chest("container/a", "guild/a")
        local detector, epoch = ready_epoch(runtime)
        armed = true

        expect_problem("CGCE-CRES-WORLD-MISMATCH", "container_manager", function()
            resolve(runtime, epoch, "guild/a", "container/a")
        end)
        a.equal(3, manager_reads)

        a.equal(true, world_ready.close(detector))
        assert_zero_forbidden(runtime)
    end)

    it("epoch-binds each scan against container-manager drift", function()
        local armed = false
        local drifted = false
        local runtime = runtime_binding_fixture.new({
            on_find_all = function(value, short_name)
                if armed and not drifted and short_name == "CGCETestGuildChest" then
                    drifted = true
                    value:set_container_manager(value:add_loaded_container_manager())
                end
            end,
        })
        runtime:add_guild_chest("container/a", "guild/a")
        local detector, epoch = ready_epoch(runtime)
        armed = true

        expect_problem("CGCE-CRES-AUTHORITY", "relation", function()
            resolve(runtime, epoch, "guild/a", "container/a")
        end)
        a.equal(true, drifted)

        a.equal(true, world_ready.close(detector))
        assert_zero_forbidden(runtime)
    end)

    it("re-scans current tokens and revokes them permanently on drift", function()
        local runtime = runtime_binding_fixture.new()
        local chest = runtime:add_guild_chest("container/a", "guild/a")
        local detector, epoch = ready_epoch(runtime)
        local token = resolve(runtime, epoch, "guild/a", "container/a").container

        runtime:set_container_owner_guild_id(chest, "guild/changed")
        expect_problem("CGCE-CRES-RELATION-CHANGED", "owner_guild_id", function()
            container_resolver.assert_current(
                token,
                runtime.adapter,
                runtime.binding_session,
                epoch
            )
        end)

        runtime:set_container_owner_guild_id(chest, "guild/a")
        expect_problem("CGCE-CRES-TOKEN", "container", function()
            container_resolver.assert_current(
                token,
                runtime.adapter,
                runtime.binding_session,
                epoch
            )
        end)

        a.equal(true, world_ready.close(detector))
        assert_zero_forbidden(runtime)
    end)

    it("revokes a token when the same token reenters validation", function()
        local armed = false
        local attempted = false
        local nested_ok
        local nested_error
        local token
        local epoch
        local runtime = runtime_binding_fixture.new({
            on_get_property = function(value, property)
                if armed
                    and not attempted
                    and rawequal(
                        property,
                        value.raw.descriptors.container_owner_guild_id_property
                    ) then
                    attempted = true
                    nested_ok, nested_error = pcall(
                        container_resolver.assert_current,
                        token,
                        value.adapter,
                        value.binding_session,
                        epoch
                    )
                end
            end,
        })
        runtime:add_guild_chest("container/a", "guild/a")
        local detector
        detector, epoch = ready_epoch(runtime)
        token = resolve(runtime, epoch, "guild/a", "container/a").container
        armed = true

        local outer_ok, outer_error = pcall(
            container_resolver.assert_current,
            token,
            runtime.adapter,
            runtime.binding_session,
            epoch
        )

        a.equal(true, attempted)
        a.equal(false, nested_ok)
        a.equal("table", type(nested_error))
        a.equal("CGCE-CRES-TOKEN", nested_error.code)
        a.equal("container", nested_error.field)
        a.equal(false, outer_ok)
        a.equal("table", type(outer_error))
        a.equal("CGCE-CRES-TOKEN", outer_error.code)
        a.equal("container", outer_error.field)
        expect_problem("CGCE-CRES-TOKEN", "container", function()
            container_resolver.assert_current(
                token,
                runtime.adapter,
                runtime.binding_session,
                epoch
            )
        end)

        a.equal(true, world_ready.close(detector))
        assert_zero_forbidden(runtime)
    end)

    it("revokes tokens on crosswired or stale authority", function()
        local runtime = runtime_binding_fixture.new()
        runtime:add_guild_chest("container/a", "guild/a")
        local detector, epoch = ready_epoch(runtime)
        local token = resolve(runtime, epoch, "guild/a", "container/a").container
        local other = runtime_binding_fixture.new()

        expect_problem("CGCE-CRES-TOKEN", "adapter", function()
            container_resolver.assert_current(
                token,
                other.adapter,
                runtime.binding_session,
                epoch
            )
        end)
        expect_problem("CGCE-CRES-TOKEN", "container", function()
            container_resolver.assert_current(
                token,
                runtime.adapter,
                runtime.binding_session,
                epoch
            )
        end)

        local stale_runtime = runtime_binding_fixture.new()
        stale_runtime:add_guild_chest("container/b", "guild/b")
        local stale_detector, stale_epoch = ready_epoch(stale_runtime)
        local stale_token = resolve(
            stale_runtime,
            stale_epoch,
            "guild/b",
            "container/b"
        ).container
        stale_runtime:supersede_session()
        expect_problem("CGCE-CRES-TOKEN", "world_epoch", function()
            container_resolver.assert_current(
                stale_token,
                stale_runtime.adapter,
                stale_runtime.binding_session,
                stale_epoch
            )
        end)
        expect_problem("CGCE-CRES-TOKEN", "container", function()
            container_resolver.assert_current(
                stale_token,
                stale_runtime.adapter,
                stale_runtime.binding_session,
                stale_epoch
            )
        end)

        a.equal(true, world_ready.close(detector))
        a.equal(true, world_ready.close(stale_detector))
        assert_zero_forbidden(runtime)
        assert_zero_forbidden(other)
        assert_zero_forbidden(stale_runtime)
    end)

    it("rejects malformed identifiers, forged tokens, and extra exports", function()
        local runtime = runtime_binding_fixture.new()
        local detector, epoch = ready_epoch(runtime)

        for _, case in ipairs({
            { field = "guild_id", guild_id = "", container_id = "container/a" },
            { field = "guild_id", guild_id = false, container_id = "container/a" },
            { field = "container_id", guild_id = "guild/a", container_id = "" },
            { field = "container_id", guild_id = "guild/a", container_id = string.char(255) },
        }) do
            expect_problem("CGCE-CRES-INPUT", case.field, function()
                resolve(runtime, epoch, case.guild_id, case.container_id)
            end)
        end
        expect_problem("CGCE-CRES-TOKEN", "container", function()
            container_resolver.assert_current(
                function() end,
                runtime.adapter,
                runtime.binding_session,
                epoch
            )
        end)

        local exports = {}
        for name in pairs(container_resolver) do
            exports[#exports + 1] = name
        end
        table.sort(exports)
        a.deep_equal({ "assert_current", "resolve" }, exports)
        a.equal(nil, container_resolver.unwrap)

        a.equal(true, world_ready.close(detector))
        assert_zero_forbidden(runtime)
    end)

    it("uses module-load captured world, binding, adapter, and JSON operations", function()
        local runtime = runtime_binding_fixture.new()
        runtime:add_guild_chest("container/a", "guild/a")
        local detector, epoch = ready_epoch(runtime)
        local replaced = {}
        local replacements = {
            { world_ready, "assert_current" },
            { world_ready, "assert_relation" },
            { revision_guard, "descriptor" },
            { ue4ss_adapter, "capabilities" },
            { ue4ss_adapter, "resolve_exact" },
            { ue4ss_adapter, "inventory_loaded" },
            { ue4ss_adapter, "read_property" },
            { ue4ss_adapter, "same_object" },
            { json, "encode" },
        }
        for _, replacement in ipairs(replacements) do
            replaced[#replaced + 1] = {
                replacement[1],
                replacement[2],
                replacement[1][replacement[2]],
            }
            replacement[1][replacement[2]] = function()
                error("mutable public module slot must not be used")
            end
        end

        local ok, err = xpcall(function()
            local token = resolve(runtime, epoch, "guild/a", "container/a").container
            a.equal(true, container_resolver.assert_current(
                token,
                runtime.adapter,
                runtime.binding_session,
                epoch
            ))
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
