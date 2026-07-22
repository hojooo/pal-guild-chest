local json = require("CrossplayGuildChestExpander.Scripts.json")

local command_router = {}

local router_ports = setmetatable({}, { __mode = "k" })

local port_names = {
    "status",
    "audit",
    "guilds",
    "verify",
    "report_path",
}

local allowed_ports = {}
for _, name in ipairs(port_names) do
    allowed_ports[name] = true
end

local command_ports = {
    audit = "audit",
    guilds = "guilds",
    verify = "verify",
    ["export-report"] = "report_path",
}

local function make_error(code, field, detail)
    return {
        code = code,
        field = field,
        detail = detail,
    }
end

local function fail_constructor(field, detail)
    error(make_error("INVALID_COMMAND_PORTS", field, detail), 0)
end

local function sorted_unknown_field(value)
    local unknown = {}
    local non_string = false
    for key in next, value do
        if type(key) ~= "string" then
            non_string = true
        elseif not allowed_ports[key] then
            unknown[#unknown + 1] = key
        end
    end
    if non_string then
        return "ports"
    end
    table.sort(unknown)
    return unknown[1]
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
    if value == nil or contains_json_null(value, {}) then
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

local function call_port(port)
    local called, value, port_error = pcall(port)
    if not called or port_error ~= nil or value == nil then
        return nil, make_error(
            "COMMAND_PORT_FAILED",
            "port",
            "read-only command port failed"
        )
    end
    return value, nil
end

local function status_envelope(ports)
    local value, port_error = call_port(ports.status)
    if port_error then
        return nil, port_error
    end
    local detached, ok = detach(value)
    if not ok or type(detached) ~= "table" then
        return nil, make_error(
            "COMMAND_OUTPUT_INVALID",
            "status",
            "status output must be a detached JSON object"
        )
    end
    for _, field in ipairs({ "revision", "mode", "target", "state" }) do
        if detached[field] == nil then
            return nil, make_error(
                "COMMAND_OUTPUT_INVALID",
                field,
                "status output is missing a required envelope field"
            )
        end
    end
    if type(detached.revision) ~= "number"
        or math.type(detached.revision) ~= "integer"
        or detached.revision < 1 then
        return nil, make_error(
            "COMMAND_OUTPUT_INVALID",
            "revision",
            "status revision must be a positive integer"
        )
    end
    if detached.mode ~= "audit" and detached.mode ~= "apply" then
        return nil, make_error(
            "COMMAND_OUTPUT_INVALID",
            "mode",
            "status mode must be audit or apply"
        )
    end
    if type(detached.target) ~= "number"
        or math.type(detached.target) ~= "integer"
        or detached.target < 1 then
        return nil, make_error(
            "COMMAND_OUTPUT_INVALID",
            "target",
            "status target must be a positive integer"
        )
    end
    if type(detached.state) ~= "string" or detached.state == "" then
        return nil, make_error(
            "COMMAND_OUTPUT_INVALID",
            "state",
            "status state must be a non-empty string"
        )
    end
    return detached, nil
end

local function has_control(text)
    return text:find("[%z\1-\31\127]") ~= nil
end

local function parse_command(line)
    if type(line) ~= "string" or has_control(line) then
        return nil, make_error("INVALID_COMMAND", "command", "command must be one control-free line")
    end

    if line == "cgce apply" or line:match("^cgce apply +") then
        return nil, make_error(
            "MUTATION_BUILD_UNAVAILABLE",
            "command",
            "discovery build cannot perform mutation"
        )
    end

    local command = line:match("^cgce ([a-z%-]+)$")
    if command ~= "status" and command_ports[command] == nil then
        return nil, make_error("INVALID_COMMAND", "command", "unknown or malformed discovery command")
    end
    return command, nil
end

function command_router.execute(handle, line)
    local ports = router_ports[handle]
    if ports == nil then
        return nil, make_error("INVALID_COMMAND_ROUTER", "handle", "command router handle is invalid")
    end

    local command, parse_error = parse_command(line)
    if parse_error then
        return nil, parse_error
    end

    local status, status_error = status_envelope(ports)
    if status_error then
        return nil, status_error
    end

    local payload = status
    if command ~= "status" then
        local value, port_error = call_port(ports[command_ports[command]])
        if port_error then
            return nil, port_error
        end
        if command == "export-report" then
            if type(value) ~= "string" or value == "" or has_control(value) then
                return nil, make_error(
                    "COMMAND_OUTPUT_INVALID",
                    "report_path",
                    "report path must be a non-empty control-free string"
                )
            end
            value = { path = value }
        end
        local ok
        payload, ok = detach(value)
        if not ok then
            return nil, make_error(
                "COMMAND_OUTPUT_INVALID",
                "payload",
                "command output must be a detached JSON value"
            )
        end
    end

    return {
        command = command,
        revision = status.revision,
        mode = status.mode,
        target = status.target,
        state = status.state,
        payload = payload,
    }, nil
end

function command_router.new(ports)
    if type(ports) ~= "table" then
        fail_constructor("ports", "constructor requires exactly five read-only ports")
    end
    local unknown = sorted_unknown_field(ports)
    if unknown ~= nil then
        fail_constructor(unknown, "unknown command port")
    end

    local copy = {}
    for _, name in ipairs(port_names) do
        local port = rawget(ports, name)
        if type(port) ~= "function" then
            fail_constructor(name, "read-only command port must be a function")
        end
        copy[name] = port
    end

    local handle = function() end
    router_ports[handle] = copy
    return handle
end

return command_router
