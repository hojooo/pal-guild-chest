local constants = require("CrossplayGuildChestExpander.Scripts.constants")
local json = require("CrossplayGuildChestExpander.Scripts.json")
local sha256 = require("CrossplayGuildChestExpander.Scripts.sha256")

local binding_manifest = {}

local logical_symbols = {
    { name = "world_ready_function", kind = "function" },
    { name = "guild_manager_class", kind = "class" },
    { name = "guild_list_property", kind = "property" },
    { name = "guild_id_property", kind = "property" },
    { name = "guild_chest_container_id_property", kind = "property" },
    { name = "container_manager_class", kind = "class" },
    { name = "find_container_function", kind = "function" },
    { name = "container_owner_guild_id_property", kind = "property" },
    { name = "slot_array_property", kind = "property" },
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

local runtime_fields = {
    manifest_version = true,
    kind = true,
    game_revision = true,
    source_audit_checksum = true,
    symbols = true,
    tested_platform_matrix = true,
    checksum = true,
}

local descriptor_fields = {
    kind = true,
    path = true,
    type_signature = true,
}

local function problem(code, field, detail)
    return { code = code, field = field, detail = detail }
end

local function fail(code, field, detail)
    error(problem(code, field, detail), 0)
end

local function parse_json(text)
    local ok, value = pcall(json.decode, text)
    if not ok then
        fail("CGCE-MAN-JSON", nil, "manifest is not valid JSON")
    end
    if type(value) ~= "table" then
        fail("CGCE-MAN-TYPE", nil, "manifest root must be an object")
    end
    if json.encode(value):sub(1, 1) ~= "{" then
        fail("CGCE-MAN-TYPE", nil, "manifest root must be an object")
    end
    return value
end

local function array_length(value, field)
    if type(value) ~= "table" then
        fail("CGCE-MAN-TYPE", field, field .. " must be an array")
    end
    if next(value) == nil and json.encode(value) ~= "[]" then
        fail("CGCE-MAN-TYPE", field, field .. " must be an array")
    end
    local count = 0
    local largest = 0
    for key in pairs(value) do
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

local function verify_checksum(value)
    if not is_sha256(value.checksum) then
        fail("CGCE-MAN-CHECKSUM", "checksum", "checksum must be lowercase SHA-256")
    end

    local unsigned = {}
    for key, item in pairs(value) do
        if key ~= "checksum" then
            unsigned[key] = item
        end
    end
    if sha256.hex(json.encode(unsigned)) ~= value.checksum then
        fail("CGCE-MAN-CHECKSUM", "checksum", "manifest self-checksum mismatch")
    end
end

local function validate_top_level(value)
    if value.kind ~= "discovery" and value.kind ~= "runtime" then
        fail("CGCE-MAN-KIND", "kind", "manifest kind must be discovery or runtime")
    end
    local allowed = value.kind == "discovery" and discovery_fields or runtime_fields
    for key in pairs(value) do
        if not allowed[key] then
            fail("CGCE-MAN-UNKNOWN-KEY", key, "unknown manifest key")
        end
    end
    for field in pairs(allowed) do
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
        if type(platform) ~= "string" or #platform == 0 then
            fail("CGCE-MAN-PLATFORM-METADATA", "tested_platform_matrix", "platform metadata entries must be non-empty strings")
        end
        if seen[platform] then
            fail("CGCE-MAN-PLATFORM-METADATA", "tested_platform_matrix", "platform metadata entries must be unique")
        end
        seen[platform] = true
    end
end

local function validate_descriptor(logical_name, descriptor, expected_kind)
    local prefix = "symbols." .. logical_name
    if type(descriptor) ~= "table" then
        fail("CGCE-MAN-DESCRIPTOR-TYPE", prefix, "symbol descriptor must be an object")
    end
    for key in pairs(descriptor) do
        if not descriptor_fields[key] then
            fail("CGCE-MAN-DESCRIPTOR-KEY", prefix .. "." .. tostring(key), "unknown descriptor key")
        end
    end
    for key in pairs(descriptor_fields) do
        if descriptor[key] == nil then
            fail("CGCE-MAN-DESCRIPTOR-TYPE", prefix .. "." .. key, "descriptor key is required")
        end
    end
    if descriptor.kind ~= expected_kind then
        fail("CGCE-MAN-DESCRIPTOR-KIND", prefix .. ".kind", "descriptor kind does not match logical symbol")
    end
    if type(descriptor.path) ~= "string" or #descriptor.path == 0 then
        fail("CGCE-MAN-DESCRIPTOR-TYPE", prefix .. ".path", "descriptor path must be a non-empty exact string")
    end
    if type(descriptor.type_signature) ~= "string" or #descriptor.type_signature == 0 then
        fail("CGCE-MAN-DESCRIPTOR-TYPE", prefix .. ".type_signature", "descriptor type signature must be non-empty")
    end
end

local function validate_symbols(value)
    if type(value.symbols) ~= "table" then
        fail("CGCE-MAN-TYPE", "symbols", "symbols must be an object")
    end
    if json.encode(value.symbols):sub(1, 1) ~= "{" then
        fail("CGCE-MAN-TYPE", "symbols", "symbols must be an object")
    end
    if value.kind == "discovery" then
        if next(value.symbols) ~= nil then
            fail("CGCE-MAN-DISCOVERY-SYMBOLS", "symbols", "discovery manifests must have empty symbols")
        end
        return
    end

    for logical_name in pairs(value.symbols) do
        if not symbol_kinds[logical_name] then
            fail("CGCE-MAN-UNKNOWN-SYMBOL", "symbols." .. tostring(logical_name), "unknown logical symbol")
        end
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

    if value.manifest_version ~= constants.versions.manifest then
        fail("CGCE-MAN-VERSION", "manifest_version", "unsupported manifest version")
    end
    if type(value.game_revision) ~= "number" or math.type(value.game_revision) ~= "integer" or value.game_revision < 1 then
        fail("CGCE-MAN-REVISION", "game_revision", "game revision must be a positive integer")
    end
    if value.kind == "runtime" and not is_sha256(value.source_audit_checksum) then
        fail("CGCE-MAN-AUDIT-CHECKSUM", "source_audit_checksum", "source audit checksum must be lowercase SHA-256")
    end
    validate_platform_metadata(value.tested_platform_matrix)
    validate_symbols(value)
    return value
end

local function descriptors_equal(expected, actual)
    return type(actual) == "table"
        and actual.kind == expected.kind
        and actual.path == expected.path
        and actual.type_signature == expected.type_signature
end

function binding_manifest.verify_types(manifest, adapter)
    local errors = {}
    if type(adapter) ~= "table" or type(adapter.read_revision) ~= "function" then
        errors[1] = problem("CGCE-MAN-ADAPTER", nil, "read-only revision inspection is unavailable")
        return false, errors
    end

    local revision_ok, live_revision = pcall(adapter.read_revision)
    if not revision_ok or live_revision ~= manifest.game_revision then
        errors[1] = problem("CGCE-MAN-REVISION", "game_revision", "live revision does not exactly match manifest")
        return false, errors
    end
    if manifest.kind == "discovery" then
        return true, errors
    end
    if type(adapter.inspect_descriptor) ~= "function" then
        errors[1] = problem("CGCE-MAN-ADAPTER", nil, "read-only descriptor inspection is unavailable")
        return false, errors
    end

    for _, symbol in ipairs(logical_symbols) do
        local expected = manifest.symbols[symbol.name]
        local inspected, actual = pcall(adapter.inspect_descriptor, symbol.name, expected)
        if not inspected or not descriptors_equal(expected, actual) then
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
