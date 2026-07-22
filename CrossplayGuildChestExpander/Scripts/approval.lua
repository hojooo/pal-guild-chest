local constants_module = require("CrossplayGuildChestExpander.Scripts.constants")
local sha256_hex = require("CrossplayGuildChestExpander.Scripts.sha256").hex

local approval = {}

local SCHEMA = "cgce.operator-approval.v1"
local DEPLOYMENT_PROFILE = constants_module.deployment_profile

local field_order = {
    "world_id",
    "game_revision",
    "audit_checksum",
    "requested_target_slots",
    "deployment_profile",
}

local allowed_fields = {}
for _, field in ipairs(field_order) do
    allowed_fields[field] = true
end

local target_candidates = {}
for _, target in ipairs(constants_module.target_slot_candidates) do
    target_candidates[target] = true
end

local function fail(code, field, detail)
    error({ code = code, field = field, detail = detail }, 0)
end

local function valid_utf8(text)
    local index = 1
    while index <= #text do
        local first = text:byte(index)
        local second = text:byte(index + 1)
        local third = text:byte(index + 2)
        local fourth = text:byte(index + 3)

        if first <= 0x7F then
            index = index + 1
        elseif first >= 0xC2 and first <= 0xDF
            and second and second >= 0x80 and second <= 0xBF then
            index = index + 2
        elseif first == 0xE0
            and second and second >= 0xA0 and second <= 0xBF
            and third and third >= 0x80 and third <= 0xBF then
            index = index + 3
        elseif ((first >= 0xE1 and first <= 0xEC) or (first >= 0xEE and first <= 0xEF))
            and second and second >= 0x80 and second <= 0xBF
            and third and third >= 0x80 and third <= 0xBF then
            index = index + 3
        elseif first == 0xED
            and second and second >= 0x80 and second <= 0x9F
            and third and third >= 0x80 and third <= 0xBF then
            index = index + 3
        elseif first == 0xF0
            and second and second >= 0x90 and second <= 0xBF
            and third and third >= 0x80 and third <= 0xBF
            and fourth and fourth >= 0x80 and fourth <= 0xBF then
            index = index + 4
        elseif first >= 0xF1 and first <= 0xF3
            and second and second >= 0x80 and second <= 0xBF
            and third and third >= 0x80 and third <= 0xBF
            and fourth and fourth >= 0x80 and fourth <= 0xBF then
            index = index + 4
        elseif first == 0xF4
            and second and second >= 0x80 and second <= 0x8F
            and third and third >= 0x80 and third <= 0xBF
            and fourth and fourth >= 0x80 and fourth <= 0xBF then
            index = index + 4
        else
            return false
        end
    end
    return true
end

local function unknown_field(fields)
    local unknown = {}
    local has_non_string = false
    for key in next, fields do
        if type(key) ~= "string" then
            has_non_string = true
        elseif not allowed_fields[key] then
            unknown[#unknown + 1] = key
        end
    end
    if has_non_string then
        return "<non-string>"
    end
    table.sort(unknown)
    return unknown[1]
end

local function validate_fields(fields)
    if type(fields) ~= "table" or getmetatable(fields) ~= nil then
        fail("CGCE-APP-FIELDS", nil, "approval fields must be a plain table")
    end

    local unknown = unknown_field(fields)
    if unknown then
        fail("CGCE-APP-UNKNOWN-FIELD", unknown, "unknown approval field")
    end
    for _, field in ipairs(field_order) do
        if fields[field] == nil then
            fail("CGCE-APP-MISSING-FIELD", field, "required approval field is missing")
        end
    end

    if type(fields.world_id) ~= "string" or #fields.world_id == 0 or not valid_utf8(fields.world_id) then
        fail("CGCE-APP-WORLD-ID", "world_id", "world_id must be a non-empty UTF-8 string")
    end
    if type(fields.game_revision) ~= "number"
        or math.type(fields.game_revision) ~= "integer"
        or fields.game_revision <= 0 then
        fail("CGCE-APP-REVISION", "game_revision", "game_revision must be a positive integer")
    end
    if type(fields.audit_checksum) ~= "string"
        or #fields.audit_checksum ~= 64
        or not fields.audit_checksum:match("^[0-9a-f]+$") then
        fail("CGCE-APP-AUDIT-CHECKSUM", "audit_checksum", "audit_checksum must be lowercase SHA-256")
    end
    if type(fields.requested_target_slots) ~= "number"
        or math.type(fields.requested_target_slots) ~= "integer"
        or not target_candidates[fields.requested_target_slots] then
        fail("CGCE-APP-TARGET", "requested_target_slots", "requested_target_slots must be an approved candidate")
    end
    if fields.deployment_profile ~= DEPLOYMENT_PROFILE then
        fail("CGCE-APP-PROFILE", "deployment_profile", "deployment_profile must match the fixed profile")
    end
end

local function length_prefix(value)
    return tostring(#value) .. ":" .. value
end

local function make_token(fields)
    validate_fields(fields)

    local preimage = length_prefix(SCHEMA)
        .. length_prefix("world_id")
        .. length_prefix(fields.world_id)
        .. length_prefix("game_revision")
        .. length_prefix(tostring(fields.game_revision))
        .. length_prefix("audit_checksum")
        .. length_prefix(fields.audit_checksum)
        .. length_prefix("requested_target_slots")
        .. length_prefix(tostring(fields.requested_target_slots))
        .. length_prefix("deployment_profile")
        .. length_prefix(fields.deployment_profile)

    return sha256_hex(preimage)
end

local function valid_candidate(candidate)
    return type(candidate) == "string"
        and #candidate == 64
        and candidate:match("^[0-9a-f]+$") ~= nil
end

local function constant_time_equal(expected, candidate)
    local difference = 0
    for index = 1, 64 do
        difference = difference | (expected:byte(index) ~ candidate:byte(index))
    end
    return difference == 0
end

function approval.token(fields)
    return make_token(fields)
end

function approval.verify(fields, candidate)
    if not valid_candidate(candidate) then
        return false
    end

    local ok, expected = pcall(make_token, fields)
    if not ok then
        return false
    end
    return constant_time_equal(expected, candidate)
end

return approval
