local constants = require("CrossplayGuildChestExpander.Scripts.constants")
local json = require("CrossplayGuildChestExpander.Scripts.json")

local config = {}
local config_version = constants.versions.config
local deployment_profile = constants.deployment_profile
local required_clients = {}
for index, client in ipairs(constants.required_clients) do
    required_clients[index] = client
end
local json_decode = json.decode
local json_encode = json.encode

local fields = {
    "config_version",
    "deployment_profile",
    "mode",
    "requested_target_slots",
    "certified_target_slots",
    "certification_mode",
    "required_clients",
    "optional_clients",
    "expand_only",
    "require_operator_approval",
    "approval_token",
    "fail_fast",
    "include_guild_ids",
    "exclude_guild_ids",
    "new_guild_hook_enabled",
    "fallback_rescan_enabled",
    "fallback_rescan_seconds",
    "verify_on_startup",
    "write_migration_ledger",
    "log_level",
    "structured_log",
}

local allowed_fields = {}
for _, field in ipairs(fields) do
    allowed_fields[field] = true
end

local target_candidates = {}
for _, slots in ipairs(constants.target_slot_candidates) do
    target_candidates[slots] = true
end

local function fail(code, field, detail)
    error({ code = code, field = field, detail = detail }, 0)
end

local function parse_json(text)
    local ok, value = pcall(json_decode, text)
    if not ok then
        fail("CGCE-CFG-JSON", nil, "configuration is not valid JSON")
    end
    if type(value) ~= "table" then
        fail("CGCE-CFG-TYPE", nil, "configuration root must be an object")
    end
    if json_encode(value):sub(1, 1) ~= "{" then
        fail("CGCE-CFG-TYPE", nil, "configuration root must be an object")
    end
    return value
end

local function require_type(value, expected, field)
    if type(value) ~= expected then
        fail("CGCE-CFG-TYPE", field, field .. " must be a " .. expected)
    end
end

local function array_length(value, field)
    if type(value) ~= "table" then
        fail("CGCE-CFG-TYPE", field, field .. " must be an array")
    end
    if next(value) == nil and json_encode(value) ~= "[]" then
        fail("CGCE-CFG-TYPE", field, field .. " must be an array")
    end

    local count = 0
    local largest = 0
    for key in pairs(value) do
        if type(key) ~= "number" or math.type(key) ~= "integer" or key < 1 then
            fail("CGCE-CFG-TYPE", field, field .. " must be an array")
        end
        count = count + 1
        if key > largest then
            largest = key
        end
    end
    if largest ~= count then
        fail("CGCE-CFG-TYPE", field, field .. " must be a dense array")
    end
    return count
end

local function equal_array(actual, expected)
    if array_length(actual, "required_clients") ~= #expected then
        return false
    end
    for index, expected_value in ipairs(expected) do
        if actual[index] ~= expected_value then
            return false
        end
    end
    return true
end

local function validate_boolean(value, field)
    require_type(value, "boolean", field)
end

local function validate_guild_ids(value, field)
    local length = array_length(value, field)
    local seen = {}
    for index = 1, length do
        local guild_id = value[index]
        if type(guild_id) ~= "string" or #guild_id == 0 then
            fail("CGCE-CFG-GUILD-ID", field, field .. " entries must be non-empty UTF-8 strings")
        end
        if seen[guild_id] then
            fail("CGCE-CFG-DUPLICATE", field, field .. " entries must be unique")
        end
        seen[guild_id] = true
    end
    return seen
end

local function validate_schema(value)
    for key in pairs(value) do
        if not allowed_fields[key] then
            fail("CGCE-CFG-UNKNOWN-KEY", key, "unknown config key")
        end
    end
    for _, field in ipairs(fields) do
        if value[field] == nil then
            fail("CGCE-CFG-MISSING-KEY", field, "required config key is missing")
        end
    end
end

function config.parse(text)
    local value = parse_json(text)
    validate_schema(value)

    if value.config_version ~= config_version then
        fail("CGCE-CFG-VERSION", "config_version", "unsupported configuration version")
    end
    if value.deployment_profile ~= deployment_profile then
        fail("CGCE-CFG-PROFILE", "deployment_profile", "unsupported deployment profile")
    end

    require_type(value.mode, "string", "mode")
    if value.mode ~= "audit" and value.mode ~= "apply" then
        fail("CGCE-CFG-MODE", "mode", "mode must be audit or apply")
    end

    if type(value.requested_target_slots) ~= "number"
        or math.type(value.requested_target_slots) ~= "integer"
        or not target_candidates[value.requested_target_slots] then
        fail("CGCE-CFG-TARGET-CANDIDATE", "requested_target_slots", "target must be an allowed slot candidate")
    end

    local certified_length = array_length(value.certified_target_slots, "certified_target_slots")
    if certified_length == 0 then
        fail("CGCE-CFG-CERTIFIED-TARGETS", "certified_target_slots", "at least one local certified target is required")
    end
    local previous
    local locally_certified = {}
    for index = 1, certified_length do
        local slots = value.certified_target_slots[index]
        if type(slots) ~= "number" or math.type(slots) ~= "integer" or not target_candidates[slots]
            or (previous and slots <= previous) then
            fail("CGCE-CFG-CERTIFIED-TARGETS", "certified_target_slots", "targets must be unique ascending slot candidates")
        end
        locally_certified[slots] = true
        previous = slots
    end

    validate_boolean(value.certification_mode, "certification_mode")
    if not value.certification_mode and not locally_certified[value.requested_target_slots] then
        fail("CGCE-CFG-LOCAL-CERTIFICATION", "requested_target_slots", "target is not locally enabled")
    end

    if not equal_array(value.required_clients, required_clients) then
        fail("CGCE-CFG-REQUIRED-CLIENTS", "required_clients", "required clients must match the canonical ordered list")
    end

    local optional_length = array_length(value.optional_clients, "optional_clients")
    local optional_seen = {}
    for index = 1, optional_length do
        local client = value.optional_clients[index]
        if client ~= "Xbox" or optional_seen[client] then
            fail("CGCE-CFG-OPTIONAL-CLIENTS", "optional_clients", "optional clients must be a unique Xbox subset")
        end
        optional_seen[client] = true
    end

    validate_boolean(value.expand_only, "expand_only")
    if value.expand_only ~= true then
        fail("CGCE-CFG-EXPAND-ONLY", "expand_only", "expand_only must be true")
    end
    validate_boolean(value.require_operator_approval, "require_operator_approval")
    require_type(value.approval_token, "string", "approval_token")

    validate_boolean(value.fail_fast, "fail_fast")
    local included = validate_guild_ids(value.include_guild_ids, "include_guild_ids")
    local excluded = validate_guild_ids(value.exclude_guild_ids, "exclude_guild_ids")
    for guild_id in pairs(included) do
        if excluded[guild_id] then
            fail("CGCE-CFG-GUILD-OVERLAP", "include_guild_ids", "guild filters must be disjoint")
        end
    end

    validate_boolean(value.new_guild_hook_enabled, "new_guild_hook_enabled")
    validate_boolean(value.fallback_rescan_enabled, "fallback_rescan_enabled")
    if type(value.fallback_rescan_seconds) ~= "number" or math.type(value.fallback_rescan_seconds) ~= "integer" then
        fail("CGCE-CFG-TYPE", "fallback_rescan_seconds", "fallback_rescan_seconds must be an integer")
    end
    if value.fallback_rescan_seconds < 30 then
        fail("CGCE-CFG-RESCAN", "fallback_rescan_seconds", "fallback rescan must be at least 30 seconds")
    end
    validate_boolean(value.verify_on_startup, "verify_on_startup")
    validate_boolean(value.write_migration_ledger, "write_migration_ledger")
    require_type(value.log_level, "string", "log_level")
    if #value.log_level == 0 then
        fail("CGCE-CFG-LOG-LEVEL", "log_level", "log level must not be empty")
    end
    validate_boolean(value.structured_log, "structured_log")

    return value
end

return config
