local a = require("tests.support.assertions")
local command_router = require("CrossplayGuildChestExpander.Scripts.command_router")
local json = require("CrossplayGuildChestExpander.Scripts.json")

local function assert_error(code, err)
    a.equal("table", type(err))
    a.equal(code, err.code)
    a.equal("string", type(err.detail))
end

local function ports(overrides)
    local calls = {
        status = 0,
        audit = 0,
        guilds = 0,
        verify = 0,
        report_path = 0,
    }
    local source = {
        nested = { value = "detached" },
    }
    local ignored_status_extra = {}
    ignored_status_extra.self = ignored_status_extra
    local values = {
        status = {
            revision = 12345,
            mode = "audit",
            target = 358,
            state = "AUDIT_COMPLETE",
            diagnostic = source,
            approval_token = "never-expose-status-secret",
            ignored_status_extra = ignored_status_extra,
        },
        audit = { blocking_errors = {}, source = source },
        guilds = { { name = "Test Guild", state = "observed" } },
        verify = { live_match = true },
        report_path = "reports/discovery.json",
    }

    for key, value in pairs(overrides or {}) do
        values[key] = value
    end

    local result = {}
    for _, key in ipairs({ "status", "audit", "guilds", "verify", "report_path" }) do
        result[key] = function()
            calls[key] = calls[key] + 1
            local value = values[key]
            if type(value) == "function" then
                return value()
            end
            return value
        end
    end
    return result, calls, source
end

local function run(router, line)
    return command_router.execute(router, line)
end

describe("command_router", function()
    it("routes every read-only command with a detached status envelope", function()
        local read_ports, calls, source = ports()
        local router = command_router.new(read_ports)
        local expected_port = {
            status = "status",
            audit = "audit",
            guilds = "guilds",
            verify = "verify",
            ["export-report"] = "report_path",
        }

        for command, port_name in pairs(expected_port) do
            local response, err = run(router, "cgce " .. command)
            a.equal(nil, err)
            a.equal(command, response.command)
            a.equal(12345, response.revision)
            a.equal("audit", response.mode)
            a.equal(358, response.target)
            a.equal("AUDIT_COMPLETE", response.state)
            a.equal("table", type(response.payload))
            a.equal(true, calls[port_name] >= 1)

            if command == "audit" then
                response.payload.source.nested.value = "caller mutation"
                a.equal("detached", source.nested.value)
            elseif command == "status" then
                a.deep_equal({
                    revision = 12345,
                    mode = "audit",
                    target = 358,
                    state = "AUDIT_COMPLETE",
                }, response.payload)
                local encoded = json.encode(response)
                a.equal(false, encoded:find("approval_token", 1, true) ~= nil)
                a.equal(false, encoded:find("never-expose-status-secret", 1, true) ~= nil)
                a.equal(false, encoded:find("diagnostic", 1, true) ~= nil)
            end
        end
    end)

    it("rejects unknown commands, quoting, shell syntax, whitespace variants, and arguments without port calls", function()
        local read_ports, calls = ports()
        local router = command_router.new(read_ports)
        local rejected = {
            "CGCE status",
            "cgce  status",
            " cgce status",
            "cgce status ",
            "cgce status now",
            "cgce 'status'",
            'cgce "status"',
            "cgce status;apply",
            "cgce unknown",
            "status",
            "",
        }

        for _, line in ipairs(rejected) do
            local response, err = run(router, line)
            a.equal(nil, response)
            assert_error("CGCE-CMD-INVALID-COMMAND", err)
        end
        a.deep_equal({ status = 0, audit = 0, guilds = 0, verify = 0, report_path = 0 }, calls)
    end)

    it("returns mutation unavailable for apply and attempted apply arguments without touching any port", function()
        local trapped = {}
        for _, key in ipairs({ "status", "audit", "guilds", "verify", "report_path" }) do
            trapped[key] = function()
                error("read port must not run")
            end
        end
        local router = command_router.new(trapped)

        for _, line in ipairs({
            "cgce apply",
            "cgce apply --token=do-not-copy",
            "cgce apply mode=apply target=358",
        }) do
            local response, err = run(router, line)
            a.equal(nil, response)
            assert_error("MUTATION_BUILD_UNAVAILABLE", err)
            a.equal(false, err.detail:find("do%-not%-copy") ~= nil)
        end
    end)

    it("fails closed on non-strings and control characters without exposing command text", function()
        local read_ports, calls = ports()
        local router = command_router.new(read_ports)

        for _, line in ipairs({ false, {}, "cgce status\nsecret", "cgce\tstatus", "cgce status\0secret" }) do
            local response, err = run(router, line)
            a.equal(nil, response)
            assert_error("CGCE-CMD-INVALID-COMMAND", err)
            a.equal(false, err.detail:find("secret", 1, true) ~= nil)
        end
        a.deep_equal({ status = 0, audit = 0, guilds = 0, verify = 0, report_path = 0 }, calls)
    end)

    it("fails closed when a port fails or returns non-JSON-safe data", function()
        local failing_ports = ports({ audit = function() error("sensitive port failure") end })
        local router = command_router.new(failing_ports)
        local response, err = run(router, "cgce audit")
        a.equal(nil, response)
        assert_error("CGCE-CMD-PORT-FAILED", err)
        a.equal(false, err.detail:find("sensitive", 1, true) ~= nil)

        local cyclic = {}
        cyclic.self = cyclic
        local unsafe_ports = ports({ verify = cyclic })
        router = command_router.new(unsafe_ports)
        response, err = run(router, "cgce verify")
        a.equal(nil, response)
        assert_error("CGCE-CMD-OUTPUT-INVALID", err)
    end)

    it("preserves empty JSON arrays and explicitly rejects the shared null sentinel", function()
        local array_ports = ports({ audit = { findings = json.array({}) } })
        local response, err = run(command_router.new(array_ports), "cgce audit")
        a.equal(nil, err)
        a.equal('{"findings":[]}', json.encode(response.payload))

        local null_ports = ports({ audit = { missing = json.null } })
        response, err = run(command_router.new(null_ports), "cgce audit")
        a.equal(nil, response)
        assert_error("CGCE-CMD-OUTPUT-INVALID", err)
    end)

    it("requires semantic revision, mode, target, and state status fields", function()
        local invalid_statuses = {
            { revision = 0, mode = "audit", target = 358, state = "AUDIT_COMPLETE" },
            { revision = 12345, mode = "other", target = 358, state = "AUDIT_COMPLETE" },
            { revision = 12345, mode = "audit", target = 0, state = "AUDIT_COMPLETE" },
            { revision = 12345, mode = "audit", target = 358, state = "" },
        }

        for _, status in ipairs(invalid_statuses) do
            local read_ports = ports({ status = status })
            local response, err = run(command_router.new(read_ports), "cgce status")
            a.equal(nil, response)
            assert_error("CGCE-CMD-OUTPUT-INVALID", err)
        end
    end)

    it("accepts exactly five function ports and exposes no mutation operation", function()
        local valid = ports()
        local ok = pcall(command_router.new, valid)
        a.equal(true, ok)

        for _, invalid in ipairs({
            {},
            { status = function() end },
            {
                status = function() end,
                audit = function() end,
                guilds = function() end,
                verify = function() end,
                report_path = function() end,
                apply = function() end,
            },
        }) do
            ok = pcall(command_router.new, invalid)
            a.equal(false, ok)
        end

        for _, name in ipairs({ "apply", "resize", "append", "mark_dirty", "replicate", "set_property" }) do
            a.equal(nil, command_router[name])
        end

        for _, module in ipairs({
            require("CrossplayGuildChestExpander.Scripts.scheduler"),
            require("CrossplayGuildChestExpander.Scripts.platform_preflight"),
        }) do
            for _, name in ipairs({
                "apply",
                "resize",
                "append",
                "mark_dirty",
                "replicate",
                "set_property",
                "write_file",
            }) do
                a.equal(nil, module[name])
            end
        end
    end)
end)
