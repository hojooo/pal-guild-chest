local binding_manifest = require("CrossplayGuildChestExpander.Scripts.binding_manifest")
local json = require("CrossplayGuildChestExpander.Scripts.json")

local revision_guard = {}

local json_array = json.array
local parse_manifest = binding_manifest.parse
local verify_manifest_types = binding_manifest.verify_types

local binding_sessions = setmetatable({}, { __mode = "k" })

local context_fields = {
    read_revision = true,
    load_manifest = true,
    inspect_descriptor = true,
}

local context_field_order = {
    "read_revision",
    "load_manifest",
    "inspect_descriptor",
}

local function problem(code, field, detail)
    return { code = code, field = field, detail = detail }
end

local function fail(code, field, detail)
    error(problem(code, field, detail), 0)
end

local function sorted_unknown_key(value, allowed)
    local unknown = {}
    local non_string = false
    for key in next, value do
        if type(key) ~= "string" then
            non_string = true
        elseif not allowed[key] then
            unknown[#unknown + 1] = key
        end
    end
    if non_string then
        return false
    end
    table.sort(unknown)
    return unknown[1]
end

local function capture_context(context)
    if type(context) ~= "table" or getmetatable(context) ~= nil then
        fail("CGCE-REV-CONTEXT", "context", "revision guard context must be a plain table")
    end
    local unknown = sorted_unknown_key(context, context_fields)
    if unknown == false then
        fail("CGCE-REV-CONTEXT", "context", "revision guard context keys must be strings")
    end
    if unknown ~= nil then
        fail("CGCE-REV-CONTEXT", unknown, "unknown revision guard context field")
    end

    local captured = {}
    for _, field in ipairs(context_field_order) do
        local port = rawget(context, field)
        if type(port) ~= "function" then
            fail("CGCE-REV-CONTEXT", field, "required strict read-only port is unavailable")
        end
        captured[field] = port
    end
    return captured
end

local function outcome(status, game_revision, manifest_kind, manifest_checksum, errors)
    return {
        status = status,
        game_revision = game_revision,
        manifest_kind = manifest_kind,
        manifest_checksum = manifest_checksum,
        mutation_capability = false,
        errors = errors or json_array(),
    }
end

local function one_error(code, field, detail)
    return json_array({ problem(code, field, detail) })
end

local function dense_length(value)
    if type(value) ~= "table" or getmetatable(value) ~= nil then
        return nil
    end
    local count = 0
    local largest = 0
    for key in next, value do
        if type(key) ~= "number" or math.type(key) ~= "integer" or key < 1 then
            return nil
        end
        count = count + 1
        if key > largest then
            largest = key
        end
    end
    if largest ~= count then
        return nil
    end
    return count
end

local function select_manifest(source)
    if source == nil then
        return nil, "missing"
    end
    if type(source) == "string" then
        return source, nil
    end
    local length = dense_length(source)
    if length == nil then
        return nil, "malformed"
    end
    if length == 0 then
        return nil, "malformed"
    end
    if length > 1 then
        return nil, "duplicate"
    end
    if type(rawget(source, 1)) ~= "string" then
        return nil, "malformed"
    end
    return rawget(source, 1), nil
end

local function safe_manifest_error(value)
    if type(value) ~= "table" then
        return problem("CGCE-REV-MANIFEST-MALFORMED", "manifest", "binding manifest validation failed")
    end
    local code = rawget(value, "code")
    local field = rawget(value, "field")
    local detail = rawget(value, "detail")
    if type(code) ~= "string"
        or (field ~= nil and type(field) ~= "string")
        or type(detail) ~= "string" then
        return problem("CGCE-REV-MANIFEST-MALFORMED", "manifest", "binding manifest validation failed")
    end
    return { code = code, field = field, detail = detail }
end

local function copy_descriptor(value)
    local copy = {
        kind = value.kind,
        path = value.path,
        type_signature = value.type_signature,
    }
    if value.kind == "property" then
        copy.owner_path = value.owner_path
        copy.member_name = value.member_name
    end
    return copy
end

local function snapshot_runtime_manifest(value)
    local descriptors = {}
    for logical_name, descriptor in next, value.symbols do
        descriptors[logical_name] = copy_descriptor(descriptor)
    end
    return {
        game_revision = value.game_revision,
        manifest_checksum = value.checksum,
        source_audit_checksum = value.source_audit_checksum,
        manifest_kind = value.kind,
        descriptors = descriptors,
    }
end

local function create_binding_session(snapshot)
    local handle = function() end
    binding_sessions[handle] = snapshot
    return handle
end

local function require_binding_session(session)
    local trusted = type(session) == "function" and binding_sessions[session] or nil
    if trusted == nil then
        fail("CGCE-REV-SESSION", "session", "value is not a verified binding session")
    end
    return trusted
end

function revision_guard.binding_metadata(session)
    local trusted = require_binding_session(session)
    return {
        game_revision = trusted.game_revision,
        manifest_checksum = trusted.manifest_checksum,
        source_audit_checksum = trusted.source_audit_checksum,
        manifest_kind = trusted.manifest_kind,
    }
end

function revision_guard.descriptor(session, logical_name)
    local trusted = require_binding_session(session)
    local value = type(logical_name) == "string"
        and trusted.descriptors[logical_name]
        or nil
    if value == nil then
        fail(
            "CGCE-REV-LOGICAL-NAME",
            "logical_name",
            "logical name is not present in the verified binding session"
        )
    end
    return copy_descriptor(value)
end

function revision_guard.check(context)
    local ports = capture_context(context)

    local revision_ok, live_revision, revision_error = pcall(ports.read_revision)
    if not revision_ok
        or revision_error ~= nil
        or type(live_revision) ~= "number"
        or math.type(live_revision) ~= "integer"
        or live_revision < 1 then
        return outcome(
            "BLOCKED",
            nil,
            nil,
            nil,
            one_error(
                "CGCE-REV-LIVE-REVISION-UNAVAILABLE",
                "game_revision",
                "strict live revision reader did not return one positive integer"
            )
        )
    end

    local load_ok, source, load_error = pcall(ports.load_manifest, live_revision)
    if not load_ok or load_error ~= nil then
        return outcome(
            "BLOCKED",
            live_revision,
            nil,
            nil,
            one_error("CGCE-REV-MANIFEST-LOAD", "manifest", "exact manifest lookup failed")
        )
    end

    local manifest_text, selection_error = select_manifest(source)
    if selection_error == "missing" then
        return outcome(
            "UNSUPPORTED",
            live_revision,
            nil,
            nil,
            one_error(
                "CGCE-REV-MANIFEST-NOT-FOUND",
                "manifest",
                "no exact runtime binding manifest exists for the live revision"
            )
        )
    end
    if selection_error == "duplicate" then
        return outcome(
            "BLOCKED",
            live_revision,
            nil,
            nil,
            one_error(
                "CGCE-REV-MANIFEST-DUPLICATE",
                "manifest",
                "multiple exact manifests exist for the live revision"
            )
        )
    end
    if selection_error ~= nil then
        return outcome(
            "BLOCKED",
            live_revision,
            nil,
            nil,
            one_error(
                "CGCE-REV-MANIFEST-LOAD",
                "manifest",
                "exact manifest lookup returned malformed data"
            )
        )
    end

    local parsed_ok, manifest_or_error = pcall(parse_manifest, manifest_text)
    if not parsed_ok then
        return outcome(
            "BLOCKED",
            live_revision,
            nil,
            nil,
            json_array({ safe_manifest_error(manifest_or_error) })
        )
    end

    local manifest = manifest_or_error
    local manifest_kind = rawget(manifest, "kind")
    local manifest_checksum = rawget(manifest, "checksum")
    local manifest_snapshot = manifest_kind == "runtime"
        and snapshot_runtime_manifest(manifest)
        or nil
    local verified, verification_errors = verify_manifest_types(manifest, {
        read_revision = function()
            return live_revision
        end,
        inspect_descriptor = ports.inspect_descriptor,
    })
    if not verified then
        return outcome(
            "BLOCKED",
            live_revision,
            manifest_kind,
            manifest_checksum,
            verification_errors
        )
    end

    if manifest_kind ~= "runtime" then
        return outcome(
            "UNSUPPORTED",
            live_revision,
            manifest_kind,
            manifest_checksum,
            one_error(
                "CGCE-REV-RUNTIME-MANIFEST-UNAVAILABLE",
                "manifest_kind",
                "an exact verified runtime binding manifest is unavailable"
            )
        )
    end

    return outcome(
        "SUPPORTED",
        live_revision,
        manifest_kind,
        manifest_checksum,
        json_array()
    ), create_binding_session(manifest_snapshot)
end

return revision_guard
