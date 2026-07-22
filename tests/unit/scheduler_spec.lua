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

        local status = controller:status()
        a.equal("READY", status.state)
        a.equal(1, status.attempts)
        a.equal(false, status.timer_pending)
        a.equal(true, status.result.world.ready)
        a.equal(true, probe_value.world.ready)
        a.equal(1, terminal_calls)
        a.equal("READY", terminal_result.state)

        status.result.world.ready = "caller change"
        a.equal(true, controller:status().result.world.ready)
        controller:cancel()
        a.equal(1, terminal_calls)
        a.equal("READY", controller:status().state)
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

        a.equal("READY", controller:status().state)
        a.equal(false, controller:status().result)
        a.equal(false, terminal_result.result)
    end)

    it("preserves empty JSON arrays and rejects the shared null sentinel", function()
        local array_controller = scheduler.retry(options(), function()
            return true, { findings = json.array({}) }
        end)
        a.equal("READY", array_controller:status().state)
        a.equal('{"findings":[]}', json.encode(array_controller:status().result))

        local null_controller = scheduler.retry(options(), function()
            return true, json.null
        end)
        a.equal("FAILED", null_controller:status().state)
        assert_scheduler_error("SCHEDULER_PROBE_FAILED", null_controller:status().error)
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

        a.equal("PENDING", controller:status().state)
        a.equal(1, controller:status().attempts)
        a.equal(true, controller:status().timer_pending)

        local first = queued[1]
        queued[1] = nil
        first.callback()
        a.equal(2, probes)
        a.equal("PENDING", controller:status().state)
        local second = queued[1]

        queued[1] = nil
        second.callback()
        local status = controller:status()
        a.equal("EXHAUSTED", status.state)
        a.equal(3, status.attempts)
        a.equal(false, status.timer_pending)
        a.equal(3, status.last_result.observed)
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

        a.equal("EXHAUSTED", controller:status().state)
        a.equal(1000, controller:status().attempts)
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

        local cancelled = controller:cancel()
        a.equal("CANCELLED", cancelled.state)
        a.equal(1, cancel_calls)
        a.equal(1, terminal_calls)
        controller:cancel()
        callback()
        a.equal(1, probes)
        a.equal(1, cancel_calls)
        a.equal(1, terminal_calls)
        a.equal("CANCELLED", controller:status().state)
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
                controller:cancel()
            end
            return false
        end)

        callback()
        local status = controller:status()
        a.equal("CANCELLED", status.state)
        a.equal(false, status.timer_pending)
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
                controller:cancel()
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
        local status = controller:status()
        a.equal("CANCELLED", status.state)
        a.equal(false, status.timer_pending)
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
                controller:cancel()
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
        local status = controller:status()
        a.equal("FAILED", status.state)
        assert_scheduler_error("SCHEDULER_CALLBACK_FAILED", status.error)
        a.equal(1, #terminal_results)
        a.equal("FAILED", terminal_results[1].state)
        assert_scheduler_error("SCHEDULER_CALLBACK_FAILED", terminal_results[1].error)
    end)

    it("fails closed on probe, scheduling, cancellation, and terminal callback errors", function()
        local probe_controller = scheduler.retry(options(), function()
            error("sensitive probe detail")
        end)
        local probe_status = probe_controller:status()
        a.equal("FAILED", probe_status.state)
        assert_scheduler_error("SCHEDULER_PROBE_FAILED", probe_status.error)
        a.equal(false, probe_status.error.detail:find("sensitive", 1, true) ~= nil)

        local schedule_controller = scheduler.retry(options({
            schedule = function() error("sensitive schedule detail") end,
        }), function() return false end)
        local schedule_status = schedule_controller:status()
        a.equal("FAILED", schedule_status.state)
        assert_scheduler_error("SCHEDULER_CALLBACK_FAILED", schedule_status.error)

        local cancel_controller = scheduler.retry(options({
            schedule = function(_, callback) return callback end,
            cancel = function() error("sensitive cancel detail") end,
        }), function() return false end)
        local cancel_status = cancel_controller:cancel()
        a.equal("FAILED", cancel_status.state)
        assert_scheduler_error("SCHEDULER_CALLBACK_FAILED", cancel_status.error)

        local returned_error_controller = scheduler.retry(options({
            schedule = function(_, callback) return callback end,
            cancel = function()
                return nil, { code = "SENSITIVE_CANCEL_FAILURE" }
            end,
        }), function() return false end)
        local returned_error_status = returned_error_controller:cancel()
        a.equal("FAILED", returned_error_status.state)
        assert_scheduler_error("SCHEDULER_CALLBACK_FAILED", returned_error_status.error)
        a.equal(false, returned_error_status.error.detail:find("SENSITIVE", 1, true) ~= nil)

        local terminal_calls = 0
        local terminal_controller = scheduler.retry(options({
            on_terminal = function()
                terminal_calls = terminal_calls + 1
                error("sensitive terminal detail")
            end,
        }), function() return true end)
        a.equal("FAILED", terminal_controller:status().state)
        assert_scheduler_error("SCHEDULER_CALLBACK_FAILED", terminal_controller:status().error)
        a.equal(1, terminal_calls)
        terminal_controller:cancel()
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
            assert_scheduler_error("INVALID_RESCAN_INTERVAL", err)
        end
    end)

    it("always inspects live state at startup even when a completed cache matches", function()
        local cache = {
            status = "completed",
            revision = 12345,
            target = 358,
            fingerprint = "sha256:fixture",
            owner = "guild/fixture",
        }
        local current = {
            revision = 12345,
            target = 358,
            fingerprint = "sha256:fixture",
            owner = "guild/fixture",
        }

        local decision = scheduler.cache_decision({
            phase = "startup",
            cache = cache,
            current = current,
        })
        a.equal("INSPECT", decision.action)
        a.deep_equal({ "STARTUP_LIVE_INSPECTION" }, decision.reasons)

        decision = scheduler.cache_decision({
            phase = "fallback",
            cache = cache,
            current = current,
        })
        a.equal("SKIP", decision.action)
        a.deep_equal({}, decision.reasons)
    end)

    it("invalidates fallback cache deterministically for every drift dimension", function()
        local decision = scheduler.cache_decision({
            phase = "fallback",
            cache = {
                status = "completed",
                revision = 100,
                target = 54,
                fingerprint = "old",
                owner = "old-owner",
            },
            current = {
                revision = 101,
                target = 358,
                fingerprint = "new",
                owner = "new-owner",
            },
        })

        a.equal("INSPECT", decision.action)
        a.deep_equal({
            "REVISION_DRIFT",
            "TARGET_DRIFT",
            "FINGERPRINT_DRIFT",
            "OWNER_DRIFT",
        }, decision.reasons)
    end)

    it("inspects conservatively for missing, malformed, or incomplete cache data", function()
        local current = {
            revision = 12345,
            target = 358,
            fingerprint = "sha256:fixture",
            owner = "guild/fixture",
        }
        local scenarios = {
            { cache = nil, reason = "CACHE_MISSING" },
            { cache = {}, reason = "CACHE_MALFORMED" },
            {
                cache = {
                    status = "pending",
                    revision = 12345,
                    target = 358,
                    fingerprint = "sha256:fixture",
                    owner = "guild/fixture",
                },
                reason = "CACHE_NOT_COMPLETED",
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
    end)
end)
