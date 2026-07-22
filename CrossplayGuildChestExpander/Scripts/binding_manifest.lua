local constants = require("CrossplayGuildChestExpander.Scripts.constants")
local json = require("CrossplayGuildChestExpander.Scripts.json")
local sha256 = require("CrossplayGuildChestExpander.Scripts.sha256")

local binding_manifest = {}

local json_array = json.array
local json_decode = json.decode
local json_encode = json.encode
local manifest_version = constants.versions.manifest
local sha256_hex = sha256.hex

local logical_symbols = {
    { name = "world_ready_function", kind = "function" },
    { name = "selected_world_class", kind = "class" },
    { name = "world_id_property", kind = "property" },
    { name = "guild_manager_class", kind = "class" },
    { name = "guild_list_property", kind = "property" },
    { name = "guild_id_property", kind = "property" },
    { name = "guild_name_property", kind = "property" },
    { name = "guild_chest_container_id_property", kind = "property" },
    { name = "guild_chest_class", kind = "class" },
    { name = "container_manager_class", kind = "class" },
    { name = "find_container_function", kind = "function" },
    { name = "container_id_property", kind = "property" },
    { name = "container_owner_guild_id_property", kind = "property" },
    { name = "slot_array_property", kind = "property" },
    { name = "slot_occupancy_discriminator_property", kind = "property" },
    { name = "item_static_id_property", kind = "property" },
    { name = "item_dynamic_guid_property", kind = "property" },
    { name = "item_quantity_property", kind = "property" },
    { name = "item_durability_property", kind = "property" },
    { name = "item_metadata_hash_inputs_property", kind = "property" },
    { name = "empty_slot_type", kind = "struct" },
    { name = "resize_function", kind = "function" },
    { name = "mark_dirty_function", kind = "function" },
    { name = "replicate_function", kind = "function" },
    { name = "new_guild_function", kind = "function" },
    { name = "container_in_use_function", kind = "function" },
    { name = "fatal_safe_stop_function", kind = "function" },
}

local symbol_kinds = {}
for _, symbol in ipairs(logical_symbols) do
    symbol_kinds[symbol.name] = symbol.kind
end

local discovery_fields = {
    manifest_version = true,
    kind = true,
    game_revision = true,
    symbols = true,
    tested_platform_matrix = true,
    checksum = true,
}

local discovery_field_order = {
    "manifest_version",
    "kind",
    "game_revision",
    "symbols",
    "tested_platform_matrix",
    "checksum",
}

local runtime_fields = {
    manifest_version = true,
    kind = true,
    game_revision = true,
    source_audit_checksum = true,
    symbols = true,
    tested_platform_matrix = true,
    checksum = true,
}

local runtime_field_order = {
    "manifest_version",
    "kind",
    "game_revision",
    "source_audit_checksum",
    "symbols",
    "tested_platform_matrix",
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

local parsed_manifests = setmetatable({}, { __mode = "k" })

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

local function parse_json(text)
    local ok, value = pcall(json_decode, text)
    if not ok then
        fail("CGCE-MAN-JSON", nil, "manifest is not valid JSON")
    end
    if type(value) ~= "table" or json_encode(value):sub(1, 1) ~= "{" then
        fail("CGCE-MAN-TYPE", nil, "manifest root must be an object")
    end
    return value
end

local function array_length(value, field)
    if type(value) ~= "table" then
        fail("CGCE-MAN-TYPE", field, field .. " must be an array")
    end
    if next(value) == nil and json_encode(value) ~= "[]" then
        fail("CGCE-MAN-TYPE", field, field .. " must be an array")
    end
    local count = 0
    local largest = 0
    for key in next, value do
        if type(key) ~= "number" or math.type(key) ~= "integer" or key < 1 then
            fail("CGCE-MAN-TYPE", field, field .. " must be an array")
        end
        count = count + 1
        if key > largest then
            largest = key
        end
    end
    if largest ~= count then
        fail("CGCE-MAN-TYPE", field, field .. " must be a dense array")
    end
    return count
end

local function is_sha256(value)
    return type(value) == "string" and #value == 64 and value:match("^[0-9a-f]+$") ~= nil
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

local function verify_checksum(value)
    if not is_sha256(value.checksum) then
        fail("CGCE-MAN-CHECKSUM", "checksum", "checksum must be lowercase SHA-256")
    end

    local unsigned = {}
    for key, item in next, value do
        if key ~= "checksum" then
            unsigned[key] = item
        end
    end
    if sha256_hex(json_encode(unsigned)) ~= value.checksum then
        fail("CGCE-MAN-CHECKSUM", "checksum", "manifest self-checksum mismatch")
    end
end

local function validate_top_level(value)
    if value.kind ~= "discovery" and value.kind ~= "runtime" then
        fail("CGCE-MAN-KIND", "kind", "manifest kind must be discovery or runtime")
    end
    local allowed = value.kind == "discovery" and discovery_fields or runtime_fields
    local ordered = value.kind == "discovery" and discovery_field_order or runtime_field_order
    local unknown = sorted_unknown_key(value, allowed)
    if unknown == false then
        fail("CGCE-MAN-UNKNOWN-KEY", nil, "manifest keys must be strings")
    end
    if unknown ~= nil then
        fail("CGCE-MAN-UNKNOWN-KEY", unknown, "unknown manifest key")
    end
    for _, field in ipairs(ordered) do
        if value[field] == nil then
            fail("CGCE-MAN-MISSING-KEY", field, "required manifest key is missing")
        end
    end
end

local function validate_platform_metadata(value)
    local length = array_length(value, "tested_platform_matrix")
    local seen = {}
    for index = 1, length do
        local platform = value[index]
        if not is_control_free(platform) or #platform == 0 then
            fail(
                "CGCE-MAN-PLATFORM-METADATA",
                "tested_platform_matrix",
                "platform metadata entries must be non-empty strings"
            )
        end
        if seen[platform] then
            fail(
                "CGCE-MAN-PLATFORM-METADATA",
                "tested_platform_matrix",
                "platform metadata entries must be unique"
            )
        end
        seen[platform] = true
    end
end

local function validate_descriptor(logical_name, descriptor, expected_kind)
    local prefix = "symbols." .. logical_name
    if type(descriptor) ~= "table" or getmetatable(descriptor) ~= nil then
        fail("CGCE-MAN-DESCRIPTOR-TYPE", prefix, "symbol descriptor must be a plain object")
    end

    local allowed = expected_kind == "property" and property_descriptor_fields or descriptor_fields
    local ordered = expected_kind == "property"
        and property_descriptor_field_order
        or descriptor_field_order
    local unknown = sorted_unknown_key(descriptor, allowed)
    if unknown == false then
        fail("CGCE-MAN-DESCRIPTOR-KEY", prefix, "descriptor keys must be strings")
    end
    if unknown ~= nil then
        fail("CGCE-MAN-DESCRIPTOR-KEY", prefix .. "." .. unknown, "unknown descriptor key")
    end
    for _, key in ipairs(ordered) do
        if descriptor[key] == nil then
            fail("CGCE-MAN-DESCRIPTOR-TYPE", prefix .. "." .. key, "descriptor key is required")
        end
    end
    if descriptor.kind ~= expected_kind then
        fail("CGCE-MAN-DESCRIPTOR-KIND", prefix .. ".kind", "descriptor kind does not match logical symbol")
    end
    if not is_exact_path(descriptor.path) then
        fail("CGCE-MAN-DESCRIPTOR-TYPE", prefix .. ".path", "descriptor path must be an exact absolute identity")
    end
    if not is_exact_signature(descriptor.type_signature) then
        fail(
            "CGCE-MAN-DESCRIPTOR-TYPE",
            prefix .. ".type_signature",
            "descriptor type signature must be exact and non-empty"
        )
    end
    if expected_kind == "property" then
        if not is_exact_path(descriptor.owner_path) then
            fail(
                "CGCE-MAN-DESCRIPTOR-TYPE",
                prefix .. ".owner_path",
                "property owner path must be an exact absolute identity"
            )
        end
        if not is_member_name(descriptor.member_name) then
            fail(
                "CGCE-MAN-DESCRIPTOR-TYPE",
                prefix .. ".member_name",
                "property member name must be an exact identifier"
            )
        end
    end
end

local function validate_symbols(value)
    if type(value.symbols) ~= "table" or json_encode(value.symbols):sub(1, 1) ~= "{" then
        fail("CGCE-MAN-TYPE", "symbols", "symbols must be an object")
    end
    if value.kind == "discovery" then
        if next(value.symbols) ~= nil then
            fail("CGCE-MAN-DISCOVERY-SYMBOLS", "symbols", "discovery manifests must have empty symbols")
        end
        return
    end

    local unknown = sorted_unknown_key(value.symbols, symbol_kinds)
    if unknown == false then
        fail("CGCE-MAN-UNKNOWN-SYMBOL", "symbols", "logical symbol names must be strings")
    end
    if unknown ~= nil then
        fail("CGCE-MAN-UNKNOWN-SYMBOL", "symbols." .. unknown, "unknown logical symbol")
    end
    for _, symbol in ipairs(logical_symbols) do
        local descriptor = value.symbols[symbol.name]
        if descriptor == nil then
            fail("CGCE-MAN-MISSING-SYMBOL", "symbols." .. symbol.name, "required logical symbol is missing")
        end
        validate_descriptor(symbol.name, descriptor, symbol.kind)
    end
end

function binding_manifest.parse(text)
    local value = parse_json(text)
    validate_top_level(value)
    verify_checksum(value)

    if value.manifest_version ~= manifest_version then
        fail("CGCE-MAN-VERSION", "manifest_version", "unsupported manifest version")
    end
    if type(value.game_revision) ~= "number"
        or math.type(value.game_revision) ~= "integer"
        or value.game_revision < 1 then
        fail("CGCE-MAN-REVISION", "game_revision", "game revision must be a positive integer")
    end
    if value.kind == "runtime" and not is_sha256(value.source_audit_checksum) then
        fail(
            "CGCE-MAN-AUDIT-CHECKSUM",
            "source_audit_checksum",
            "source audit checksum must be lowercase SHA-256"
        )
    end
    validate_platform_metadata(value.tested_platform_matrix)
    validate_symbols(value)

    parsed_manifests[value] = json_encode(value)
    return value
end

local function trusted_manifest_copy(manifest)
    local encoded = type(manifest) == "table" and parsed_manifests[manifest] or nil
    if encoded == nil then
        return nil
    end
    return json_decode(encoded)
end

local function copy_descriptor(descriptor)
    local copy = {
        kind = descriptor.kind,
        path = descriptor.path,
        type_signature = descriptor.type_signature,
    }
    if descriptor.kind == "property" then
        copy.owner_path = descriptor.owner_path
        copy.member_name = descriptor.member_name
    end
    return copy
end

local function descriptors_equal(expected, actual)
    if type(actual) ~= "table" or getmetatable(actual) ~= nil then
        return false
    end
    local allowed = expected.kind == "property" and property_descriptor_fields or descriptor_fields
    if sorted_unknown_key(actual, allowed) ~= nil then
        return false
    end
    for key in next, allowed do
        if rawget(actual, key) ~= expected[key] then
            return false
        end
    end
    return true
end

function binding_manifest.verify_types(manifest, adapter)
    local errors = json_array()
    local trusted = trusted_manifest_copy(manifest)
    if trusted == nil then
        errors[1] = problem("CGCE-MAN-AUTHORITY", "manifest", "manifest was not produced by binding_manifest.parse")
        return false, errors
    end
    if type(adapter) ~= "table" or type(rawget(adapter, "read_revision")) ~= "function" then
        errors[1] = problem("CGCE-MAN-ADAPTER", nil, "read-only revision inspection is unavailable")
        return false, errors
    end

    local read_revision = rawget(adapter, "read_revision")
    local revision_ok, live_revision, revision_error = pcall(read_revision)
    if not revision_ok
        or revision_error ~= nil
        or type(live_revision) ~= "number"
        or math.type(live_revision) ~= "integer"
        or live_revision < 1
        or live_revision ~= trusted.game_revision then
        errors[1] = problem("CGCE-MAN-REVISION", "game_revision", "live revision does not exactly match manifest")
        return false, errors
    end
    if trusted.kind == "discovery" then
        return true, errors
    end

    local inspect_descriptor = rawget(adapter, "inspect_descriptor")
    if type(inspect_descriptor) ~= "function" then
        errors[1] = problem("CGCE-MAN-ADAPTER", nil, "read-only descriptor inspection is unavailable")
        return false, errors
    end

    for _, symbol in ipairs(logical_symbols) do
        local expected = trusted.symbols[symbol.name]
        local inspected, actual, inspection_error = pcall(
            inspect_descriptor,
            symbol.name,
            copy_descriptor(expected)
        )
        if not inspected or inspection_error ~= nil or not descriptors_equal(expected, actual) then
            errors[#errors + 1] = problem(
                "CGCE-MAN-TYPE-MISMATCH",
                "symbols." .. symbol.name,
                "reflected descriptor does not exactly match manifest"
            )
        end
    end
    return #errors == 0, errors
end

return binding_manifest
