local state_machine = {}

local machine_methods = {}
machine_methods.__index = machine_methods
machine_methods.__newindex = function()
    error("discovery state machine is read-only", 2)
end
machine_methods.__metatable = "discovery state machine is read-only"

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

local function invalid_constructor(detail)
    error(make_error("CGCE-STATE-INVALID-CONTEXT", nil, detail), 0)
end

local function sorted_keys(value)
    local keys = {}
    for key in next, value do
        keys[#keys + 1] = key
    end
    table.sort(keys, function(left, right)
        return tostring(left) < tostring(right)
    end)
    return keys
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
    local key = next(context)
    if key ~= nil then
        return make_error(
            "CGCE-STATE-INVALID-CONTEXT",
            tostring(key),
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
    for _, key in ipairs(sorted_keys(context)) do
        if type(key) ~= "string" or not allowed[key] then
            return nil, make_error(
                "CGCE-STATE-INVALID-CONTEXT",
                tostring(key),
                "unknown audit completion context field"
            )
        end
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

function machine_methods:state()
    return machine_states[self]
end

function machine_methods:transition(event, context)
    local current = machine_states[self]
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

    machine_states[self] = target
    return target, nil
end

function state_machine.new(context)
    if type(context) ~= "table" then
        invalid_constructor("constructor context must be a table")
    end
    for key in next, context do
        if key ~= "mutation_capability" then
            invalid_constructor("unknown constructor context field")
        end
    end
    if rawget(context, "mutation_capability") ~= false then
        invalid_constructor("discovery build requires mutation_capability=false")
    end

    local machine = setmetatable({}, machine_methods)
    machine_states[machine] = "DISABLED"
    return machine
end

return state_machine
