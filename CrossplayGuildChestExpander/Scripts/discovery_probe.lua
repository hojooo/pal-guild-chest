local json = require("CrossplayGuildChestExpander.Scripts.json")
local sha256 = require("CrossplayGuildChestExpander.Scripts.sha256")

local discovery_probe = {}

local PROBE_VERSION = "1.0"
local json_decode = json.decode
local json_encode = json.encode
local sha256_hex = sha256.hex

local logical_kinds = {
    world_ready_function = "function",
    world_ready_state_property = "property",
    selected_world_class = "class",
    world_id_property = "property",
    selected_world_guild_manager_property = "property",
    selected_world_container_manager_property = "property",
    guild_manager_class = "class",
    guild_class = "class",
    guild_list_property = "property",
    guild_id_property = "property",
    guild_name_property = "property",
    guild_chest_container_id_property = "property",
    guild_chest_class = "class",
    guild_chest_container_manager_property = "property",
    container_manager_class = "class",
    find_container_function = "function",
    container_id_property = "property",
    container_owner_guild_id_property = "property",
    slot_array_property = "property",
    slot_occupancy_discriminator_property = "property",
    item_static_id_property = "property",
    item_dynamic_guid_property = "property",
    item_quantity_property = "property",
    item_durability_property = "property",
    item_metadata_hash_inputs_property = "property",
    empty_slot_type = "struct",
    resize_function = "function",
    mark_dirty_function = "function",
    replicate_function = "function",
    new_guild_function = "function",
    container_in_use_function = "function",
    fatal_safe_stop_function = "function",
}

local top_fields = {
    probe_version = true,
    kind = true,
    authoritative = true,
    mutation_capability = true,
    candidates = true,
    checksum = true,
}

local top_field_order = {
    "probe_version",
    "kind",
    "authoritative",
    "mutation_capability",
    "candidates",
    "checksum",
}

local descriptor_fields = {
    kind = true,
    path = true,
    type_signature = true,
}

local property_descriptor_fields = {
    kind = true,
    owner_path = true,
    member_name = true,
    path = true,
    type_signature = true,
}

local descriptor_field_order = { "kind", "path", "type_signature" }
local property_descriptor_field_order = {
    "kind",
    "owner_path",
    "member_name",
    "path",
    "type_signature",
}

local parsed_requests = setmetatable({}, { __mode = "k" })

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

local function is_control_free(value)
    if type(value) ~= "string" then
        return false
    end
    for index = 1, #value do
        local byte = value:byte(index)
        if byte <= 31 or byte == 127 then
            return false
        end
    end
    return true
end

local function is_exact_path(value)
    return is_control_free(value)
        and #value > 1
        and value:sub(1, 1) == "/"
        and value:match("^%s") == nil
        and value:match("%s$") == nil
        and value:find("*", 1, true) == nil
        and value:find("?", 1, true) == nil
        and value:find("[", 1, true) == nil
        and value:find("]", 1, true) == nil
        and value:find("...", 1, true) == nil
end

local function has_wildcard_star(value)
    local start = 1
    while true do
        local index = value:find("*", start, true)
        if index == nil then
            return false
        end
        local previous = value:sub(index - 1, index - 1)
        local following = value:sub(index + 1, index + 1)
        local pointer_prefix = previous:match("[A-Za-z0-9_>]") ~= nil
        local pointer_suffix = following == ""
            or following == ">"
            or following == ","
            or following == ")"
            or following == " "
            or following == "&"
        if not pointer_prefix or not pointer_suffix then
            return true
        end
        start = index + 1
    end
end

local function is_exact_signature(value)
    return is_control_free(value)
        and #value > 0
        and value:match("^%s") == nil
        and value:match("%s$") == nil
        and not has_wildcard_star(value)
        and value:find("?", 1, true) == nil
        and value:find("[", 1, true) == nil
        and value:find("]", 1, true) == nil
        and value:find("...", 1, true) == nil
end

local function is_member_name(value)
    return is_control_free(value) and value:match("^[A-Za-z_][A-Za-z0-9_]*$") ~= nil
end

local function is_sha256(value)
    return type(value) == "string" and #value == 64 and value:match("^[0-9a-f]+$") ~= nil
end

local function parse_json(text)
    local ok, value = pcall(json_decode, text)
    if not ok then
        fail("CGCE-PROBE-JSON", nil, "probe request is not valid JSON")
    end
    if type(value) ~= "table" or json_encode(value):sub(1, 1) ~= "{" then
        fail("CGCE-PROBE-TYPE", nil, "probe request root must be an object")
    end
    return value
end

local function array_length(value, field)
    if type(value) ~= "table" then
        fail("CGCE-PROBE-CANDIDATES", field, "candidate list must be a dense array")
    end
    if next(value) == nil and json_encode(value) ~= "[]" then
        fail("CGCE-PROBE-CANDIDATES", field, "candidate list must be a dense array")
    end
    local count = 0
    local largest = 0
    for key in next, value do
        if type(key) ~= "number" or math.type(key) ~= "integer" or key < 1 then
            fail("CGCE-PROBE-CANDIDATES", field, "candidate list must be a dense array")
        end
        count = count + 1
        if key > largest then
            largest = key
        end
    end
    if largest ~= count or count == 0 then
        fail("CGCE-PROBE-CANDIDATES", field, "candidate list must be a non-empty dense array")
    end
    return count
end

local function validate_top_level(value)
    local unknown = sorted_unknown_key(value, top_fields)
    if unknown == false then
        fail("CGCE-PROBE-UNKNOWN-KEY", nil, "probe request keys must be strings")
    end
    if unknown ~= nil then
        fail("CGCE-PROBE-UNKNOWN-KEY", unknown, "unknown probe request key")
    end
    for _, field in ipairs(top_field_order) do
        if value[field] == nil then
            fail("CGCE-PROBE-MISSING-KEY", field, "required probe request key is missing")
        end
    end
    if value.probe_version ~= PROBE_VERSION then
        fail("CGCE-PROBE-VERSION", "probe_version", "unsupported probe request version")
    end
    if value.kind ~= "discovery_probe_request" then
        fail("CGCE-PROBE-KIND", "kind", "kind must be discovery_probe_request")
    end
    if value.authoritative ~= false then
        fail("CGCE-PROBE-AUTHORITY", "authoritative", "discovery probe requests are non-authoritative")
    end
    if value.mutation_capability ~= false then
        fail("CGCE-PROBE-AUTHORITY", "mutation_capability", "discovery probe requests cannot mutate")
    end
end

local function verify_checksum(value)
    if not is_sha256(value.checksum) then
        fail("CGCE-PROBE-CHECKSUM", "checksum", "checksum must be lowercase SHA-256")
    end
    local unsigned = {}
    for key, item in next, value do
        if key ~= "checksum" then
            unsigned[key] = item
        end
    end
    if sha256_hex(json_encode(unsigned)) ~= value.checksum then
        fail("CGCE-PROBE-CHECKSUM", "checksum", "probe request self-checksum mismatch")
    end
end

local function validate_descriptor(logical_name, index, descriptor, expected_kind)
    local prefix = "candidates." .. logical_name .. "[" .. index .. "]"
    if type(descriptor) ~= "table" or getmetatable(descriptor) ~= nil then
        fail("CGCE-PROBE-DESCRIPTOR-TYPE", prefix, "candidate descriptor must be a plain object")
    end

    local allowed = expected_kind == "property" and property_descriptor_fields or descriptor_fields
    local ordered = expected_kind == "property"
        and property_descriptor_field_order
        or descriptor_field_order
    local unknown = sorted_unknown_key(descriptor, allowed)
    if unknown == false then
        fail("CGCE-PROBE-DESCRIPTOR-KEY", prefix, "candidate descriptor keys must be strings")
    end
    if unknown ~= nil then
        fail("CGCE-PROBE-DESCRIPTOR-KEY", prefix .. "." .. unknown, "unknown candidate descriptor key")
    end
    for _, field in ipairs(ordered) do
        if descriptor[field] == nil then
            fail("CGCE-PROBE-DESCRIPTOR-TYPE", prefix .. "." .. field, "candidate descriptor key is required")
        end
    end
    if descriptor.kind ~= expected_kind then
        fail("CGCE-PROBE-DESCRIPTOR-KIND", prefix .. ".kind", "candidate kind does not match logical symbol")
    end
    if not is_exact_path(descriptor.path) then
        fail("CGCE-PROBE-DESCRIPTOR-TYPE", prefix .. ".path", "candidate path must be an exact absolute identity")
    end
    if not is_exact_signature(descriptor.type_signature) then
        fail(
            "CGCE-PROBE-DESCRIPTOR-TYPE",
            prefix .. ".type_signature",
            "candidate type signature must be exact and non-empty"
        )
    end
    if expected_kind == "property" then
        if not is_exact_path(descriptor.owner_path) then
            fail(
                "CGCE-PROBE-DESCRIPTOR-TYPE",
                prefix .. ".owner_path",
                "candidate property owner path must be exact and absolute"
            )
        end
        if not is_member_name(descriptor.member_name) then
            fail(
                "CGCE-PROBE-DESCRIPTOR-TYPE",
                prefix .. ".member_name",
                "candidate property member name must be an exact identifier"
            )
        end
    end
end

local function validate_candidates(value)
    if type(value.candidates) ~= "table"
        or getmetatable(value.candidates) ~= nil
        or json_encode(value.candidates):sub(1, 1) ~= "{" then
        fail("CGCE-PROBE-CANDIDATES", "candidates", "candidates must be a plain object")
    end
    local unknown = sorted_unknown_key(value.candidates, logical_kinds)
    if unknown == false then
        fail("CGCE-PROBE-UNKNOWN-SYMBOL", "candidates", "logical symbol names must be strings")
    end
    if unknown ~= nil then
        fail("CGCE-PROBE-UNKNOWN-SYMBOL", "candidates." .. unknown, "unknown logical symbol")
    end

    local logical_names = {}
    for logical_name in next, value.candidates do
        logical_names[#logical_names + 1] = logical_name
    end
    table.sort(logical_names)
    for _, logical_name in ipairs(logical_names) do
        local candidate_list = value.candidates[logical_name]
        local length = array_length(candidate_list, "candidates." .. logical_name)
        local seen = {}
        for index = 1, length do
            local descriptor = candidate_list[index]
            validate_descriptor(logical_name, index, descriptor, logical_kinds[logical_name])
            local identity = json_encode(descriptor)
            if seen[identity] then
                fail(
                    "CGCE-PROBE-DUPLICATE",
                    "candidates." .. logical_name .. "[" .. index .. "]",
                    "duplicate exact candidate descriptor"
                )
            end
            seen[identity] = true
        end
    end
end

function discovery_probe.parse(text)
    local value = parse_json(text)
    validate_top_level(value)
    verify_checksum(value)
    validate_candidates(value)

    local handle = function() end
    parsed_requests[handle] = {
        encoded = json_encode(value),
        checksum = value.checksum,
    }
    return handle
end

local function require_request(handle)
    local record = parsed_requests[handle]
    if record == nil then
        fail("CGCE-PROBE-HANDLE", "handle", "discovery probe handle is invalid")
    end
    return record
end

function discovery_probe.to_table(handle)
    return json_decode(require_request(handle).encoded)
end

function discovery_probe.checksum(handle)
    return require_request(handle).checksum
end

function discovery_probe.authoritative(handle)
    require_request(handle)
    return false
end

function discovery_probe.mutation_capability(handle)
    require_request(handle)
    return false
end

return discovery_probe
