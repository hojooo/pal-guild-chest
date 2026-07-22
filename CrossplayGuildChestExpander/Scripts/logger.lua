local json_module = require("CrossplayGuildChestExpander.Scripts.json")

local json_array = json_module.array
local json_encode = json_module.encode
local json_null = json_module.null

local logger = {}

local MAX_EVENT_BYTES = 16 * 1024
local REDACTED = "[REDACTED]"

local levels = {
    DEBUG = true,
    INFO = true,
    WARNING = true,
    BLOCKING = true,
    CRITICAL = true,
}

local credential_markers = {
    "password",
    "token",
    "secret",
    "credential",
    "authorization",
    "apikey",
    "privatekey",
}

local required_fields = { "timestamp", "level", "event" }
local required_lookup = {
    timestamp = true,
    level = true,
    event = true,
}

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

local function normalize_key(key)
    return key:lower():gsub("[^a-z0-9]", "")
end

local function credential_key(key)
    local normalized = normalize_key(key)
    for _, marker in ipairs(credential_markers) do
        if normalized:find(marker, 1, true) then
            return true
        end
    end
    return false
end

local function child_path(parent, key)
    if parent == "" then
        return key
    end
    return parent .. "." .. key
end

local function index_path(parent, index)
    return parent .. "[" .. tostring(index) .. "]"
end

local function table_kind(value, path)
    local count = 0
    local largest = 0
    local saw_number = false
    local saw_string = false

    for key in next, value do
        count = count + 1
        if type(key) == "number" then
            if math.type(key) ~= "integer" or key < 1 then
                fail("CGCE-LOG-VALUE", path, "log arrays must use positive integer indexes")
            end
            saw_number = true
            if key > largest then
                largest = key
            end
        elseif type(key) == "string" then
            if not valid_utf8(key) then
                fail("CGCE-LOG-VALUE", path, "log object keys must contain valid UTF-8")
            end
            saw_string = true
        else
            fail("CGCE-LOG-VALUE", path, "log object keys must be strings or dense array indexes")
        end
    end

    if count == 0 then
        local ok, encoded = pcall(json_encode, value)
        if not ok then
            fail("CGCE-LOG-VALUE", path, "empty log table must be JSON-safe")
        end
        return encoded == "[]" and "array" or "object", 0
    end
    if saw_number and saw_string then
        fail("CGCE-LOG-VALUE", path, "log tables cannot mix object and array keys")
    end
    if saw_number then
        if largest ~= count then
            fail("CGCE-LOG-VALUE", path, "log arrays must be dense")
        end
        return "array", count
    end
    return "object", count
end

local function sanitize_value(value, path, active)
    if value == json_null then
        return json_null
    end

    local value_type = type(value)
    if value_type == "string" then
        if not valid_utf8(value) then
            fail("CGCE-LOG-VALUE", path, "log strings must contain valid UTF-8")
        end
        return value
    end
    if value_type == "number" then
        if value ~= value or value == math.huge or value == -math.huge then
            fail("CGCE-LOG-VALUE", path, "log numbers must be finite")
        end
        return value
    end
    if value_type == "boolean" then
        return value
    end
    if value_type ~= "table" then
        fail("CGCE-LOG-VALUE", path, "log values must be JSON-safe")
    end
    if getmetatable(value) ~= nil then
        fail("CGCE-LOG-VALUE", path, "log tables must not have metatables")
    end
    if active[value] then
        fail("CGCE-LOG-VALUE", path, "log values must be acyclic")
    end

    active[value] = true
    local kind, length = table_kind(value, path)
    local copy
    if kind == "array" then
        copy = json_array({})
        for index = 1, length do
            copy[index] = sanitize_value(value[index], index_path(path, index), active)
        end
    else
        copy = {}
        local keys = {}
        for key in next, value do
            keys[#keys + 1] = key
        end
        table.sort(keys)
        for _, key in ipairs(keys) do
            local current_path = child_path(path, key)
            if credential_key(key) then
                copy[key] = REDACTED
            else
                copy[key] = sanitize_value(value[key], current_path, active)
            end
        end
    end
    active[value] = nil
    return copy
end

local function validate_required(value)
    if type(value) ~= "table" or getmetatable(value) ~= nil then
        fail("CGCE-LOG-EVENT", nil, "log event must be a plain object")
    end
    for _, field in ipairs(required_fields) do
        if value[field] == nil then
            fail("CGCE-LOG-MISSING-FIELD", field, "required log field is missing")
        end
        if type(value[field]) ~= "string" or #value[field] == 0 or not valid_utf8(value[field]) then
            fail("CGCE-LOG-FIELD", field, "required log fields must be non-empty UTF-8 strings")
        end
    end
    if not levels[value.level] then
        fail("CGCE-LOG-LEVEL", "level", "unsupported log level")
    end
end

local function sorted_object_keys(value)
    local keys = {}
    for key in next, value do
        keys[#keys + 1] = key
    end
    table.sort(keys)
    return keys
end

local function is_secondary_per_slot_key(key)
    local normalized = normalize_key(key)
    return normalized == "slotfingerprint"
        or normalized == "slotrecord"
        or normalized == "slotitem"
        or normalized == "slotguid"
        or normalized:sub(1, 7) == "perslot"
        or normalized:sub(1, 10) == "slotdetail"
end

local function find_per_slot_field(value, path)
    if type(value) ~= "table" or value == json_null then
        return nil
    end

    local kind, length = table_kind(value, path)
    if kind == "array" then
        for index = 1, length do
            local found = find_per_slot_field(value[index], index_path(path, index))
            if found then
                return found
            end
        end
        return nil
    end

    local keys = sorted_object_keys(value)
    for _, key in ipairs(keys) do
        if normalize_key(key) == "slotindex" then
            return child_path(path, key)
        end
    end
    for _, key in ipairs(keys) do
        if is_secondary_per_slot_key(key) then
            return child_path(path, key)
        end
        local found = find_per_slot_field(value[key], child_path(path, key))
        if found then
            return found
        end
    end
    return nil
end

local function sanitize_event(value)
    validate_required(value)
    local sanitized = sanitize_value(value, "", {})
    if sanitized.level ~= "DEBUG" then
        local per_slot = find_per_slot_field(sanitized, "")
        if per_slot then
            fail("CGCE-LOG-PER-SLOT", per_slot, "per-slot details require DEBUG level")
        end
    end
    return sanitized
end

local function encode_jsonl(value)
    return json_encode(value) .. "\n"
end

local function encode_text(value)
    local parts = {
        "[" .. json_encode(value.timestamp) .. "]",
        "[" .. value.level .. "]",
        json_encode(value.event),
    }
    for _, key in ipairs(sorted_object_keys(value)) do
        if not required_lookup[key] then
            parts[#parts + 1] = json_encode(key) .. "=" .. json_encode(value[key])
        end
    end
    return table.concat(parts, " ") .. "\n"
end

local function replacement_timestamp(timestamp)
    if #timestamp <= 256 then
        return timestamp
    end
    return "timestamp_omitted"
end

local function oversize_replacement(format, timestamp, original_size)
    return {
        timestamp = replacement_timestamp(timestamp),
        level = "WARNING",
        event = "log_event_oversize",
        format = format,
        original_size_bytes = original_size,
    }
end

local function format_event(value, format)
    local sanitized = sanitize_event(value)
    local encoded
    if format == "jsonl" then
        encoded = encode_jsonl(sanitized)
    else
        encoded = encode_text(sanitized)
    end
    if #encoded <= MAX_EVENT_BYTES then
        return encoded
    end

    local replacement = oversize_replacement(format, sanitized.timestamp, #encoded)
    local compact = format == "jsonl" and encode_jsonl(replacement) or encode_text(replacement)
    if #compact > MAX_EVENT_BYTES then
        fail("CGCE-LOG-OVERSIZE", nil, "oversize replacement exceeded the fixed event limit")
    end
    return compact
end

function logger.text(value)
    return format_event(value, "text")
end

function logger.jsonl(value)
    return format_event(value, "jsonl")
end

return logger
