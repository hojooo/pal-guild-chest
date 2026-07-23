local a = require("tests.support.assertions")
local json = require("CrossplayGuildChestExpander.Scripts.json")
local revision_guard = require("CrossplayGuildChestExpander.Scripts.revision_guard")
local runtime_binding_fixture = require("tests.support.runtime_binding_fixture")
local scheduler = require("CrossplayGuildChestExpander.Scripts.scheduler")
local ue4ss_adapter = require("CrossplayGuildChestExpander.Scripts.ue4ss_adapter")
local world_ready = require("CrossplayGuildChestExpander.Scripts.world_ready")

local function timer_harness()
    local harness = {
        scheduled = 0,
        cancelled = 0,
        fail_cancel = false,
        records = {},
    }

    function harness.schedule(delay_seconds, callback)
        a.equal(1, delay_seconds)
        harness.scheduled = harness.scheduled + 1
        local token = function() end
        harness.records[#harness.records + 1] = {
            token = token,
            callback = callback,
            cancelled = false,
            fired = false,
        }
        return token
    end

    function harness.cancel(token)
        harness.cancelled = harness.cancelled + 1
        for _, record in ipairs(harness.records) do
            if record.token == token then
                if harness.fail_cancel then
                    return false
                end
                record.cancelled = true
                return true
            end
        end
        error("unknown timer token")
    end

    function harness:fire_next()
        for _, record in ipairs(self.records) do
            if not record.cancelled and not record.fired then
                record.fired = true
                record.callback()
                return true
            end
        end
        return false
    end

    function harness:fire_late(index)
        self.records[index].callback()
    end

    return harness
end

local function start(runtime, timers, extra)
    local options = {
        adapter = runtime.adapter,
        binding_session = runtime.binding_session,
        schedule = timers.schedule,
        cancel = timers.cancel,
    }
    for key, value in pairs(extra or {}) do
        options[key] = value
    end
    return world_ready.start(options)
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

describe("world_ready bounded selected-world authority", function()
    it("returns immediate READY with one epoch-invalidating hook and no timer", function()
        local runtime = runtime_binding_fixture.new()
        local timers = timer_harness()
        local detector = start(runtime, timers)
        local status = world_ready.status(detector)

        a.deep_equal({
            state = "READY",
            attempts = 1,
            max_attempts = 60,
            timer_pending = false,
            errors = json.array(),
        }, status)
        a.equal(0, timers.scheduled)
        a.equal(0, timers.cancelled)
        a.equal(1, runtime.fake.counters().register_hook)

        local epoch = world_ready.epoch(detector)
        a.equal("function", type(epoch))
        a.equal("test-world-alpha", world_ready.world_id(epoch))
        a.equal(true, world_ready.assert_current(
            epoch,
            runtime.adapter,
            runtime.binding_session
        ))

        local closed, errors = world_ready.close(detector)
        a.equal(true, closed)
        a.equal("[]", json.encode(errors))
        a.equal("CLOSED", world_ready.status(detector).state)
        a.equal(1, runtime.fake.counters().unregister_hook)
        assert_zero_forbidden(runtime)
    end)

    it("notifies exactly once after an asynchronous PENDING to READY transition", function()
        local runtime = runtime_binding_fixture.new({ ready = false })
        local timers = timer_harness()
        local notifications = 0
        local callback_state
        local callback_world_id
        local detector

        detector = start(runtime, timers, {
            on_terminal = function(callback_detector)
                notifications = notifications + 1
                a.equal(detector, callback_detector)
                callback_state = world_ready.status(callback_detector).state
                local epoch = world_ready.epoch(callback_detector)
                callback_world_id = world_ready.world_id(epoch)
            end,
        })

        a.equal("PENDING", world_ready.status(detector).state)
        a.equal(0, notifications)

        runtime:set_ready(true)
        runtime:fire_world_ready()

        a.equal("READY", callback_state)
        a.equal("test-world-alpha", callback_world_id)
        a.equal(1, notifications)

        runtime:fire_world_ready()
        timers:fire_late(2)
        a.equal("BLOCKED", world_ready.status(detector).state)
        a.equal(1, notifications)

        a.equal(true, world_ready.close(detector))
        runtime:fire_world_ready_late()
        a.equal(1, notifications)
        assert_zero_forbidden(runtime)
    end)

    it("notifies exactly once after an asynchronous PENDING to BLOCKED transition", function()
        local runtime = runtime_binding_fixture.new({ ready = false })
        local timers = timer_harness()
        local notifications = 0
        local callback_status
        local detector

        detector = start(runtime, timers, {
            on_terminal = function(callback_detector)
                notifications = notifications + 1
                a.equal(detector, callback_detector)
                callback_status = world_ready.status(callback_detector)
            end,
        })

        while timers:fire_next() do
        end

        a.equal(1, notifications)
        a.equal("BLOCKED", callback_status.state)
        a.equal("CGCE-WORLD-TIMEOUT", callback_status.errors[1].code)
        a.equal(nil, world_ready.epoch(detector))

        runtime:fire_world_ready_late()
        timers:fire_late(#timers.records)
        a.equal(1, notifications)
        a.equal(true, world_ready.close(detector))
        a.equal(1, notifications)
        assert_zero_forbidden(runtime)
    end)

    it("fails closed and sanitizes an asynchronous terminal callback failure", function()
        local runtime = runtime_binding_fixture.new({ ready = false })
        local timers = timer_harness()
        local notifications = 0
        local callback_state
        local callback_epoch
        local detector = start(runtime, timers, {
            on_terminal = function(callback_detector)
                notifications = notifications + 1
                callback_state = world_ready.status(callback_detector).state
                callback_epoch = world_ready.epoch(callback_detector)
                error("secret callback failure 0xDEADBEEF")
            end,
        })

        runtime:set_ready(true)
        runtime:fire_world_ready()

        local status = world_ready.status(detector)
        a.equal("BLOCKED", status.state)
        a.equal(1, notifications)
        a.equal("READY", callback_state)
        a.equal("function", type(callback_epoch))
        a.equal("CGCE-WORLD-TERMINAL-CALLBACK", status.errors[1].code)
        a.equal("on_terminal", status.errors[1].field)
        a.equal("world readiness terminal callback failed", status.errors[1].detail)
        a.equal(nil, status.errors[1].detail:find("secret", 1, true))
        a.equal(nil, status.errors[1].detail:find("0x", 1, true))
        a.equal(nil, world_ready.epoch(detector))
        expect_problem("CGCE-WORLD-EPOCH", "epoch", function()
            world_ready.world_id(callback_epoch)
        end)

        runtime:fire_world_ready_late()
        timers:fire_late(2)
        a.equal(1, notifications)
        a.equal(true, world_ready.close(detector))
        a.equal(1, notifications)
        assert_zero_forbidden(runtime)
    end)

    it("does not notify terminal callbacks for immediate startup outcomes", function()
        local notifications = 0
        local callback = function()
            notifications = notifications + 1
        end

        local ready_runtime = runtime_binding_fixture.new()
        local ready_detector = start(ready_runtime, timer_harness(), {
            on_terminal = callback,
        })
        a.equal("READY", world_ready.status(ready_detector).state)

        local registration_race_runtime = runtime_binding_fixture.new({
            ready = false,
            on_register = function(value)
                value:set_ready(true)
            end,
        })
        local registration_race_detector = start(
            registration_race_runtime,
            timer_harness(),
            { on_terminal = callback }
        )
        a.equal("READY", world_ready.status(registration_race_detector).state)

        local blocked_runtime = runtime_binding_fixture.new({ world_id = "" })
        local blocked_detector = start(blocked_runtime, timer_harness(), {
            on_terminal = callback,
        })
        a.equal("BLOCKED", world_ready.status(blocked_detector).state)
        a.equal(0, notifications)
        a.equal(true, world_ready.close(ready_detector))
        a.equal(true, world_ready.close(registration_race_detector))
        a.equal(true, world_ready.close(blocked_detector))
        a.equal(1, ready_runtime.fake.counters().unregister_hook)
        a.equal(1, registration_race_runtime.fake.counters().unregister_hook)
        assert_zero_forbidden(ready_runtime)
        assert_zero_forbidden(registration_race_runtime)
        assert_zero_forbidden(blocked_runtime)
    end)

    it("validates candidate manager relations without exporting epoch handles", function()
        local runtime = runtime_binding_fixture.new()
        local detector = start(runtime, timer_harness())
        local epoch = world_ready.epoch(detector)

        local selected_world_class = ue4ss_adapter.resolve_exact(
            runtime.adapter,
            runtime.descriptors.selected_world_class
        )
        local selected_worlds = ue4ss_adapter.inventory_loaded(
            runtime.adapter,
            selected_world_class
        )
        local guild_manager_class = ue4ss_adapter.resolve_exact(
            runtime.adapter,
            runtime.descriptors.guild_manager_class
        )
        local guild_managers = ue4ss_adapter.inventory_loaded(
            runtime.adapter,
            guild_manager_class
        )
        local container_manager_class = ue4ss_adapter.resolve_exact(
            runtime.adapter,
            runtime.descriptors.container_manager_class
        )
        local container_managers = ue4ss_adapter.inventory_loaded(
            runtime.adapter,
            container_manager_class
        )

        a.equal(true, world_ready.assert_relation(
            epoch,
            runtime.adapter,
            runtime.binding_session,
            "guild_manager",
            selected_worlds[1],
            guild_managers[1]
        ))
        a.equal(true, world_ready.assert_relation(
            epoch,
            runtime.adapter,
            runtime.binding_session,
            "container_manager",
            selected_worlds[1],
            container_managers[1]
        ))

        local foreign_raw = runtime:add_unlisted_guild_manager()
        runtime.fake.add_loaded(runtime.raw.descriptors.guild_manager_class, foreign_raw)
        local fresh_guild_managers = ue4ss_adapter.inventory_loaded(
            runtime.adapter,
            guild_manager_class
        )
        expect_problem("CGCE-WORLD-RELATION", "relation", function()
            world_ready.assert_relation(
                epoch,
                runtime.adapter,
                runtime.binding_session,
                "guild_manager",
                selected_worlds[1],
                fresh_guild_managers[2]
            )
        end)
        expect_problem("CGCE-WORLD-AUTHORITY", "relation_kind", function()
            world_ready.assert_relation(
                epoch,
                runtime.adapter,
                runtime.binding_session,
                "manager",
                selected_worlds[1],
                guild_managers[1]
            )
        end)

        a.equal(true, world_ready.close(detector))
        assert_zero_forbidden(runtime)
    end)

    it("closes the registration race with one post-hook wake", function()
        local runtime = runtime_binding_fixture.new({
            ready = false,
            on_register = function(value)
                value:set_ready(true)
            end,
        })
        local timers = timer_harness()
        local detector = start(runtime, timers)

        a.equal("READY", world_ready.status(detector).state)
        a.equal(2, world_ready.status(detector).attempts)
        a.equal(1, timers.scheduled)
        a.equal(1, timers.cancelled)
        a.equal(1, runtime.fake.counters().register_hook)
        a.equal(0, runtime.fake.counters().unregister_hook)

        a.equal(true, world_ready.close(detector))
        a.equal(1, runtime.fake.counters().unregister_hook)
        assert_zero_forbidden(runtime)
    end)

    it("blocks after exactly sixty total one-second attempts", function()
        local runtime = runtime_binding_fixture.new({ ready = false })
        local timers = timer_harness()
        local detector = start(runtime, timers)

        while timers:fire_next() do
        end

        local status = world_ready.status(detector)
        a.equal("BLOCKED", status.state)
        a.equal(60, status.attempts)
        a.equal(60, status.max_attempts)
        a.equal(false, status.timer_pending)
        a.equal("CGCE-WORLD-TIMEOUT", status.errors[1].code)
        a.equal(59, timers.scheduled)
        a.equal(1, timers.cancelled)
        a.equal(1, runtime.fake.counters().register_hook)
        a.equal(1, runtime.fake.counters().unregister_hook)
        a.equal(nil, world_ready.epoch(detector))
        assert_zero_forbidden(runtime)
    end)

    it("blocks multiple selected worlds and manager identity mismatch", function()
        local multi = runtime_binding_fixture.new()
        multi:add_selected_world()
        local multi_detector = start(multi, timer_harness())
        local multi_status = world_ready.status(multi_detector)
        a.equal("BLOCKED", multi_status.state)
        a.equal("CGCE-WORLD-SELECTED-CARDINALITY", multi_status.errors[1].code)
        a.equal(0, multi.fake.counters().register_hook)
        assert_zero_forbidden(multi)

        local mismatch = runtime_binding_fixture.new()
        mismatch:set_guild_manager(mismatch:add_unlisted_guild_manager())
        local mismatch_detector = start(mismatch, timer_harness())
        local mismatch_status = world_ready.status(mismatch_detector)
        a.equal("BLOCKED", mismatch_status.state)
        a.equal("CGCE-WORLD-GUILD-MANAGER-RELATION", mismatch_status.errors[1].code)
        a.equal(0, mismatch.fake.counters().register_hook)
        assert_zero_forbidden(mismatch)

        local duplicate = runtime_binding_fixture.new()
        duplicate:duplicate_guild_manager_inventory()
        local duplicate_detector = start(duplicate, timer_harness())
        a.equal("BLOCKED", world_ready.status(duplicate_detector).state)
        a.equal(
            "CGCE-WORLD-GUILD-MANAGER-RELATION",
            world_ready.status(duplicate_detector).errors[1].code
        )
        assert_zero_forbidden(duplicate)
    end)

    it("coalesces an event storm within the fixed product bound", function()
        local runtime = runtime_binding_fixture.new({ ready = false })
        local timers = timer_harness()
        local detector = start(runtime, timers)

        for _ = 1, 100 do
            runtime:fire_world_ready()
        end

        local status = world_ready.status(detector)
        a.equal("BLOCKED", status.state)
        a.equal(60, status.attempts)
        a.equal("CGCE-WORLD-TIMEOUT", status.errors[1].code)
        a.equal(59, timers.scheduled)
        a.equal(59, timers.cancelled)
        a.equal(1, runtime.fake.counters().unregister_hook)
        assert_zero_forbidden(runtime)
    end)

    it("makes a READY epoch stale when its observed readiness event fires again", function()
        local runtime = runtime_binding_fixture.new({
            ready = false,
            on_register = function(value)
                value:set_ready(true)
            end,
        })
        local timers = timer_harness()
        local detector = start(runtime, timers)
        local epoch = world_ready.epoch(detector)
        a.equal("READY", world_ready.status(detector).state)

        runtime:fire_world_ready()

        local status = world_ready.status(detector)
        a.equal("BLOCKED", status.state)
        a.equal("CGCE-WORLD-EPOCH-STALE", status.errors[1].code)
        a.equal(1, runtime.fake.counters().unregister_hook)
        expect_problem("CGCE-WORLD-EPOCH", "epoch", function()
            world_ready.assert_current(epoch, runtime.adapter, runtime.binding_session)
        end)
        assert_zero_forbidden(runtime)
    end)

    it("cannot return from an epoch accessor invalidated during fresh validation", function()
        local accessors = {
            function(detector)
                return world_ready.epoch(detector)
            end,
            function(_, epoch)
                return world_ready.world_id(epoch)
            end,
            function(_, epoch, runtime)
                return world_ready.assert_current(
                    epoch,
                    runtime.adapter,
                    runtime.binding_session
                )
            end,
        }

        for _, accessor in ipairs(accessors) do
            local armed = false
            local runtime = runtime_binding_fixture.new({
                ready = false,
                on_register = function(value)
                    value:set_ready(true)
                end,
                on_find_all = function(value, short_name)
                    if armed and short_name == "CGCETestSelectedWorld" then
                        armed = false
                        value:fire_world_ready()
                    end
                end,
            })
            local detector = start(runtime, timer_harness())
            local epoch = world_ready.epoch(detector)
            a.equal("READY", world_ready.status(detector).state)
            armed = true

            expect_problem("CGCE-WORLD-EPOCH", "epoch", function()
                accessor(detector, epoch, runtime)
            end)
            a.equal("BLOCKED", world_ready.status(detector).state)
            a.equal(1, runtime.fake.counters().unregister_hook)
            assert_zero_forbidden(runtime)
        end
    end)

    it("rejects superseded sessions and fresh relation drift", function()
        local superseded = runtime_binding_fixture.new()
        local first_detector = start(superseded, timer_harness())
        local first_epoch = world_ready.epoch(first_detector)
        superseded:supersede_session()

        expect_problem("CGCE-WORLD-EPOCH-STALE", "epoch", function()
            world_ready.assert_current(
                first_epoch,
                superseded.adapter,
                superseded.binding_session
            )
        end)
        a.equal("BLOCKED", world_ready.status(first_detector).state)

        local drifted = runtime_binding_fixture.new()
        local second_detector = start(drifted, timer_harness())
        local second_epoch = world_ready.epoch(second_detector)
        drifted:set_container_manager(drifted:add_unlisted_container_manager())

        expect_problem("CGCE-WORLD-EPOCH-STALE", "epoch", function()
            world_ready.assert_current(
                second_epoch,
                drifted.adapter,
                drifted.binding_session
            )
        end)
        a.equal("BLOCKED", world_ready.status(second_detector).state)
        a.equal(
            "CGCE-WORLD-EPOCH-STALE",
            world_ready.status(second_detector).errors[1].code
        )
        assert_zero_forbidden(superseded)
        assert_zero_forbidden(drifted)
    end)

    it("freshly rejects relation drift before returning an epoch handle", function()
        local runtime = runtime_binding_fixture.new()
        local detector = start(runtime, timer_harness())
        a.equal("READY", world_ready.status(detector).state)
        runtime:set_guild_manager(runtime:add_unlisted_guild_manager())

        expect_problem("CGCE-WORLD-EPOCH-STALE", "epoch", function()
            world_ready.epoch(detector)
        end)
        a.equal("BLOCKED", world_ready.status(detector).state)
        a.equal(nil, world_ready.epoch(detector))
        assert_zero_forbidden(runtime)
    end)

    it("invalidates before close and fences late hook and timer callbacks", function()
        local runtime = runtime_binding_fixture.new({ ready = false })
        local timers = timer_harness()
        local detector = start(runtime, timers)
        a.equal(2, world_ready.status(detector).attempts)

        local closed, errors = world_ready.close(detector)
        a.equal(true, closed)
        a.equal("[]", json.encode(errors))
        a.equal(true, world_ready.close(detector))
        a.equal(2, timers.cancelled)
        a.equal(1, runtime.fake.counters().unregister_hook)

        runtime:fire_world_ready_late()
        timers:fire_late(2)
        a.equal("CLOSED", world_ready.status(detector).state)
        a.equal(2, world_ready.status(detector).attempts)
        a.equal(2, timers.cancelled)
        a.equal(1, runtime.fake.counters().unregister_hook)
        assert_zero_forbidden(runtime)
    end)

    it("fails closed without repeating timer or hook cleanup failures", function()
        local cancel_runtime = runtime_binding_fixture.new({ ready = false })
        local cancel_timers = timer_harness()
        local cancel_detector = start(cancel_runtime, cancel_timers)
        cancel_timers.fail_cancel = true

        local cancel_ok, cancel_errors = world_ready.close(cancel_detector)
        a.equal(false, cancel_ok)
        a.equal("CGCE-WORLD-TIMER-CLEANUP", cancel_errors[1].code)
        a.equal("BLOCKED", world_ready.status(cancel_detector).state)
        a.equal(2, cancel_timers.cancelled)
        a.equal(1, cancel_runtime.fake.counters().unregister_hook)
        a.equal(false, world_ready.close(cancel_detector))
        a.equal(2, cancel_timers.cancelled)
        a.equal(1, cancel_runtime.fake.counters().unregister_hook)

        local unregister_runtime = runtime_binding_fixture.new({ ready = false })
        local unregister_timers = timer_harness()
        local unregister_detector = start(unregister_runtime, unregister_timers)
        unregister_runtime:fail_world_ready_unregister()

        local unregister_ok, unregister_errors = world_ready.close(unregister_detector)
        a.equal(false, unregister_ok)
        a.equal("CGCE-WORLD-HOOK-CLEANUP", unregister_errors[1].code)
        a.equal("BLOCKED", world_ready.status(unregister_detector).state)
        a.equal(1, unregister_runtime.fake.counters().unregister_hook)
        a.equal(false, world_ready.close(unregister_detector))
        a.equal(1, unregister_runtime.fake.counters().unregister_hook)
        assert_zero_forbidden(cancel_runtime)
        assert_zero_forbidden(unregister_runtime)
    end)

    it("cancels the pending timer when its binding session expires before hook setup", function()
        local runtime = runtime_binding_fixture.new({ ready = false })
        local timers = timer_harness()
        local original_schedule = timers.schedule
        local superseded = false
        timers.schedule = function(delay_seconds, callback)
            local token = original_schedule(delay_seconds, callback)
            if not superseded then
                superseded = true
                runtime:supersede_session()
            end
            return token
        end

        local detector = start(runtime, timers)

        local status = world_ready.status(detector)
        a.equal("BLOCKED", status.state)
        a.equal("CGCE-WORLD-HOOK-REGISTER", status.errors[1].code)
        a.equal(1, timers.scheduled)
        a.equal(1, timers.cancelled)
        a.equal(0, runtime.fake.counters().register_hook)
        assert_zero_forbidden(runtime)
    end)

    it("cannot become READY when relation inspection supersedes its binding session", function()
        local trigger = false
        local runtime = runtime_binding_fixture.new({
            on_find_all = function(value, short_name)
                if trigger and short_name == "CGCETestContainerManager" then
                    trigger = false
                    value:supersede_session()
                end
            end,
        })
        trigger = true

        local detector = start(runtime, timer_harness())

        local status = world_ready.status(detector)
        a.equal("BLOCKED", status.state)
        a.equal("CGCE-WORLD-AUTHORITY", status.errors[1].code)
        a.equal(0, runtime.fake.counters().register_hook)
        a.equal(nil, world_ready.epoch(detector))
        assert_zero_forbidden(runtime)
    end)

    it("cannot issue an epoch from a relation changed during the initial inspection", function()
        local trigger = false
        local runtime = runtime_binding_fixture.new({
            on_find_all = function(value, short_name)
                if trigger and short_name == "CGCETestContainerManager" then
                    trigger = false
                    value:set_container_manager(value:add_loaded_container_manager())
                end
            end,
        })
        trigger = true

        local detector = start(runtime, timer_harness())

        local status = world_ready.status(detector)
        a.equal("BLOCKED", status.state)
        a.equal("CGCE-WORLD-RELATION-CHANGED", status.errors[1].code)
        a.equal(nil, world_ready.epoch(detector))
        a.equal(0, runtime.fake.counters().register_hook)
        assert_zero_forbidden(runtime)
    end)

    it("reprobes instead of losing a world-ready event during final confirmation", function()
        local container_manager_inspections = 0
        local runtime = runtime_binding_fixture.new({
            ready = false,
            on_register = function(value)
                value:set_ready(true)
            end,
            on_find_all = function(value, short_name)
                if short_name == "CGCETestContainerManager" then
                    container_manager_inspections = container_manager_inspections + 1
                    if container_manager_inspections == 2 then
                        value:fire_world_ready()
                        value:set_container_manager(value:add_loaded_container_manager())
                    end
                end
            end,
        })

        local detector = start(runtime, timer_harness())

        local status = world_ready.status(detector)
        a.equal("READY", status.state)
        a.equal(3, status.attempts)
        a.deep_equal({}, status.errors)
        local epoch = world_ready.epoch(detector)
        a.equal("function", type(epoch))
        a.equal(true, world_ready.assert_current(
            epoch,
            runtime.adapter,
            runtime.binding_session
        ))
        a.equal(true, world_ready.close(detector))
        a.equal(1, runtime.fake.counters().unregister_hook)
        assert_zero_forbidden(runtime)
    end)

    it("does not expose READY after an unobserved final-confirmation drift", function()
        local container_manager_inspections = 0
        local runtime = runtime_binding_fixture.new({
            on_find_all = function(value, short_name)
                if short_name == "CGCETestContainerManager" then
                    container_manager_inspections = container_manager_inspections + 1
                    if container_manager_inspections == 2 then
                        value:set_container_manager(value:add_loaded_container_manager())
                    end
                end
            end,
        })

        local detector = start(runtime, timer_harness())

        local status = world_ready.status(detector)
        a.equal("BLOCKED", status.state)
        a.equal("CGCE-WORLD-RELATION-CHANGED", status.errors[1].code)
        a.equal(nil, world_ready.epoch(detector))
        assert_zero_forbidden(runtime)
    end)

    it("keeps null references and unloaded exact manager inventories pending until a wake", function()
        local cases = {
            {
                options = { guild_manager_reference = false },
                repair = function(runtime)
                    runtime:set_guild_manager(runtime.raw.guild_manager)
                end,
            },
            {
                options = { guild_manager_loaded = false },
                repair = function(runtime)
                    runtime:load_guild_manager()
                end,
            },
            {
                options = { container_manager_reference = false },
                repair = function(runtime)
                    runtime:set_container_manager(runtime.raw.container_manager)
                end,
            },
            {
                options = { container_manager_loaded = false },
                repair = function(runtime)
                    runtime:load_container_manager()
                end,
            },
        }

        for _, case in ipairs(cases) do
            local runtime = runtime_binding_fixture.new(case.options)
            local timers = timer_harness()
            local detector = start(runtime, timers)
            local pending = world_ready.status(detector)
            a.equal("PENDING", pending.state)
            a.equal(2, pending.attempts)
            a.equal(true, pending.timer_pending)
            a.equal(1, runtime.fake.counters().register_hook)

            case.repair(runtime)
            runtime:fire_world_ready()

            a.equal("READY", world_ready.status(detector).state)
            a.equal(3, world_ready.status(detector).attempts)
            a.equal(2, timers.scheduled)
            a.equal(2, timers.cancelled)
            a.equal("function", type(world_ready.epoch(detector)))
            a.equal(true, world_ready.close(detector))
            a.equal(1, runtime.fake.counters().unregister_hook)
            assert_zero_forbidden(runtime)
        end
    end)

    it("blocks epoch use after its adapter is closed or poisoned", function()
        local closed_runtime = runtime_binding_fixture.new()
        local closed_detector = start(closed_runtime, timer_harness())
        local closed_epoch = world_ready.epoch(closed_detector)
        a.equal(true, ue4ss_adapter.close(closed_runtime.adapter))
        expect_problem("CGCE-WORLD-EPOCH-STALE", "epoch", function()
            world_ready.world_id(closed_epoch)
        end)
        a.equal("BLOCKED", world_ready.status(closed_detector).state)

        local poisoned_runtime = runtime_binding_fixture.new()
        local poisoned_detector = start(poisoned_runtime, timer_harness())
        local poisoned_epoch = world_ready.epoch(poisoned_detector)
        local observation = ue4ss_adapter.observe_function(
            poisoned_runtime.adapter,
            poisoned_runtime.descriptors.world_ready_function,
            function() end
        )
        poisoned_runtime:fail_world_ready_unregister()
        a.equal(false, ue4ss_adapter.close_observation(poisoned_runtime.adapter, observation))
        expect_problem("CGCE-WORLD-EPOCH-STALE", "epoch", function()
            world_ready.assert_current(
                poisoned_epoch,
                poisoned_runtime.adapter,
                poisoned_runtime.binding_session
            )
        end)
        a.equal("BLOCKED", world_ready.status(poisoned_detector).state)
        assert_zero_forbidden(closed_runtime)
        assert_zero_forbidden(poisoned_runtime)
    end)

    it("rejects invalid identifiers, forged handles, unknown options, and extra exports", function()
        local runtime = runtime_binding_fixture.new({ world_id = "" })
        local timers = timer_harness()
        local detector = start(runtime, timers)
        a.equal("BLOCKED", world_ready.status(detector).state)
        a.equal("CGCE-WORLD-ID", world_ready.status(detector).errors[1].code)

        expect_problem("CGCE-WORLD-OPTIONS", "unexpected", function()
            start(runtime, timers, { unexpected = true })
        end)
        expect_problem("CGCE-WORLD-OPTIONS", "on_terminal", function()
            start(runtime, timers, { on_terminal = true })
        end)
        expect_problem("CGCE-WORLD-DETECTOR", "detector", function()
            world_ready.status(function() end)
        end)
        expect_problem("CGCE-WORLD-EPOCH", "epoch", function()
            world_ready.world_id(function() end)
        end)
        a.equal(nil, world_ready.scope)

        local authority_runtime = runtime_binding_fixture.new()
        local authority_detector = start(authority_runtime, timer_harness())
        local authority_epoch = world_ready.epoch(authority_detector)
        expect_problem("CGCE-WORLD-AUTHORITY", "adapter", function()
            world_ready.assert_current(
                authority_epoch,
                function() end,
                authority_runtime.binding_session
            )
        end)
        expect_problem("CGCE-WORLD-AUTHORITY", "binding_session", function()
            world_ready.assert_current(
                authority_epoch,
                authority_runtime.adapter,
                function() end
            )
        end)
        expect_problem("CGCE-WORLD-AUTHORITY", "adapter", function()
            world_ready.assert_current(authority_epoch)
        end)
        a.equal(true, world_ready.close(authority_detector))
        assert_zero_forbidden(authority_runtime)

        local exports = {}
        for name in pairs(world_ready) do
            exports[#exports + 1] = name
        end
        table.sort(exports)
        a.deep_equal({
            "assert_current",
            "assert_relation",
            "close",
            "epoch",
            "start",
            "status",
            "world_id",
        }, exports)
        assert_zero_forbidden(runtime)
    end)

    it("uses module-initial captured scheduler, adapter, and revision operations", function()
        local runtime = runtime_binding_fixture.new({
            ready = false,
            on_register = function(value)
                value:set_ready(true)
            end,
        })
        local timers = timer_harness()
        local replaced = {}
        local replacements = {
            { scheduler, "retry" },
            { scheduler, "status" },
            { scheduler, "wake" },
            { scheduler, "cancel" },
            { ue4ss_adapter, "capabilities" },
            { ue4ss_adapter, "resolve_exact" },
            { ue4ss_adapter, "inventory_loaded" },
            { ue4ss_adapter, "read_property" },
            { ue4ss_adapter, "same_object" },
            { ue4ss_adapter, "observe_function" },
            { ue4ss_adapter, "close_observation" },
            { revision_guard, "binding_metadata" },
            { revision_guard, "descriptor" },
        }
        for _, replacement in ipairs(replacements) do
            replaced[#replaced + 1] = { replacement[1], replacement[2], replacement[1][replacement[2]] }
            replacement[1][replacement[2]] = function()
                error("mutable public module slot must not be used")
            end
        end

        local ok, err = pcall(function()
            local detector = start(runtime, timers)
            local epoch = world_ready.epoch(detector)
            a.equal("READY", world_ready.status(detector).state)
            a.equal("test-world-alpha", world_ready.world_id(epoch))
            a.equal(true, world_ready.assert_current(
                epoch,
                runtime.adapter,
                runtime.binding_session
            ))
            a.equal(true, world_ready.close(detector))
        end)
        for _, replacement in ipairs(replaced) do
            replacement[1][replacement[2]] = replacement[3]
        end
        if not ok then
            error(err, 0)
        end
        assert_zero_forbidden(runtime)
    end)
end)
