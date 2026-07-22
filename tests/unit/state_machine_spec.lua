local a = require("tests.support.assertions")
local state_machine = require("CrossplayGuildChestExpander.Scripts.state_machine")

local function assert_error(expected_code, expected_field, actual)
    a.equal("table", type(actual))
    a.equal(expected_code, actual.code)
    a.equal(expected_field, actual.field)
    a.equal("string", type(actual.detail))
end

local function new_machine()
    return state_machine.new({ mutation_capability = false })
end

local function transition(machine, event, context, expected_state)
    local state, err = machine:transition(event, context)
    a.equal(expected_state, state)
    a.equal(nil, err)
    a.equal(expected_state, machine:state())
end

local function at_audit()
    local machine = new_machine()
    transition(machine, "enable", nil, "PREFLIGHT")
    transition(machine, "world_ready", nil, "AUDIT")
    return machine
end

describe("discovery-safe state machine", function()
    it("takes the direct ready path to an audit-only completion", function()
        local machine = new_machine()
        a.equal("DISABLED", machine:state())

        transition(machine, "enable", nil, "PREFLIGHT")
        transition(machine, "world_ready", nil, "AUDIT")
        transition(machine, "audit_complete", { mode = "audit" }, "AUDIT_COMPLETE")
    end)

    it("takes the bounded waiting path and blocks readiness failures", function()
        local ready = new_machine()
        transition(ready, "enable", nil, "PREFLIGHT")
        transition(ready, "world_waiting", nil, "WAITING")
        transition(ready, "world_ready", nil, "AUDIT")

        for _, event in ipairs({ "world_ready_timeout", "discovery_failure" }) do
            local blocked = new_machine()
            transition(blocked, "enable", nil, "PREFLIGHT")
            transition(blocked, "world_waiting", nil, "WAITING")
            transition(blocked, event, nil, "BLOCKED")
        end
    end)

    it("maps preflight and audit blockers to terminal states", function()
        local unsupported = new_machine()
        transition(unsupported, "enable", nil, "PREFLIGHT")
        transition(unsupported, "preflight_unsupported", nil, "UNSUPPORTED")

        local preflight_blocked = new_machine()
        transition(preflight_blocked, "enable", nil, "PREFLIGHT")
        transition(preflight_blocked, "preflight_blocked", nil, "BLOCKED")

        local audit_blocked = at_audit()
        transition(audit_blocked, "audit_conflicts", nil, "BLOCKED")
    end)

    it("blocks generic post-audit validation and persistence failures", function()
        local machine = at_audit()

        transition(machine, "audit_blocked", nil, "BLOCKED")
    end)

    it("finishes apply-mode discovery without approval as awaiting approval", function()
        local machine = at_audit()
        transition(
            machine,
            "audit_complete",
            { mode = "apply", approval_present = false },
            "AWAITING_APPROVAL"
        )
    end)

    it("finishes approved apply-mode discovery without acquiring apply authority", function()
        local machine = at_audit()
        transition(
            machine,
            "audit_complete",
            { mode = "apply", approval_present = true },
            "AUDIT_COMPLETE"
        )
    end)

    it("keeps all completion and failure outcomes terminal for the epoch", function()
        local terminal_machines = {}

        local complete = at_audit()
        transition(complete, "audit_complete", { mode = "audit" }, "AUDIT_COMPLETE")
        terminal_machines[#terminal_machines + 1] = complete

        local approval = at_audit()
        transition(
            approval,
            "audit_complete",
            { mode = "apply", approval_present = false },
            "AWAITING_APPROVAL"
        )
        terminal_machines[#terminal_machines + 1] = approval

        local blocked = new_machine()
        transition(blocked, "enable", nil, "PREFLIGHT")
        transition(blocked, "preflight_blocked", nil, "BLOCKED")
        terminal_machines[#terminal_machines + 1] = blocked

        local unsupported = new_machine()
        transition(unsupported, "enable", nil, "PREFLIGHT")
        transition(unsupported, "preflight_unsupported", nil, "UNSUPPORTED")
        terminal_machines[#terminal_machines + 1] = unsupported

        for _, machine in ipairs(terminal_machines) do
            local before = machine:state()
            local state, err = machine:transition("enable")
            a.equal(before, state)
            a.equal(before, machine:state())
            assert_error("CGCE-STATE-TERMINAL", "event", err)
        end
    end)

    it("rejects apply from every discovery state without changing state", function()
        local machines = { new_machine() }

        local preflight = new_machine()
        transition(preflight, "enable", nil, "PREFLIGHT")
        machines[#machines + 1] = preflight

        local waiting = new_machine()
        transition(waiting, "enable", nil, "PREFLIGHT")
        transition(waiting, "world_waiting", nil, "WAITING")
        machines[#machines + 1] = waiting

        machines[#machines + 1] = at_audit()

        local complete = at_audit()
        transition(complete, "audit_complete", { mode = "audit" }, "AUDIT_COMPLETE")
        machines[#machines + 1] = complete

        local approval = at_audit()
        transition(
            approval,
            "audit_complete",
            { mode = "apply", approval_present = false },
            "AWAITING_APPROVAL"
        )
        machines[#machines + 1] = approval

        local blocked = new_machine()
        transition(blocked, "enable", nil, "PREFLIGHT")
        transition(blocked, "preflight_blocked", nil, "BLOCKED")
        machines[#machines + 1] = blocked

        local unsupported = new_machine()
        transition(unsupported, "enable", nil, "PREFLIGHT")
        transition(unsupported, "preflight_unsupported", nil, "UNSUPPORTED")
        machines[#machines + 1] = unsupported

        for _, machine in ipairs(machines) do
            local before = machine:state()
            local state, err = machine:transition("apply", { token = "must-not-be-read" })
            a.equal(before, state)
            a.equal(before, machine:state())
            assert_error("CGCE-STATE-MUTATION-BUILD-UNAVAILABLE", "event", err)
        end
    end)

    it("rejects invalid events and contexts without changing state", function()
        local machine = new_machine()
        local state, err = machine:transition("world_ready")
        a.equal("DISABLED", state)
        assert_error("CGCE-STATE-INVALID-EVENT", "event", err)

        state, err = machine:transition("enable", { unexpected = true })
        a.equal("DISABLED", state)
        assert_error("CGCE-STATE-INVALID-CONTEXT", "unexpected", err)

        state, err = machine:transition("enable", "not-a-table")
        a.equal("DISABLED", state)
        assert_error("CGCE-STATE-INVALID-CONTEXT", "context", err)
    end)

    it("validates audit completion context without leaking approval values", function()
        for _, context in ipairs({
            {},
            { mode = "other" },
            { mode = "apply" },
            { mode = "apply", approval_present = "yes" },
            { mode = "audit", approval_present = true },
            { mode = "audit", approval_present = false, token = "secret" },
        }) do
            local machine = at_audit()
            local state, err = machine:transition("audit_complete", context)
            a.equal("AUDIT", state)
            a.equal("CGCE-STATE-INVALID-CONTEXT", err.code)
            a.equal(false, err.detail:find("secret", 1, true) ~= nil)
        end
    end)

    it("accepts only a discovery build constructor context", function()
        for _, context in ipairs({
            {},
            { mutation_capability = true },
            { mutation_capability = false, resizer = function() end },
            "not-a-table",
        }) do
            local ok, err = pcall(state_machine.new, context)
            a.equal(false, ok)
            assert_error("CGCE-STATE-INVALID-CONTEXT", nil, err)
        end
    end)

    it("never reaches a mutation state through any discovery event", function()
        local forbidden = {
            APPLYING = true,
            VALIDATING = true,
            COMPLETE = true,
            FAILED_AFTER_MUTATION = true,
        }
        local events = {
            "enable",
            "preflight_unsupported",
            "preflight_blocked",
            "world_waiting",
            "world_ready",
            "world_ready_timeout",
            "discovery_failure",
            "audit_conflicts",
            "audit_blocked",
            "audit_complete",
            "apply",
        }

        for _, event in ipairs(events) do
            local machine = new_machine()
            local state = machine:transition(event, { mode = "audit" })
            a.equal(false, forbidden[state] == true)
            a.equal(false, forbidden[machine:state()] == true)
        end
    end)
end)
