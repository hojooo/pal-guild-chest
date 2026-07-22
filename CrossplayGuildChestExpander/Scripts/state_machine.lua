local state_machine = {}

local machine_states = setmetatable({}, { __mode = "k" })

local terminal_states = {
    AUDIT_COMPLETE = true,
    AWAITING_APPROVAL = true,
    BLOCKED = true,
    UNSUPPORTED = true,
}

local transitions = {
    DISABLED = {
        enable = "PREFLIGHT",
    },
    PREFLIGHT = {
        preflight_unsupported = "UNSUPPORTED",
        preflight_blocked = "BLOCKED",
        world_waiting = "WAITING",
        world_ready = "AUDIT",
    },
    WAITING = {
        world_ready = "AUDIT",
        world_ready_timeout = "BLOCKED",
        discovery_failure = "BLOCKED",
    },
    AUDIT = {
        audit_conflicts = "BLOCKED",
        audit_blocked = "BLOCKED",
        audit_complete = true,
    },
}

local function make_error(code, field, detail)
    return {
        code = code,
        field = field,
        detail = detail,
    }
end

local function invalid_constructor(field, detail)
    error(make_error("CGCE-STATE-INVALID-CONTEXT", field, detail), 0)
end

local function unknown_context_field(value, allowed)
    local unknown_strings = {}
    local has_non_string = false
    for key in next, value do
        if type(key) ~= "string" then
            has_non_string = true
        elseif not allowed[key] then
            unknown_strings[#unknown_strings + 1] = key
        end
    end
    if has_non_string then
        return "context"
    end
    table.sort(unknown_strings)
    return unknown_strings[1]
end

local function validate_no_context(context)
    if context == nil then
        return nil
    end
    if type(context) ~= "table" then
        return make_error(
            "CGCE-STATE-INVALID-CONTEXT",
            "context",
            "event context must be a table"
        )
    end
    local field = unknown_context_field(context, {})
    if field ~= nil then
        return make_error(
            "CGCE-STATE-INVALID-CONTEXT",
            field,
            "event does not accept context fields"
        )
    end
    return nil
end

local function audit_completion_state(context)
    if type(context) ~= "table" then
        return nil, make_error(
            "CGCE-STATE-INVALID-CONTEXT",
            "context",
            "audit completion context must be a table"
        )
    end

    local allowed = {
        mode = true,
        approval_present = true,
    }
    local unknown = unknown_context_field(context, allowed)
    if unknown ~= nil then
        return nil, make_error(
            "CGCE-STATE-INVALID-CONTEXT",
            unknown,
            "unknown audit completion context field"
        )
    end

    local mode = rawget(context, "mode")
    local approval_present = rawget(context, "approval_present")
    if mode == "audit" then
        if approval_present ~= nil then
            return nil, make_error(
                "CGCE-STATE-INVALID-CONTEXT",
                "approval_present",
                "audit mode does not accept approval state"
            )
        end
        return "AUDIT_COMPLETE", nil
    end

    if mode == "apply" then
        if type(approval_present) ~= "boolean" then
            return nil, make_error(
                "CGCE-STATE-INVALID-CONTEXT",
                "approval_present",
                "apply mode requires an explicit boolean approval state"
            )
        end
        if approval_present then
            return "AUDIT_COMPLETE", nil
        end
        return "AWAITING_APPROVAL", nil
    end

    return nil, make_error(
        "CGCE-STATE-INVALID-CONTEXT",
        "mode",
        "mode must be audit or apply"
    )
end

local function require_state(handle)
    local current = machine_states[handle]
    if current == nil then
        return nil, make_error(
            "CGCE-STATE-INVALID-CONTEXT",
            "handle",
            "state machine handle is invalid"
        )
    end
    return current, nil
end

function state_machine.state(handle)
    return require_state(handle)
end

function state_machine.transition(handle, event, context)
    local current, handle_error = require_state(handle)
    if handle_error then
        return nil, handle_error
    end
    if event == "apply" then
        return current, make_error(
            "CGCE-STATE-MUTATION-BUILD-UNAVAILABLE",
            "event",
            "discovery build cannot perform mutation"
        )
    end

    if terminal_states[current] then
        return current, make_error(
            "CGCE-STATE-TERMINAL",
            "event",
            "execution epoch is terminal"
        )
    end

    if type(event) ~= "string" then
        return current, make_error(
            "CGCE-STATE-INVALID-EVENT",
            "event",
            "event must be a valid discovery event"
        )
    end

    local target = transitions[current] and transitions[current][event]
    if target == nil then
        return current, make_error(
            "CGCE-STATE-INVALID-EVENT",
            "event",
            "event is not valid from the current discovery state"
        )
    end

    local context_error
    if event == "audit_complete" then
        target, context_error = audit_completion_state(context)
    else
        context_error = validate_no_context(context)
    end
    if context_error then
        return current, context_error
    end

    machine_states[handle] = target
    return target, nil
end

function state_machine.new(context)
    if type(context) ~= "table" then
        invalid_constructor("context", "constructor context must be a table")
    end
    local unknown = unknown_context_field(context, { mutation_capability = true })
    if unknown ~= nil then
        invalid_constructor(unknown, "unknown constructor context field")
    end
    if rawget(context, "mutation_capability") ~= false then
        invalid_constructor(
            "mutation_capability",
            "discovery build requires mutation_capability=false"
        )
    end

    local handle = function() end
    machine_states[handle] = "DISABLED"
    return handle
end

return state_machine
