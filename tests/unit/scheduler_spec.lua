local a = require("tests.support.assertions")
local json = require("CrossplayGuildChestExpander.Scripts.json")
local scheduler = require("CrossplayGuildChestExpander.Scripts.scheduler")

local function options(overrides)
    local value = {
        max_attempts = 3,
        delay_seconds = 5,
        schedule = function()
            error("unexpected schedule")
        end,
        cancel = function()
            error("unexpected cancel")
        end,
    }
    for key, item in pairs(overrides or {}) do
        value[key] = item
    end
    return value
end

local function assert_scheduler_error(code, err)
    a.equal("table", type(err))
    a.equal(code, err.code)
    a.equal("string", type(err.detail))
end

local function status(controller)
    local value, err = scheduler.status(controller)
    a.equal(nil, err)
    return value
end

local function cancel(controller)
    local value, err = scheduler.cancel(controller)
    a.equal(nil, err)
    return value
end

local function wake(controller)
    local value, err = scheduler.wake(controller)
    a.equal(nil, err)
    return value
end

describe("scheduler.retry", function()
    it("probes immediately and delivers one detached READY result", function()
        local terminal_calls = 0
        local terminal_result
        local probe_value = { world = { ready = true } }
        local controller = scheduler.retry(options({
            on_terminal = function(result)
                terminal_calls = terminal_calls + 1
                terminal_result = result
                result.result.world.ready = "changed by callback"
            end,
        }), function(attempt)
            a.equal(1, attempt)
            return true, probe_value
        end)

        local current = status(controller)
        a.equal("READY", current.state)
        a.equal(1, current.attempts)
        a.equal(false, current.timer_pending)
        a.equal(true, current.result.world.ready)
        a.equal(true, probe_value.world.ready)
        a.equal(1, terminal_calls)
        a.equal("READY", terminal_result.state)

        current.result.world.ready = "caller change"
        a.equal(true, status(controller).result.world.ready)
        cancel(controller)
        a.equal(1, terminal_calls)
        a.equal("READY", status(controller).state)
    end)

    it("detaches JSON scalar probe results without treating false as failure", function()
        local terminal_result
        local controller = scheduler.retry(options({
            on_terminal = function(value)
                terminal_result = value
            end,
        }), function()
            return true, false
        end)

        a.equal("READY", status(controller).state)
        a.equal(false, status(controller).result)
        a.equal(false, terminal_result.result)
    end)

    it("preserves empty JSON arrays and rejects the shared null sentinel", function()
        local array_controller = scheduler.retry(options(), function()
            return true, { findings = json.array({}) }
        end)
        a.equal("READY", status(array_controller).state)
        a.equal('{"findings":[]}', json.encode(status(array_controller).result))

        local null_controller = scheduler.retry(options(), function()
            return true, json.null
        end)
        a.equal("FAILED", status(null_controller).state)
        assert_scheduler_error("CGCE-SCHED-PROBE-FAILED", status(null_controller).error)
    end)

    it("keeps at most one timer and exhausts at the explicit attempt bound", function()
        local queued = {}
        local cancelled = {}
        local terminal_calls = 0
        local probes = 0
        local controller = scheduler.retry(options({
            schedule = function(delay, callback)
                a.equal(5, delay)
                a.equal(0, #queued)
                local timer = { callback = callback }
                queued[1] = timer
                return timer
            end,
            cancel = function(timer)
                cancelled[#cancelled + 1] = timer
            end,
            on_terminal = function()
                terminal_calls = terminal_calls + 1
            end,
        }), function()
            probes = probes + 1
            return false, { observed = probes }
        end)

        a.equal("PENDING", status(controller).state)
        a.equal(1, status(controller).attempts)
        a.equal(true, status(controller).timer_pending)

        local first = queued[1]
        queued[1] = nil
        first.callback()
        a.equal(2, probes)
        a.equal("PENDING", status(controller).state)
        local second = queued[1]

        queued[1] = nil
        second.callback()
        local current = status(controller)
        a.equal("EXHAUSTED", current.state)
        a.equal(3, current.attempts)
        a.equal(false, current.timer_pending)
        a.equal(3, current.last_result.observed)
        a.equal(1, terminal_calls)
        a.equal(0, #cancelled)

        first.callback()
        second.callback()
        a.equal(3, probes)
        a.equal(1, terminal_calls)
    end)

    it("does not recurse past the bound with a synchronous scheduler", function()
        local schedules = 0
        local terminal_calls = 0
        local probes = 0
        local controller = scheduler.retry(options({
            max_attempts = 1000,
            delay_seconds = 0,
            schedule = function(_, callback)
                schedules = schedules + 1
                callback()
                callback()
                return { already_fired = true }
            end,
            cancel = function()
                error("a fired timer must not be cancelled")
            end,
            on_terminal = function()
                terminal_calls = terminal_calls + 1
            end,
        }), function()
            probes = probes + 1
            return false
        end)

        a.equal("EXHAUSTED", status(controller).state)
        a.equal(1000, status(controller).attempts)
        a.equal(1000, probes)
        a.equal(999, schedules)
        a.equal(1, terminal_calls)
    end)

    it("cancels once and ignores a callback that arrives after cancellation", function()
        local callback
        local timer = {}
        local cancel_calls = 0
        local terminal_calls = 0
        local probes = 0
        local controller = scheduler.retry(options({
            schedule = function(_, scheduled)
                callback = scheduled
                return timer
            end,
            cancel = function(actual)
                a.equal(timer, actual)
                cancel_calls = cancel_calls + 1
            end,
            on_terminal = function()
                terminal_calls = terminal_calls + 1
            end,
        }), function()
            probes = probes + 1
            return false
        end)

        local cancelled = cancel(controller)
        a.equal("CANCELLED", cancelled.state)
        a.equal(1, cancel_calls)
        a.equal(1, terminal_calls)
        cancel(controller)
        callback()
        a.equal(1, probes)
        a.equal(1, cancel_calls)
        a.equal(1, terminal_calls)
        a.equal("CANCELLED", status(controller).state)
    end)

    it("cancels one pending timer and probes immediately when woken", function()
        local callbacks = {}
        local timers = {}
        local cancelled = {}
        local probes = 0
        local terminal_calls = 0
        local controller = scheduler.retry(options({
            schedule = function(_, callback)
                callbacks[#callbacks + 1] = callback
                local token = { generation = #callbacks }
                timers[#timers + 1] = token
                return token
            end,
            cancel = function(token)
                cancelled[#cancelled + 1] = token
            end,
            on_terminal = function()
                terminal_calls = terminal_calls + 1
            end,
        }), function()
            probes = probes + 1
            return false, { observed = probes }
        end)

        a.equal(1, probes)
        a.equal(true, status(controller).timer_pending)
        local after_wake = wake(controller)
        a.equal("PENDING", after_wake.state)
        a.equal(2, after_wake.attempts)
        a.equal(true, after_wake.timer_pending)
        a.equal(1, #cancelled)
        a.equal(timers[1], cancelled[1])

        callbacks[1]()
        a.equal(2, probes)
        a.equal(1, #cancelled)

        callbacks[2]()
        a.equal(3, probes)
        a.equal("EXHAUSTED", status(controller).state)
        a.equal(1, terminal_calls)
    end)

    it("coalesces reentrant wakes during a probe without recursion or extra attempts", function()
        local callback
        local controller
        local probes = 0
        local probe_depth = 0
        local maximum_probe_depth = 0
        local schedule_calls = 0
        local terminal_calls = 0
        controller = scheduler.retry(options({
            max_attempts = 3,
            schedule = function(_, scheduled)
                schedule_calls = schedule_calls + 1
                callback = scheduled
                return { generation = schedule_calls }
            end,
            cancel = function()
                error("a fired timer must not be cancelled")
            end,
            on_terminal = function()
                terminal_calls = terminal_calls + 1
            end,
        }), function(attempt)
            probes = probes + 1
            probe_depth = probe_depth + 1
            maximum_probe_depth = math.max(maximum_probe_depth, probe_depth)
            if attempt >= 2 then
                a.equal("PENDING", wake(controller).state)
                a.equal("PENDING", wake(controller).state)
            end
            probe_depth = probe_depth - 1
            return false
        end)

        callback()
        a.equal("EXHAUSTED", status(controller).state)
        a.equal(3, status(controller).attempts)
        a.equal(3, probes)
        a.equal(1, maximum_probe_depth)
        a.equal(1, schedule_calls)
        a.equal(1, terminal_calls)
    end)

    it("invalidates a timer returned after schedule reentrantly wakes the controller", function()
        local callbacks = {}
        local timers = {}
        local cancelled = {}
        local controller
        local probes = 0
        local terminal_calls = 0
        controller = scheduler.retry(options({
            max_attempts = 3,
            schedule = function(_, callback)
                callbacks[#callbacks + 1] = callback
                local token = { generation = #callbacks }
                timers[#timers + 1] = token
                if #callbacks == 2 then
                    a.equal("PENDING", wake(controller).state)
                end
                return token
            end,
            cancel = function(token)
                cancelled[#cancelled + 1] = token
            end,
            on_terminal = function()
                terminal_calls = terminal_calls + 1
            end,
        }), function(attempt)
            probes = probes + 1
            return attempt == 3, { observed = attempt }
        end)

        callbacks[1]()
        local current = status(controller)
        a.equal("READY", current.state)
        a.equal(3, current.attempts)
        a.equal(3, probes)
        a.equal(1, #cancelled)
        a.equal(timers[2], cancelled[1])
        a.equal(1, terminal_calls)

        callbacks[2]()
        a.equal(3, probes)
        a.equal(1, #cancelled)
        a.equal(1, terminal_calls)
    end)

    it("treats wake as an idempotent no-op for every terminal state", function()
        local ready = scheduler.retry(options(), function()
            return true, { ready = true }
        end)
        local exhausted = scheduler.retry(options({ max_attempts = 1 }), function()
            return false, { exhausted = true }
        end)
        local failed = scheduler.retry(options(), function()
            error("sensitive probe detail")
        end)

        local cancelled_callback
        local cancel_calls = 0
        local cancelled = scheduler.retry(options({
            schedule = function(_, callback)
                cancelled_callback = callback
                return { pending = true }
            end,
            cancel = function()
                cancel_calls = cancel_calls + 1
            end,
        }), function()
            return false
        end)
        cancel(cancelled)

        for controller, expected in pairs({
            [ready] = "READY",
            [exhausted] = "EXHAUSTED",
            [failed] = "FAILED",
            [cancelled] = "CANCELLED",
        }) do
            local attempts = status(controller).attempts
            a.equal(expected, wake(controller).state)
            a.equal(expected, wake(controller).state)
            a.equal(attempts, status(controller).attempts)
            a.equal(false, status(controller).timer_pending)
        end
        a.equal(1, cancel_calls)
        cancelled_callback()
        a.equal("CANCELLED", status(cancelled).state)
    end)

    it("fails closed and fences the timer when wake cannot cancel it", function()
        local scenarios = {
            function()
                error("sensitive thrown cancellation detail")
            end,
            function()
                return nil, { code = "SENSITIVE_CANCEL_FAILURE" }
            end,
            function()
                return false
            end,
        }

        for _, cancel_callback in ipairs(scenarios) do
            local timer_callback
            local cancel_calls = 0
            local probes = 0
            local terminal_calls = 0
            local controller = scheduler.retry(options({
                schedule = function(_, callback)
                    timer_callback = callback
                    return { pending = true }
                end,
                cancel = function(...)
                    cancel_calls = cancel_calls + 1
                    return cancel_callback(...)
                end,
                on_terminal = function(value)
                    terminal_calls = terminal_calls + 1
                    a.equal("FAILED", value.state)
                end,
            }), function()
                probes = probes + 1
                return false
            end)

            local current = wake(controller)
            a.equal("FAILED", current.state)
            assert_scheduler_error("CGCE-SCHED-CALLBACK-FAILED", current.error)
            a.equal("timer cancellation callback failed", current.error.detail)
            a.equal(1, current.attempts)
            a.equal(false, current.timer_pending)
            a.equal(1, cancel_calls)
            a.equal(1, terminal_calls)

            timer_callback()
            wake(controller)
            a.equal(1, probes)
            a.equal(1, cancel_calls)
            a.equal(1, terminal_calls)
        end
    end)

    it("coalesces a wake reentered by cancellation before probing again", function()
        for _, cancel_succeeds in ipairs({ true, false }) do
            local callbacks = {}
            local tokens = {}
            local cancel_calls = 0
            local probes = 0
            local terminal_calls = 0
            local controller
            controller = scheduler.retry(options({
                schedule = function(_, callback)
                    callbacks[#callbacks + 1] = callback
                    local token = { generation = #callbacks }
                    tokens[#tokens + 1] = token
                    return token
                end,
                cancel = function(token)
                    cancel_calls = cancel_calls + 1
                    a.equal(tokens[1], token)
                    local nested = wake(controller)
                    a.equal("PENDING", nested.state)
                    a.equal(1, nested.attempts)
                    a.equal(1, #tokens)
                    if not cancel_succeeds then
                        return false
                    end
                end,
                on_terminal = function(value)
                    terminal_calls = terminal_calls + 1
                    if not cancel_succeeds then
                        a.equal("FAILED", value.state)
                    end
                end,
            }), function()
                probes = probes + 1
                return false
            end)

            local current = wake(controller)
            a.equal(1, cancel_calls)
            if cancel_succeeds then
                a.equal("PENDING", current.state)
                a.equal(2, current.attempts)
                a.equal(2, probes)
                a.equal(2, #tokens)
                a.equal(0, terminal_calls)
            else
                a.equal("FAILED", current.state)
                a.equal(1, current.attempts)
                a.equal(1, probes)
                a.equal(1, #tokens)
                a.equal(1, terminal_calls)
            end

            callbacks[1]()
            a.equal(cancel_succeeds and 2 or 1, probes)
        end
    end)

    it("honors a cancel reentered while wake is cancelling the pending timer", function()
        for _, cancel_succeeds in ipairs({ true, false }) do
            local callbacks = {}
            local tokens = {}
            local cancel_calls = 0
            local probes = 0
            local terminal_calls = 0
            local controller
            controller = scheduler.retry(options({
                schedule = function(_, callback)
                    callbacks[#callbacks + 1] = callback
                    local token = { generation = #callbacks }
                    tokens[#tokens + 1] = token
                    return token
                end,
                cancel = function(token)
                    cancel_calls = cancel_calls + 1
                    a.equal(tokens[1], token)
                    local nested = cancel(controller)
                    a.equal("PENDING", nested.state)
                    a.equal(1, nested.attempts)
                    a.equal(1, #tokens)
                    if not cancel_succeeds then
                        return false
                    end
                end,
                on_terminal = function(value)
                    terminal_calls = terminal_calls + 1
                    a.equal(cancel_succeeds and "CANCELLED" or "FAILED", value.state)
                end,
            }), function()
                probes = probes + 1
                return false
            end)

            local current = wake(controller)
            a.equal(cancel_succeeds and "CANCELLED" or "FAILED", current.state)
            a.equal(1, current.attempts)
            a.equal(1, probes)
            a.equal(1, #tokens)
            a.equal(1, cancel_calls)
            a.equal(1, terminal_calls)

            callbacks[1]()
            wake(controller)
            cancel(controller)
            a.equal(1, probes)
            a.equal(1, cancel_calls)
            a.equal(1, terminal_calls)
        end
    end)

    it("honors a cancel reentered while cleaning up a timer returned after wake", function()
        for _, cancel_succeeds in ipairs({ true, false }) do
            local callbacks = {}
            local tokens = {}
            local cancel_calls = 0
            local probes = 0
            local terminal_calls = 0
            local controller
            controller = scheduler.retry(options({
                max_attempts = 3,
                schedule = function(_, callback)
                    callbacks[#callbacks + 1] = callback
                    local token = { generation = #callbacks }
                    tokens[#tokens + 1] = token
                    if #callbacks == 2 then
                        a.equal("PENDING", wake(controller).state)
                    end
                    return token
                end,
                cancel = function(token)
                    cancel_calls = cancel_calls + 1
                    a.equal(tokens[2], token)
                    local nested = cancel(controller)
                    a.equal("PENDING", nested.state)
                    a.equal(2, nested.attempts)
                    if not cancel_succeeds then
                        return false
                    end
                end,
                on_terminal = function(value)
                    terminal_calls = terminal_calls + 1
                    a.equal(cancel_succeeds and "CANCELLED" or "FAILED", value.state)
                end,
            }), function()
                probes = probes + 1
                return false
            end)

            callbacks[1]()
            local current = status(controller)
            a.equal(cancel_succeeds and "CANCELLED" or "FAILED", current.state)
            a.equal(2, current.attempts)
            a.equal(2, probes)
            a.equal(2, #tokens)
            a.equal(1, cancel_calls)
            a.equal(1, terminal_calls)

            callbacks[2]()
            wake(controller)
            cancel(controller)
            a.equal(2, probes)
            a.equal(1, cancel_calls)
            a.equal(1, terminal_calls)
        end
    end)

    it("does not schedule after a probe reentrantly cancels the controller", function()
        local callback
        local schedule_calls = 0
        local terminal_calls = 0
        local controller
        controller = scheduler.retry(options({
            schedule = function(_, scheduled)
                schedule_calls = schedule_calls + 1
                callback = scheduled
                return { generation = schedule_calls }
            end,
            cancel = function()
                error("a fired timer must not be cancelled")
            end,
            on_terminal = function()
                terminal_calls = terminal_calls + 1
            end,
        }), function(attempt)
            if attempt == 2 then
                cancel(controller)
            end
            return false
        end)

        callback()
        local current = status(controller)
        a.equal("CANCELLED", current.state)
        a.equal(false, current.timer_pending)
        a.equal(1, schedule_calls)
        a.equal(1, terminal_calls)
    end)

    it("cancels a timer returned after schedule reentrantly reaches a terminal state", function()
        local first_callback
        local second_timer = { generation = 2 }
        local schedule_calls = 0
        local cancel_calls = 0
        local terminal_calls = 0
        local controller
        controller = scheduler.retry(options({
            schedule = function(_, callback)
                schedule_calls = schedule_calls + 1
                if schedule_calls == 1 then
                    first_callback = callback
                    return { generation = 1 }
                end
                cancel(controller)
                return second_timer
            end,
            cancel = function(timer)
                a.equal(second_timer, timer)
                cancel_calls = cancel_calls + 1
            end,
            on_terminal = function()
                terminal_calls = terminal_calls + 1
            end,
        }), function()
            return false
        end)

        first_callback()
        local current = status(controller)
        a.equal("CANCELLED", current.state)
        a.equal(false, current.timer_pending)
        a.equal(2, schedule_calls)
        a.equal(1, cancel_calls)
        a.equal(1, terminal_calls)
    end)

    it("delivers FAILED when a reentrantly returned timer cannot be cleaned up", function()
        local first_callback
        local schedule_calls = 0
        local terminal_results = {}
        local controller
        controller = scheduler.retry(options({
            schedule = function(_, callback)
                schedule_calls = schedule_calls + 1
                if schedule_calls == 1 then
                    first_callback = callback
                    return { generation = 1 }
                end
                cancel(controller)
                return { generation = 2 }
            end,
            cancel = function()
                return nil, { code = "SENSITIVE_CLEANUP_FAILURE" }
            end,
            on_terminal = function(result)
                terminal_results[#terminal_results + 1] = result
            end,
        }), function()
            return false
        end)

        first_callback()
        local current = status(controller)
        a.equal("FAILED", current.state)
        assert_scheduler_error("CGCE-SCHED-CALLBACK-FAILED", current.error)
        a.equal(1, #terminal_results)
        a.equal("FAILED", terminal_results[1].state)
        assert_scheduler_error("CGCE-SCHED-CALLBACK-FAILED", terminal_results[1].error)
    end)

    it("fails closed on probe, scheduling, cancellation, and terminal callback errors", function()
        local probe_controller = scheduler.retry(options(), function()
            error("sensitive probe detail")
        end)
        local probe_status = status(probe_controller)
        a.equal("FAILED", probe_status.state)
        assert_scheduler_error("CGCE-SCHED-PROBE-FAILED", probe_status.error)
        a.equal(false, probe_status.error.detail:find("sensitive", 1, true) ~= nil)

        local schedule_controller = scheduler.retry(options({
            schedule = function() error("sensitive schedule detail") end,
        }), function() return false end)
        local schedule_status = status(schedule_controller)
        a.equal("FAILED", schedule_status.state)
        assert_scheduler_error("CGCE-SCHED-CALLBACK-FAILED", schedule_status.error)

        local cancel_controller = scheduler.retry(options({
            schedule = function(_, callback) return callback end,
            cancel = function() error("sensitive cancel detail") end,
        }), function() return false end)
        local cancel_status = cancel(cancel_controller)
        a.equal("FAILED", cancel_status.state)
        assert_scheduler_error("CGCE-SCHED-CALLBACK-FAILED", cancel_status.error)

        local returned_error_controller = scheduler.retry(options({
            schedule = function(_, callback) return callback end,
            cancel = function()
                return nil, { code = "SENSITIVE_CANCEL_FAILURE" }
            end,
        }), function() return false end)
        local returned_error_status = cancel(returned_error_controller)
        a.equal("FAILED", returned_error_status.state)
        assert_scheduler_error("CGCE-SCHED-CALLBACK-FAILED", returned_error_status.error)
        a.equal(false, returned_error_status.error.detail:find("SENSITIVE", 1, true) ~= nil)

        local terminal_calls = 0
        local terminal_controller = scheduler.retry(options({
            on_terminal = function()
                terminal_calls = terminal_calls + 1
                error("sensitive terminal detail")
            end,
        }), function() return true end)
        a.equal("FAILED", status(terminal_controller).state)
        assert_scheduler_error("CGCE-SCHED-CALLBACK-FAILED", status(terminal_controller).error)
        a.equal(1, terminal_calls)
        cancel(terminal_controller)
        a.equal(1, terminal_calls)
    end)

    it("validates bounded retry options before invoking the probe", function()
        local probes = 0
        for _, invalid in ipairs({
            options({ max_attempts = 0 }),
            options({ max_attempts = 1.5 }),
            options({ delay_seconds = -1 }),
            options({ delay_seconds = math.huge }),
            options({ schedule = true }),
            options({ cancel = false }),
            options({ on_terminal = true }),
        }) do
            local ok = pcall(scheduler.retry, invalid, function()
                probes = probes + 1
                return true
            end)
            a.equal(false, ok)
        end
        a.equal(0, probes)

        local ok, err = pcall(scheduler.retry, options({ max_attempts = 0 }), function()
            return true
        end)
        a.equal(false, ok)
        assert_scheduler_error("CGCE-SCHED-INVALID-OPTIONS", err)
    end)

    it("uses an opaque handle and rejects forged handles without shadowable methods", function()
        local controller = scheduler.retry(options(), function()
            return true
        end)
        a.equal("function", type(controller))
        a.equal(false, pcall(function()
            rawset(controller, "status", function() return { state = "READY" } end)
        end))

        for _, forged in ipairs({ function() end, {}, "forged", false }) do
            local value, err = scheduler.status(forged)
            a.equal(nil, value)
            assert_scheduler_error("CGCE-SCHED-INVALID-HANDLE", err)

            value, err = scheduler.cancel(forged)
            a.equal(nil, value)
            assert_scheduler_error("CGCE-SCHED-INVALID-HANDLE", err)

            value, err = scheduler.wake(forged)
            a.equal(nil, value)
            assert_scheduler_error("CGCE-SCHED-INVALID-HANDLE", err)
        end
        local value, err = scheduler.status(nil)
        a.equal(nil, value)
        assert_scheduler_error("CGCE-SCHED-INVALID-HANDLE", err)

        value, err = scheduler.wake(nil)
        a.equal(nil, value)
        assert_scheduler_error("CGCE-SCHED-INVALID-HANDLE", err)

        local trusted_status = scheduler.status
        local trusted_cancel = scheduler.cancel
        rawset(scheduler, "status", function() return { state = "forged" } end)
        rawset(scheduler, "cancel", function() return { state = "forged" } end)
        local trusted_ok, trusted_value, trusted_error = pcall(trusted_status, controller)
        rawset(scheduler, "status", trusted_status)
        rawset(scheduler, "cancel", trusted_cancel)
        a.equal(true, trusted_ok)
        a.equal(nil, trusted_error)
        a.equal("READY", trusted_value.state)
    end)
end)

describe("scheduler rescan and cache policy", function()
    it("defaults to 60 seconds and rejects intervals below 30 or non-finite values", function()
        a.equal(60, scheduler.rescan_interval(nil))
        a.equal(30, scheduler.rescan_interval(30))
        a.equal(90, scheduler.rescan_interval(90))

        for _, value in ipairs({ 0, 29, 30.5, math.huge, "60" }) do
            local interval, err = scheduler.rescan_interval(value)
            a.equal(nil, interval)
            assert_scheduler_error("CGCE-SCHED-INVALID-RESCAN-INTERVAL", err)
        end
    end)

    it("always inspects live state at startup even when a completed cache matches", function()
        local cache = {
            status = "completed",
            game_revision = 12345,
            target_slots = 358,
            item_fingerprint = string.rep("a", 64),
            owner_guild_id = "guild/fixture",
        }
        local current = {
            game_revision = 12345,
            target_slots = 358,
            item_fingerprint = string.rep("a", 64),
            owner_guild_id = "guild/fixture",
        }

        local decision = scheduler.cache_decision({
            phase = "startup",
            cache = cache,
            current = current,
        })
        a.equal("INSPECT", decision.action)
        a.deep_equal({ "CGCE-SCHED-STARTUP-LIVE-INSPECTION" }, decision.reasons)

        decision = scheduler.cache_decision({
            phase = "fallback",
            cache = cache,
            current = current,
        })
        a.equal("SKIP", decision.action)
        a.deep_equal({}, decision.reasons)
        a.equal("[]", json.encode(decision.reasons))
    end)

    it("invalidates fallback cache deterministically for every drift dimension", function()
        local decision = scheduler.cache_decision({
            phase = "fallback",
            cache = {
                status = "completed",
                game_revision = 100,
                target_slots = 54,
                item_fingerprint = string.rep("a", 64),
                owner_guild_id = "old-owner",
            },
            current = {
                game_revision = 101,
                target_slots = 358,
                item_fingerprint = string.rep("b", 64),
                owner_guild_id = "new-owner",
            },
        })

        a.equal("INSPECT", decision.action)
        a.deep_equal({
            "CGCE-SCHED-REVISION-DRIFT",
            "CGCE-SCHED-TARGET-DRIFT",
            "CGCE-SCHED-FINGERPRINT-DRIFT",
            "CGCE-SCHED-OWNER-DRIFT",
        }, decision.reasons)
    end)

    it("inspects conservatively for missing, malformed, or incomplete cache data", function()
        local current = {
            game_revision = 12345,
            target_slots = 358,
            item_fingerprint = string.rep("a", 64),
            owner_guild_id = "guild/fixture",
        }
        local scenarios = {
            { cache = nil, reason = "CGCE-SCHED-CACHE-MISSING" },
            { cache = {}, reason = "CGCE-SCHED-CACHE-MALFORMED" },
            {
                cache = {
                    status = "pending",
                    game_revision = 12345,
                    target_slots = 358,
                    item_fingerprint = string.rep("a", 64),
                    owner_guild_id = "guild/fixture",
                },
                reason = "CGCE-SCHED-CACHE-NOT-COMPLETED",
            },
            {
                cache = {
                    status = "completed",
                    game_revision = 12345,
                    target_slots = 358,
                    item_fingerprint = string.rep("A", 64),
                    owner_guild_id = "guild/fixture",
                },
                reason = "CGCE-SCHED-CACHE-MALFORMED",
            },
            {
                cache = {
                    status = "completed",
                    game_revision = 12345,
                    target_slots = 358,
                    item_fingerprint = string.rep("a", 64),
                    owner_guild_id = "guild/fixture",
                    extra = true,
                },
                reason = "CGCE-SCHED-CACHE-MALFORMED",
            },
        }

        for _, scenario in ipairs(scenarios) do
            local decision = scheduler.cache_decision({
                phase = "fallback",
                cache = scenario.cache,
                current = current,
            })
            a.equal("INSPECT", decision.action)
            a.equal(scenario.reason, decision.reasons[1])
        end

        local decision = scheduler.cache_decision({
            phase = "fallback",
            cache = {
                status = "completed",
                game_revision = 12345,
                target_slots = 358,
                item_fingerprint = string.rep("a", 64),
                owner_guild_id = "guild/fixture",
            },
            current = {
                game_revision = 12345,
                target_slots = 358,
                item_fingerprint = string.rep("a", 64),
                owner_guild_id = "guild/fixture",
                extra = true,
            },
        })
        a.equal("INSPECT", decision.action)
        a.equal("CGCE-SCHED-CURRENT-MALFORMED", decision.reasons[1])

        decision = scheduler.cache_decision({
            phase = "fallback",
            cache = nil,
            current = current,
            unexpected = true,
        })
        a.deep_equal({ "CGCE-SCHED-DECISION-INPUT-MALFORMED" }, decision.reasons)
    end)
end)
