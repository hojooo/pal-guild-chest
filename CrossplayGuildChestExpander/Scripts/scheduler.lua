local json = require("CrossplayGuildChestExpander.Scripts.json")

local scheduler = {}

local controller_operations = setmetatable({}, { __mode = "k" })

local function make_error(code, field, detail)
    return {
        code = code,
        field = field,
        detail = detail,
    }
end

local function finite_number(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

local function contains_json_null(value, visited)
    if value == json.null then
        return true
    end
    if type(value) ~= "table" or visited[value] then
        return false
    end
    visited[value] = true
    for _, item in next, value do
        if contains_json_null(item, visited) then
            return true
        end
    end
    return false
end

local function detach(value)
    if value == nil then
        return nil, true
    end
    if contains_json_null(value, {}) then
        return nil, false
    end
    local encoded_ok, encoded = pcall(json.encode, value)
    if not encoded_ok then
        return nil, false
    end
    local decoded_ok, copy = pcall(json.decode, encoded)
    if not decoded_ok then
        return nil, false
    end
    return copy, true
end

local retry_option_names = {
    max_attempts = true,
    delay_seconds = true,
    schedule = true,
    cancel = true,
    on_terminal = true,
}

local function invalid_options(field, detail)
    error(make_error("CGCE-SCHED-INVALID-OPTIONS", field, detail), 0)
end

local function validate_retry_options(options, probe)
    if type(options) ~= "table" then
        invalid_options("options", "retry options must be a table")
    end
    local unknown = {}
    local non_string = false
    for key in next, options do
        if type(key) ~= "string" then
            non_string = true
        elseif not retry_option_names[key] then
            unknown[#unknown + 1] = key
        end
    end
    if non_string then
        invalid_options("options", "retry options contain an invalid field")
    end
    table.sort(unknown)
    if unknown[1] then
        invalid_options(unknown[1], "unknown retry option")
    end

    local max_attempts = rawget(options, "max_attempts")
    if type(max_attempts) ~= "number" or math.type(max_attempts) ~= "integer" or max_attempts < 1 then
        invalid_options("max_attempts", "max_attempts must be a positive integer")
    end
    local delay_seconds = rawget(options, "delay_seconds")
    if not finite_number(delay_seconds) or delay_seconds < 0 then
        invalid_options("delay_seconds", "delay_seconds must be a nonnegative finite number")
    end
    if type(rawget(options, "schedule")) ~= "function" then
        invalid_options("schedule", "schedule must be a function")
    end
    if type(rawget(options, "cancel")) ~= "function" then
        invalid_options("cancel", "cancel must be a function")
    end
    local on_terminal = rawget(options, "on_terminal")
    if on_terminal ~= nil and type(on_terminal) ~= "function" then
        invalid_options("on_terminal", "on_terminal must be a function when provided")
    end
    if type(probe) ~= "function" then
        invalid_options("probe", "probe must be a function")
    end
end

function scheduler.retry(options, probe)
    validate_retry_options(options, probe)

    local max_attempts = rawget(options, "max_attempts")
    local delay_seconds = rawget(options, "delay_seconds")
    local schedule = rawget(options, "schedule")
    local cancel_timer = rawget(options, "cancel")
    local on_terminal = rawget(options, "on_terminal")
    local scheduling_sentinel = {}

    local state = "PENDING"
    local attempts = 0
    local timer = nil
    local generation = 0
    local pumping = false
    local pump_requested = false
    local cancelling_timer = false
    local cancel_requested = false
    local terminal_delivered = false
    local terminal_defer_depth = 0
    local result = nil
    local last_result = nil
    local terminal_error = nil

    local function snapshot()
        local value = {
            state = state,
            attempts = attempts,
            max_attempts = max_attempts,
            timer_pending = timer ~= nil,
        }
        if result ~= nil then
            local detached, ok = detach(result)
            if not ok then
                error("scheduler stored an invalid terminal result", 0)
            end
            value.result = detached
        end
        if last_result ~= nil then
            local detached, ok = detach(last_result)
            if not ok then
                error("scheduler stored an invalid probe result", 0)
            end
            value.last_result = detached
        end
        if terminal_error ~= nil then
            value.error = {
                code = terminal_error.code,
                field = terminal_error.field,
                detail = terminal_error.detail,
            }
        end
        return value
    end

    local function deliver_terminal()
        if terminal_delivered then
            return
        end
        terminal_delivered = true
        if on_terminal ~= nil then
            local ok = pcall(on_terminal, snapshot())
            if not ok then
                state = "FAILED"
                terminal_error = make_error(
                    "CGCE-SCHED-CALLBACK-FAILED",
                    "on_terminal",
                    "terminal callback failed"
                )
            end
        end
    end

    local function begin_terminal_scope()
        terminal_defer_depth = terminal_defer_depth + 1
    end

    local function end_terminal_scope()
        terminal_defer_depth = terminal_defer_depth - 1
        if terminal_defer_depth == 0 and state ~= "PENDING" then
            deliver_terminal()
        end
    end

    local function finish(terminal_state, err)
        if state ~= "PENDING" then
            return
        end
        generation = generation + 1
        timer = nil
        pump_requested = false
        cancel_requested = false
        state = terminal_state
        terminal_error = err
        if terminal_defer_depth == 0 then
            deliver_terminal()
        end
    end

    local function callback_failure(field, detail)
        local err = make_error("CGCE-SCHED-CALLBACK-FAILED", field, detail)
        if state == "PENDING" then
            finish("FAILED", err)
        else
            timer = nil
            pump_requested = false
            state = "FAILED"
            terminal_error = err
            if terminal_defer_depth == 0 then
                deliver_terminal()
            end
        end
    end

    local function cancel_handle(handle)
        cancelling_timer = true
        local ok, result_value, returned_error = pcall(cancel_timer, handle)
        cancelling_timer = false
        if not ok or returned_error ~= nil or result_value == false then
            callback_failure("cancel", "timer cancellation callback failed")
            return false
        end
        return true
    end

    local request_pump

    local function schedule_next()
        begin_terminal_scope()
        generation = generation + 1
        local callback_generation = generation
        local fired = false
        timer = scheduling_sentinel

        local ok, token, callback_error = pcall(schedule, delay_seconds, function()
            if fired or state ~= "PENDING" or generation ~= callback_generation then
                return
            end
            fired = true
            timer = nil
            request_pump()
        end)

        if state ~= "PENDING" or generation ~= callback_generation then
            timer = nil
            if not ok or callback_error ~= nil then
                callback_failure("schedule", "schedule callback failed")
            elseif not fired and token ~= nil then
                local cancelled = cancel_handle(token)
                if cancelled and cancel_requested and state == "PENDING" then
                    finish("CANCELLED", nil)
                end
            end
            end_terminal_scope()
            return
        end
        if not ok or callback_error ~= nil then
            timer = nil
            callback_failure("schedule", "schedule callback failed")
            end_terminal_scope()
            return
        end
        if fired then
            timer = nil
            end_terminal_scope()
            return
        end
        if token == nil then
            timer = nil
            callback_failure("schedule", "schedule callback did not return a timer handle")
            end_terminal_scope()
            return
        end
        timer = token
        end_terminal_scope()
    end

    local function run_probe()
        begin_terminal_scope()
        attempts = attempts + 1
        local probe_generation = generation
        local ok, ready, observed = pcall(probe, attempts)
        if state ~= "PENDING" or generation ~= probe_generation then
            if not ok then
                state = "FAILED"
                terminal_error = make_error(
                    "CGCE-SCHED-PROBE-FAILED",
                    "probe",
                    "world-ready probe failed"
                )
            end
            end_terminal_scope()
            return
        end
        if not ok then
            finish("FAILED", make_error(
                "CGCE-SCHED-PROBE-FAILED",
                "probe",
                "world-ready probe failed"
            ))
            end_terminal_scope()
            return
        end
        if type(ready) ~= "boolean" then
            finish("FAILED", make_error(
                "CGCE-SCHED-PROBE-FAILED",
                "probe",
                "world-ready probe must return a boolean"
            ))
            end_terminal_scope()
            return
        end

        local detached, detached_ok = detach(observed)
        if not detached_ok then
            finish("FAILED", make_error(
                "CGCE-SCHED-PROBE-FAILED",
                "probe",
                "world-ready probe returned a non-JSON-safe result"
            ))
            end_terminal_scope()
            return
        end
        last_result = detached

        if ready then
            result = detached
            finish("READY", nil)
        elseif attempts >= max_attempts then
            finish("EXHAUSTED", nil)
        elseif pump_requested then
            -- A wake observed while the probe was running is already queued by
            -- the non-recursive pump. Do not introduce a timer between the
            -- current observation and that coalesced re-probe.
        else
            schedule_next()
        end
        end_terminal_scope()
    end

    request_pump = function()
        if state ~= "PENDING" then
            return
        end
        if pumping then
            pump_requested = true
            return
        end

        pumping = true
        repeat
            pump_requested = false
            if state == "PENDING" and timer == nil then
                run_probe()
            end
        until not pump_requested or state ~= "PENDING"
        pumping = false
    end

    local function status_method()
        return snapshot()
    end

    local function cancel_method()
        if state ~= "PENDING" then
            return snapshot()
        end
        if cancelling_timer then
            cancel_requested = true
            return snapshot()
        end

        begin_terminal_scope()
        generation = generation + 1
        local pending_timer = timer
        timer = nil
        pump_requested = false
        if pending_timer ~= nil and pending_timer ~= scheduling_sentinel then
            if not cancel_handle(pending_timer) then
                end_terminal_scope()
                return snapshot()
            end
        end
        finish("CANCELLED", nil)
        end_terminal_scope()
        return snapshot()
    end

    local function wake_method()
        if state ~= "PENDING" then
            return snapshot()
        end
        if cancelling_timer then
            pump_requested = true
            return snapshot()
        end

        -- A wake raised from inside the active probe is only a freshness hint.
        -- The running observation is allowed to finish, and at most one more
        -- probe is queued by the pump. In particular, this cannot recurse or
        -- consume an attempt beyond max_attempts.
        if pumping and timer == nil then
            pump_requested = true
            return snapshot()
        end

        begin_terminal_scope()
        generation = generation + 1
        local pending_timer = timer
        timer = nil
        pump_requested = true
        if pending_timer ~= nil and pending_timer ~= scheduling_sentinel then
            if not cancel_handle(pending_timer) then
                end_terminal_scope()
                return snapshot()
            end
        end
        if cancel_requested then
            finish("CANCELLED", nil)
        elseif state == "PENDING" then
            request_pump()
        end
        end_terminal_scope()
        return snapshot()
    end

    local controller = function() end
    controller_operations[controller] = {
        status = status_method,
        cancel = cancel_method,
        wake = wake_method,
    }

    request_pump()
    return controller
end

local function controller_operation(handle, name)
    local operations = controller_operations[handle]
    if operations == nil then
        return nil, make_error(
            "CGCE-SCHED-INVALID-HANDLE",
            "handle",
            "scheduler controller handle is invalid"
        )
    end
    return operations[name](), nil
end

function scheduler.status(handle)
    return controller_operation(handle, "status")
end

function scheduler.cancel(handle)
    return controller_operation(handle, "cancel")
end

function scheduler.wake(handle)
    return controller_operation(handle, "wake")
end

function scheduler.rescan_interval(value)
    if value == nil then
        return 60, nil
    end
    if not finite_number(value) or math.type(value) ~= "integer" or value < 30 then
        return nil, make_error(
            "CGCE-SCHED-INVALID-RESCAN-INTERVAL",
            "interval",
            "fallback rescan interval must be an integer of at least 30 seconds"
        )
    end
    return value, nil
end

local cache_fields = {
    status = true,
    game_revision = true,
    target_slots = true,
    item_fingerprint = true,
    owner_guild_id = true,
}

local current_fields = {
    game_revision = true,
    target_slots = true,
    item_fingerprint = true,
    owner_guild_id = true,
}

local decision_fields = {
    phase = true,
    cache = true,
    current = true,
}

local function has_only_fields(value, allowed)
    if type(value) ~= "table" or getmetatable(value) ~= nil then
        return false
    end
    for key in next, value do
        if type(key) ~= "string" or not allowed[key] then
            return false
        end
    end
    return true
end

local function valid_identity(value, include_status)
    local allowed = include_status and cache_fields or current_fields
    if not has_only_fields(value, allowed) then
        return false
    end
    if include_status and type(rawget(value, "status")) ~= "string" then
        return false
    end
    local revision = rawget(value, "game_revision")
    local target = rawget(value, "target_slots")
    local fingerprint = rawget(value, "item_fingerprint")
    local owner = rawget(value, "owner_guild_id")
    return type(revision) == "number"
        and math.type(revision) == "integer"
        and revision > 0
        and type(target) == "number"
        and math.type(target) == "integer"
        and target > 0
        and type(fingerprint) == "string"
        and #fingerprint == 64
        and fingerprint:match("^[0-9a-f]+$") ~= nil
        and type(owner) == "string"
        and owner ~= ""
end

function scheduler.cache_decision(input)
    local reasons = json.array({})
    if not has_only_fields(input, decision_fields) then
        return {
            action = "INSPECT",
            reasons = json.array({ "CGCE-SCHED-DECISION-INPUT-MALFORMED" }),
        }
    end

    local phase = rawget(input, "phase")
    local cache = rawget(input, "cache")
    local current = rawget(input, "current")
    if phase ~= "startup" and phase ~= "fallback" then
        return {
            action = "INSPECT",
            reasons = json.array({ "CGCE-SCHED-DECISION-INPUT-MALFORMED" }),
        }
    end
    if phase == "startup" then
        reasons[#reasons + 1] = "CGCE-SCHED-STARTUP-LIVE-INSPECTION"
    end

    local cache_valid = valid_identity(cache, true)
    local current_valid = valid_identity(current, false)
    if cache == nil then
        reasons[#reasons + 1] = "CGCE-SCHED-CACHE-MISSING"
    elseif not cache_valid then
        reasons[#reasons + 1] = "CGCE-SCHED-CACHE-MALFORMED"
    elseif rawget(cache, "status") ~= "completed" then
        reasons[#reasons + 1] = "CGCE-SCHED-CACHE-NOT-COMPLETED"
    end
    if not current_valid then
        reasons[#reasons + 1] = "CGCE-SCHED-CURRENT-MALFORMED"
    end

    if cache_valid and current_valid then
        for _, comparison in ipairs({
            { field = "game_revision", reason = "CGCE-SCHED-REVISION-DRIFT" },
            { field = "target_slots", reason = "CGCE-SCHED-TARGET-DRIFT" },
            { field = "item_fingerprint", reason = "CGCE-SCHED-FINGERPRINT-DRIFT" },
            { field = "owner_guild_id", reason = "CGCE-SCHED-OWNER-DRIFT" },
        }) do
            if rawget(cache, comparison.field) ~= rawget(current, comparison.field) then
                reasons[#reasons + 1] = comparison.reason
            end
        end
    end

    if phase == "fallback" and #reasons == 0 then
        return { action = "SKIP", reasons = json.array({}) }
    end
    return { action = "INSPECT", reasons = reasons }
end

return scheduler
