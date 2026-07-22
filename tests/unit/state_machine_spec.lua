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
    local state, err = state_machine.transition(machine, event, context)
    a.equal(expected_state, state)
    a.equal(nil, err)
    local current, state_err = state_machine.state(machine)
    a.equal(expected_state, current)
    a.equal(nil, state_err)
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
        a.equal("function", type(machine))
        a.equal("DISABLED", state_machine.state(machine))

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
            local before = state_machine.state(machine)
            local state, err = state_machine.transition(machine, "enable")
            a.equal(before, state)
            a.equal(before, state_machine.state(machine))
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
            local before = state_machine.state(machine)
            local state, err = state_machine.transition(
                machine,
                "apply",
                { token = "must-not-be-read" }
            )
            a.equal(before, state)
            a.equal(before, state_machine.state(machine))
            assert_error("CGCE-STATE-MUTATION-BUILD-UNAVAILABLE", "event", err)
        end
    end)

    it("rejects invalid events and contexts without changing state", function()
        local machine = new_machine()
        local state, err = state_machine.transition(machine, "world_ready")
        a.equal("DISABLED", state)
        assert_error("CGCE-STATE-INVALID-EVENT", "event", err)

        state, err = state_machine.transition(machine, "enable", { unexpected = true })
        a.equal("DISABLED", state)
        assert_error("CGCE-STATE-INVALID-CONTEXT", "unexpected", err)

        state, err = state_machine.transition(machine, "enable", "not-a-table")
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
            local state, err = state_machine.transition(machine, "audit_complete", context)
            a.equal("AUDIT", state)
            a.equal("CGCE-STATE-INVALID-CONTEXT", err.code)
            a.equal(false, err.detail:find("secret", 1, true) ~= nil)
        end
    end)

    it("uses deterministic fields for invalid context keys without address leakage", function()
        local machine = new_machine()
        local state, err = state_machine.transition(machine, "enable", {
            zebra = true,
            alpha = true,
        })
        a.equal("DISABLED", state)
        assert_error("CGCE-STATE-INVALID-CONTEXT", "alpha", err)

        local non_string_context = {}
        non_string_context[{}] = true
        non_string_context[function() end] = true
        non_string_context[io.stdout] = true
        state, err = state_machine.transition(machine, "enable", non_string_context)
        a.equal("DISABLED", state)
        assert_error("CGCE-STATE-INVALID-CONTEXT", "context", err)
        a.equal(false, err.detail:find("0x", 1, true) ~= nil)

        local constructor_context = {
            mutation_capability = false,
            zebra = true,
            alpha = true,
        }
        local ok, constructor_err = pcall(state_machine.new, constructor_context)
        a.equal(false, ok)
        assert_error("CGCE-STATE-INVALID-CONTEXT", "alpha", constructor_err)

        local non_string_constructor = { mutation_capability = false }
        non_string_constructor[{}] = true
        non_string_constructor[io.stdout] = true
        ok, constructor_err = pcall(state_machine.new, non_string_constructor)
        a.equal(false, ok)
        assert_error("CGCE-STATE-INVALID-CONTEXT", "context", constructor_err)
        a.equal(false, constructor_err.detail:find("0x", 1, true) ~= nil)
    end)

    it("rejects forged and invalid opaque handles without changing a real machine", function()
        local real = new_machine()
        local function assert_forged(forged)
            local state, err = state_machine.state(forged)
            a.equal(nil, state)
            assert_error("CGCE-STATE-INVALID-CONTEXT", "handle", err)

            state, err = state_machine.transition(forged, "enable")
            a.equal(nil, state)
            assert_error("CGCE-STATE-INVALID-CONTEXT", "handle", err)
        end
        for _, forged in ipairs({ function() end, {}, "forged", false }) do
            assert_forged(forged)
        end
        assert_forged(nil)
        a.equal("DISABLED", state_machine.state(real))
    end)

    it("accepts only a discovery build constructor context", function()
        for _, scenario in ipairs({
            { context = {}, field = "mutation_capability" },
            { context = { mutation_capability = true }, field = "mutation_capability" },
            {
                context = { mutation_capability = false, resizer = function() end },
                field = "resizer",
            },
            { context = "not-a-table", field = "context" },
        }) do
            local ok, err = pcall(state_machine.new, scenario.context)
            a.equal(false, ok)
            assert_error("CGCE-STATE-INVALID-CONTEXT", scenario.field, err)
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
            local state = state_machine.transition(machine, event, { mode = "audit" })
            a.equal(false, forbidden[state] == true)
            a.equal(false, forbidden[state_machine.state(machine)] == true)
        end
    end)
end)
