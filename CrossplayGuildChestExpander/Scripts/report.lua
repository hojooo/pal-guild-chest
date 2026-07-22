local audit_module = require("CrossplayGuildChestExpander.Scripts.audit")
local fingerprint_module = require("CrossplayGuildChestExpander.Scripts.fingerprint")
local json_module = require("CrossplayGuildChestExpander.Scripts.json")
local path_guard_module = require("CrossplayGuildChestExpander.Scripts.path_guard")
local sha256_module = require("CrossplayGuildChestExpander.Scripts.sha256")

local audit_canonical_json = audit_module.canonical_json
local audit_checksum = audit_module.checksum
local audit_to_table = audit_module.to_table
local fingerprint_compute = fingerprint_module.compute
local json_array = json_module.array
local json_decode = json_module.decode
local json_encode = json_module.encode
local path_resolve = path_guard_module.resolve
local sha256_hex = sha256_module.hex

local report = {}
local built_reports = setmetatable({}, { __mode = "k" })

local REPORT_SCHEMA = "cgce.operational-report.v1"
local TERMINAL_STATES = {
    AUDIT_COMPLETE = true,
    AWAITING_APPROVAL = true,
    BLOCKED = true,
}
local MODES = { audit = true, apply = true }
local SEVERITIES = {
    INFO = true,
    WARNING = true,
    BLOCKING = true,
    CRITICAL = true,
}
local PREFLIGHT_STATES = {
    CONNECTIVITY_PREFLIGHT_OK = true,
    PS5_CONNECTIVITY_MISCONFIGURED = true,
}
local SECRET_FRAGMENTS = {
    "password",
    "token",
    "authorization",
    "cookie",
    "secret",
    "credential",
    "apikey",
    "privatekey",
}

local context_fields = {
    "audit",
    "mode",
    "state",
    "mod_version",
    "binding_manifest_checksum",
    "platform_preflight",
    "conflict_summary",
    "mod_inventory",
    "findings",
}
local report_fields = {
    "schema",
    "report_kind",
    "build_kind",
    "release_eligible",
    "mode",
    "state",
    "mod_version",
    "world_id",
    "game_revision",
    "deployment_profile",
    "target_slots",
    "binding_manifest_checksum",
    "audit_checksum",
    "audit",
    "platform_preflight",
    "conflict_summary",
    "mod_inventory",
    "findings",
    "checksum",
}
local preflight_fields = {
    "preflight_ok",
    "state",
    "certification",
    "diagnostic_only",
    "evidence",
}
local evidence_fields = {
    public_lobby = true,
    game_port = true,
    public_port = true,
    ini_public_port = true,
    required_platforms = true,
    xbox = true,
    client_mod_allowed = true,
    log_format = true,
}
local conflict_fields = { "coverage", "blocking", "forced_noop" }
local mod_fields = { "package_name", "package_version" }
local finding_fields = { "code", "severity", "field", "detail", "forced_noop" }
local audit_fields = {
    "schema",
    "world_id",
    "game_revision",
    "deployment_profile",
    "target_slots",
    "include_guild_ids",
    "exclude_guild_ids",
    "guilds",
    "blocking_errors",
    "checksum",
}
local audit_guild_allowed = {
    guild_id = true,
    guild_name = true,
    chest_container_id = true,
    status = true,
    eligible_action = true,
    errors = true,
    snapshot = true,
}
local audit_error_fields = { "code", "field", "detail" }
local snapshot_fields = {
    "version",
    "container_id",
    "owner_guild_id",
    "slot_count",
    "occupied_slot_count",
    "total_item_quantity",
    "slots",
    "item_fingerprint",
}
local empty_slot_allowed = { index = true, empty = true }
local occupied_slot_allowed = {
    index = true,
    empty = true,
    static_id = true,
    dynamic_guid = true,
    quantity = true,
    durability = true,
    instance_metadata_hash = true,
}

local function fail(code, field, detail)
    error({ code = code, field = field, detail = detail }, 0)
end

local function is_plain_table(value)
    return type(value) == "table" and getmetatable(value) == nil
end

local function allowed_map(fields)
    local result = {}
    for _, field in ipairs(fields) do
        result[field] = true
    end
    return result
end

local function validate_object(value, fields, field, code)
    if not is_plain_table(value) then
        fail(code, field, field .. " must be a plain object")
    end
    local allowed = allowed_map(fields)
    local unknown = {}
    local invalid_key = false
    for key in next, value do
        if type(key) ~= "string" then
            invalid_key = true
        elseif not allowed[key] then
            unknown[#unknown + 1] = key
        end
    end
    table.sort(unknown)
    if unknown[1] ~= nil then
        local prefix = field == "context" and "" or (field .. ".")
        fail(code, prefix .. unknown[1], "unknown report field")
    end
    if invalid_key then
        fail(code, field .. "[invalid-key]", "report object keys must be strings")
    end
    for _, name in ipairs(fields) do
        if rawget(value, name) == nil then
            local prefix = field == "context" and "" or (field .. ".")
            fail(code, prefix .. name, "required report field is missing")
        end
    end
end

local function array_length(value, field, code)
    if not is_plain_table(value) then
        fail(code, field, field .. " must be a plain dense array")
    end
    local count = 0
    local largest = 0
    for key in next, value do
        if type(key) ~= "number" or math.type(key) ~= "integer" or key < 1 then
            fail(code, field, field .. " must be a plain dense array")
        end
        count = count + 1
        if key > largest then
            largest = key
        end
    end
    if count ~= largest then
        fail(code, field, field .. " must be a plain dense array")
    end
    return count
end

local function is_sha256(value)
    return type(value) == "string"
        and #value == 64
        and value:match("^[0-9a-f]+$") ~= nil
end

local function validate_text(value, field, code, allow_empty)
    if type(value) ~= "string"
        or (not allow_empty and #value == 0)
        or value:find("[%z\1-\31\127]") ~= nil
        or not pcall(json_encode, value) then
        fail(code, field, field .. " must be a control-free UTF-8 string")
    end
    return value
end

local function secret_key(key)
    if type(key) ~= "string" then
        return false
    end
    local normalized = key:lower():gsub("[^a-z0-9]", "")
    for _, fragment in ipairs(SECRET_FRAGMENTS) do
        if normalized:find(fragment, 1, true) ~= nil then
            return true
        end
    end
    return false
end

local function reject_secret_keys(value, field, seen)
    if type(value) ~= "table" then
        return
    end
    if seen[value] then
        fail("CGCE-REPORT-TYPE", field, "cyclic report values are forbidden")
    end
    seen[value] = true
    for key, item in next, value do
        local child
        if type(key) == "string" then
            child = field == "context" and key or (field .. "." .. key)
            if secret_key(key) then
                fail("CGCE-REPORT-SECRET-KEY", child, "secret-bearing report keys are forbidden")
            end
        elseif type(key) == "number" and math.type(key) == "integer" then
            child = field .. "[" .. tostring(key) .. "]"
        else
            child = field .. "[invalid-key]"
        end
        reject_secret_keys(item, child, seen)
    end
    seen[value] = nil
end

local function copy_json(value, code, field)
    local encoded_ok, encoded = pcall(json_encode, value)
    if not encoded_ok then
        fail(code, field, field .. " is not canonical JSON data")
    end
    local decoded_ok, detached = pcall(json_decode, encoded)
    if not decoded_ok then
        fail(code, field, field .. " could not be detached")
    end
    return detached, encoded
end

local function unsigned_copy(value)
    local result = {}
    for key, item in next, value do
        if key ~= "checksum" then
            result[key] = item
        end
    end
    return result
end

local function validate_positive_integer(value, field, code)
    if type(value) ~= "number" or math.type(value) ~= "integer" or value < 1 then
        fail(code, field, field .. " must be a positive integer")
    end
    return value
end

local function validate_json_string(value, field, allow_empty)
    if type(value) ~= "string"
        or (not allow_empty and #value == 0)
        or not pcall(json_encode, value) then
        fail("CGCE-REPORT-AUDIT", field, "audit string is not valid UTF-8")
    end
    return value
end

local function validate_audit_exact_object(value, allowed, required, field)
    if not is_plain_table(value) then
        fail("CGCE-REPORT-AUDIT", field, "audit value must be a plain object")
    end
    local unknown = {}
    local invalid = false
    for key in next, value do
        if type(key) ~= "string" then
            invalid = true
        elseif not allowed[key] then
            unknown[#unknown + 1] = key
        end
    end
    table.sort(unknown)
    if unknown[1] ~= nil then
        fail("CGCE-REPORT-AUDIT", field .. "." .. unknown[1], "unknown embedded audit field")
    end
    if invalid then
        fail("CGCE-REPORT-AUDIT", field .. "[invalid-key]", "embedded audit object keys must be strings")
    end
    for _, name in ipairs(required) do
        if rawget(value, name) == nil then
            fail("CGCE-REPORT-AUDIT", field .. "." .. name, "required embedded audit field is missing")
        end
    end
end

local function validate_audit_error_array(value, field)
    local length = array_length(value, field, "CGCE-REPORT-AUDIT")
    local previous
    for index = 1, length do
        local item_field = field .. "[" .. tostring(index) .. "]"
        local item = rawget(value, index)
        validate_object(item, audit_error_fields, item_field, "CGCE-REPORT-AUDIT")
        validate_json_string(item.code, item_field .. ".code", false)
        validate_json_string(item.field, item_field .. ".field", false)
        validate_json_string(item.detail, item_field .. ".detail", false)
        local sort_key = item.code .. "\0" .. item.field .. "\0" .. item.detail
        if previous ~= nil and sort_key < previous then
            fail("CGCE-REPORT-AUDIT", field, "embedded audit findings must be sorted")
        end
        previous = sort_key
    end
    return length
end

local function validate_snapshot(value, field, container_id, owner_guild_id)
    validate_object(value, snapshot_fields, field, "CGCE-REPORT-AUDIT")
    if value.version ~= "1.0" then
        fail("CGCE-REPORT-AUDIT", field .. ".version", "unsupported embedded snapshot version")
    end
    if value.container_id ~= container_id then
        fail("CGCE-REPORT-AUDIT", field .. ".container_id", "snapshot container identity differs from guild")
    end
    if value.owner_guild_id ~= owner_guild_id then
        fail("CGCE-REPORT-AUDIT", field .. ".owner_guild_id", "snapshot owner identity differs from guild")
    end
    local slot_count = value.slot_count
    local occupied_count = value.occupied_slot_count
    local total_quantity = value.total_item_quantity
    if type(slot_count) ~= "number" or math.type(slot_count) ~= "integer" or slot_count < 0 then
        fail("CGCE-REPORT-AUDIT", field .. ".slot_count", "snapshot slot count is invalid")
    end
    if type(occupied_count) ~= "number"
        or math.type(occupied_count) ~= "integer"
        or occupied_count < 0
        or occupied_count > slot_count then
        fail("CGCE-REPORT-AUDIT", field .. ".occupied_slot_count", "snapshot occupied count is invalid")
    end
    if type(total_quantity) ~= "number" or math.type(total_quantity) ~= "integer" or total_quantity < 0 then
        fail("CGCE-REPORT-AUDIT", field .. ".total_item_quantity", "snapshot quantity is invalid")
    end
    if not is_sha256(value.item_fingerprint) then
        fail("CGCE-REPORT-AUDIT", field .. ".item_fingerprint", "snapshot fingerprint must be lowercase SHA-256")
    end
    if array_length(value.slots, field .. ".slots", "CGCE-REPORT-AUDIT") ~= slot_count then
        fail("CGCE-REPORT-AUDIT", field .. ".slots", "snapshot slots do not match slot count")
    end

    local occupied = json_array()
    local computed_quantity = 0
    for index = 1, slot_count do
        local slot_field = field .. ".slots[" .. tostring(index) .. "]"
        local slot = rawget(value.slots, index)
        if not is_plain_table(slot) then
            fail("CGCE-REPORT-AUDIT", slot_field, "snapshot slot must be a plain object")
        end
        local allowed = slot.empty == true and empty_slot_allowed or occupied_slot_allowed
        local required = slot.empty == true
            and { "index", "empty" }
            or {
                "index",
                "empty",
                "static_id",
                "dynamic_guid",
                "quantity",
                "durability",
                "instance_metadata_hash",
            }
        validate_audit_exact_object(slot, allowed, required, slot_field)
        if slot.index ~= index or type(slot.empty) ~= "boolean" then
            fail("CGCE-REPORT-AUDIT", slot_field, "snapshot slot index or occupancy is invalid")
        end
        if not slot.empty then
            validate_json_string(slot.static_id, slot_field .. ".static_id", false)
            validate_json_string(slot.dynamic_guid, slot_field .. ".dynamic_guid", false)
            validate_json_string(slot.durability, slot_field .. ".durability", false)
            if type(slot.quantity) ~= "number" or math.type(slot.quantity) ~= "integer" or slot.quantity < 1 then
                fail("CGCE-REPORT-AUDIT", slot_field .. ".quantity", "snapshot item quantity is invalid")
            end
            if not is_sha256(slot.instance_metadata_hash) then
                fail("CGCE-REPORT-AUDIT", slot_field .. ".instance_metadata_hash", "snapshot metadata hash must be lowercase SHA-256")
            end
            if slot.quantity > math.maxinteger - computed_quantity then
                fail("CGCE-REPORT-AUDIT", field .. ".total_item_quantity", "snapshot quantity overflows integer range")
            end
            computed_quantity = computed_quantity + slot.quantity
            occupied[#occupied + 1] = slot
        end
    end
    if #occupied ~= occupied_count or computed_quantity ~= total_quantity then
        fail("CGCE-REPORT-AUDIT", field, "snapshot aggregate counts do not match slots")
    end
    local fingerprint_ok, computed_fingerprint = pcall(fingerprint_compute, occupied)
    if not fingerprint_ok or computed_fingerprint ~= value.item_fingerprint then
        fail("CGCE-REPORT-AUDIT", field .. ".item_fingerprint", "snapshot fingerprint does not match occupied slots")
    end
end

local function validate_id_array(value, field)
    local length = array_length(value, field, "CGCE-REPORT-AUDIT")
    local previous
    for index = 1, length do
        local item = rawget(value, index)
        validate_json_string(item, field .. "[" .. tostring(index) .. "]", false)
        if previous ~= nil and item <= previous then
            fail("CGCE-REPORT-AUDIT", field, "embedded audit IDs must be unique and sorted")
        end
        previous = item
    end
end

local function audit_error_mirror_key(index, code, field, detail)
    return tostring(index) .. "\0" .. code .. "\0" .. field .. "\0" .. detail
end

local function validate_audit_error_mirrors(value)
    local expected = {}
    for index, guild in ipairs(value.guilds) do
        for _, item in ipairs(guild.errors) do
            local key = audit_error_mirror_key(index, item.code, item.field, item.detail)
            expected[key] = (expected[key] or 0) + 1
        end
    end

    local actual = {}
    for _, item in ipairs(value.blocking_errors) do
        local index_text, field = item.field:match("^guilds%[(%d+)%]%.(.+)$")
        if index_text ~= nil then
            local index = tonumber(index_text)
            if index == nil
                or math.type(index) ~= "integer"
                or index < 1
                or index > #value.guilds
                or tostring(index) ~= index_text then
                fail("CGCE-REPORT-AUDIT", "audit.blocking_errors", "embedded audit guild blocker index is invalid")
            end
            local key = audit_error_mirror_key(index, item.code, field, item.detail)
            actual[key] = (actual[key] or 0) + 1
        elseif item.field:match("^guilds%[") ~= nil then
            fail("CGCE-REPORT-AUDIT", "audit.blocking_errors", "embedded audit guild blocker field is invalid")
        end
    end

    for key, count in pairs(expected) do
        if actual[key] ~= count then
            fail("CGCE-REPORT-AUDIT", "audit.blocking_errors", "embedded audit guild errors and blockers differ")
        end
    end
    for key, count in pairs(actual) do
        if expected[key] ~= count then
            fail("CGCE-REPORT-AUDIT", "audit.blocking_errors", "embedded audit guild errors and blockers differ")
        end
    end
end

local function validate_audit_shape(value)
    validate_object(value, audit_fields, "audit", "CGCE-REPORT-AUDIT")
    if value.schema ~= "cgce.audit.v1" then
        fail("CGCE-REPORT-AUDIT", "audit.schema", "unsupported embedded audit schema")
    end
    validate_json_string(value.world_id, "audit.world_id", false)
    validate_positive_integer(value.game_revision, "audit.game_revision", "CGCE-REPORT-AUDIT")
    validate_json_string(value.deployment_profile, "audit.deployment_profile", false)
    validate_positive_integer(value.target_slots, "audit.target_slots", "CGCE-REPORT-AUDIT")
    validate_id_array(value.include_guild_ids, "audit.include_guild_ids")
    validate_id_array(value.exclude_guild_ids, "audit.exclude_guild_ids")
    validate_audit_error_array(value.blocking_errors, "audit.blocking_errors")

    local length = array_length(value.guilds, "audit.guilds", "CGCE-REPORT-AUDIT")
    local previous_guild
    for index = 1, length do
        local field = "audit.guilds[" .. tostring(index) .. "]"
        local guild = rawget(value.guilds, index)
        validate_audit_exact_object(
            guild,
            audit_guild_allowed,
            { "guild_id", "guild_name", "status", "eligible_action", "errors" },
            field
        )
        validate_json_string(guild.guild_id, field .. ".guild_id", false)
        validate_json_string(guild.guild_name, field .. ".guild_name", true)
        if previous_guild ~= nil and guild.guild_id <= previous_guild then
            fail("CGCE-REPORT-AUDIT", "audit.guilds", "embedded audit guilds must be unique and sorted")
        end
        previous_guild = guild.guild_id
        validate_audit_error_array(guild.errors, field .. ".errors")
        local chest = rawget(guild, "chest_container_id")
        local snapshot = rawget(guild, "snapshot")
        if chest ~= nil then
            validate_json_string(chest, field .. ".chest_container_id", false)
        end
        if snapshot ~= nil then
            if chest == nil then
                fail("CGCE-REPORT-AUDIT", field .. ".snapshot", "snapshot requires a configured container")
            end
            validate_snapshot(snapshot, field .. ".snapshot", chest, guild.guild_id)
        end

        if guild.status == "not_initialized" then
            if guild.eligible_action ~= "none" or chest ~= nil or snapshot ~= nil or #guild.errors ~= 0 then
                fail("CGCE-REPORT-AUDIT", field .. ".status", "not_initialized guild shape is inconsistent")
            end
        elseif guild.status == "blocked" then
            if guild.eligible_action ~= "none" then
                fail("CGCE-REPORT-AUDIT", field .. ".eligible_action", "blocked guild cannot be eligible")
            end
        elseif guild.status == "excluded_by_filter" then
            if guild.eligible_action ~= "none" or snapshot == nil then
                fail("CGCE-REPORT-AUDIT", field .. ".status", "excluded guild shape is inconsistent")
            end
        elseif guild.status == "eligible_expand" then
            if guild.eligible_action ~= "expand" or snapshot == nil or snapshot.slot_count >= value.target_slots then
                fail("CGCE-REPORT-AUDIT", field .. ".status", "expand-eligible guild shape is inconsistent")
            end
        elseif guild.status == "eligible_noop" then
            if guild.eligible_action ~= "noop" or snapshot == nil or snapshot.slot_count < value.target_slots then
                fail("CGCE-REPORT-AUDIT", field .. ".status", "no-op guild shape is inconsistent")
            end
        else
            fail("CGCE-REPORT-AUDIT", field .. ".status", "embedded audit guild status is invalid")
        end
    end
    validate_audit_error_mirrors(value)
end

local function validate_embedded_audit(value, expected_checksum)
    if not is_plain_table(value) or not is_sha256(expected_checksum) then
        fail("CGCE-REPORT-AUDIT", "audit", "embedded audit is malformed")
    end
    local detached = copy_json(value, "CGCE-REPORT-AUDIT", "audit")
    if detached.checksum ~= expected_checksum
        or sha256_hex(json_encode(unsigned_copy(detached))) ~= expected_checksum then
        fail("CGCE-REPORT-AUDIT", "audit", "embedded audit checksum does not match")
    end
    validate_audit_shape(detached)
    return detached
end

local function trusted_audit(handle)
    local table_ok, detached = pcall(audit_to_table, handle)
    local checksum_ok, checksum = pcall(audit_checksum, handle)
    local canonical_ok, canonical = pcall(audit_canonical_json, handle)
    if not table_ok or not checksum_ok or not canonical_ok or not is_sha256(checksum) then
        fail("CGCE-REPORT-AUDIT", "audit", "audit must be a trusted Task 5 capture")
    end
    local copied, encoded = copy_json(detached, "CGCE-REPORT-AUDIT", "audit")
    if encoded ~= canonical then
        fail("CGCE-REPORT-AUDIT", "audit", "trusted audit canonical bytes do not match")
    end
    copied = validate_embedded_audit(copied, checksum)
    reject_secret_keys(copied, "audit", {})
    return copied, checksum
end

local function project_platform(value)
    validate_object(value, preflight_fields, "platform_preflight", "CGCE-REPORT-PREFLIGHT")
    if type(value.preflight_ok) ~= "boolean" then
        fail("CGCE-REPORT-PREFLIGHT", "platform_preflight.preflight_ok", "preflight_ok must be boolean")
    end
    if not PREFLIGHT_STATES[value.state] then
        fail("CGCE-REPORT-PREFLIGHT", "platform_preflight.state", "preflight state is invalid")
    end
    local expected_state = value.preflight_ok
        and "CONNECTIVITY_PREFLIGHT_OK"
        or "PS5_CONNECTIVITY_MISCONFIGURED"
    if value.state ~= expected_state then
        fail("CGCE-REPORT-PREFLIGHT", "platform_preflight.state", "preflight state does not match preflight_ok")
    end
    if value.certification ~= "UNPROVEN" then
        fail("CGCE-REPORT-PREFLIGHT", "platform_preflight.certification", "discovery certification must remain UNPROVEN")
    end
    if value.diagnostic_only ~= true then
        fail("CGCE-REPORT-PREFLIGHT", "platform_preflight.diagnostic_only", "platform preflight must remain diagnostic-only")
    end

    local evidence = value.evidence
    if not is_plain_table(evidence) then
        fail("CGCE-REPORT-PREFLIGHT", "platform_preflight.evidence", "preflight evidence must be a plain object")
    end
    local unknown = {}
    local invalid = false
    for key in next, evidence do
        if type(key) ~= "string" then
            invalid = true
        elseif not evidence_fields[key] then
            unknown[#unknown + 1] = key
        end
    end
    table.sort(unknown)
    if unknown[1] then
        fail("CGCE-REPORT-PREFLIGHT", "platform_preflight.evidence." .. unknown[1], "unknown preflight evidence field")
    end
    if invalid then
        fail("CGCE-REPORT-PREFLIGHT", "platform_preflight.evidence[invalid-key]", "preflight evidence keys must be strings")
    end

    if type(evidence.public_lobby) ~= "boolean" then
        fail("CGCE-REPORT-PREFLIGHT", "platform_preflight.evidence.public_lobby", "public_lobby must be boolean")
    end
    if type(evidence.xbox) ~= "boolean" then
        fail("CGCE-REPORT-PREFLIGHT", "platform_preflight.evidence.xbox", "xbox must be boolean")
    end
    local required = evidence.required_platforms
    if not is_plain_table(required) then
        fail("CGCE-REPORT-PREFLIGHT", "platform_preflight.evidence.required_platforms", "required platforms must be a plain object")
    end
    local unknown_platforms = {}
    local invalid_platform_key = false
    for key in next, required do
        if type(key) ~= "string" then
            invalid_platform_key = true
        elseif key ~= "Steam" and key ~= "PS5" and key ~= "Mac" then
            unknown_platforms[#unknown_platforms + 1] = key
        end
    end
    table.sort(unknown_platforms)
    if unknown_platforms[1] ~= nil then
        fail(
            "CGCE-REPORT-PREFLIGHT",
            "platform_preflight.evidence.required_platforms." .. unknown_platforms[1],
            "only Tier 0 platform keys are allowed"
        )
    end
    if invalid_platform_key then
        fail(
            "CGCE-REPORT-PREFLIGHT",
            "platform_preflight.evidence.required_platforms[invalid-key]",
            "Tier 0 platform keys must be strings"
        )
    end
    for _, name in ipairs({ "Steam", "PS5", "Mac" }) do
        if type(rawget(required, name)) ~= "boolean" then
            fail("CGCE-REPORT-PREFLIGHT", "platform_preflight.evidence.required_platforms." .. name, "Tier 0 platform evidence must be boolean")
        end
    end

    local projected_evidence = {
        public_lobby = evidence.public_lobby,
        required_platforms = {
            Steam = required.Steam,
            PS5 = required.PS5,
            Mac = required.Mac,
        },
        xbox = evidence.xbox,
    }
    for _, name in ipairs({ "game_port", "public_port", "ini_public_port" }) do
        local port = rawget(evidence, name)
        if port ~= nil then
            if type(port) ~= "number" or math.type(port) ~= "integer" or port < 1 or port > 65535 then
                fail("CGCE-REPORT-PREFLIGHT", "platform_preflight.evidence." .. name, name .. " must be a valid port")
            end
            projected_evidence[name] = port
        end
    end
    if rawget(evidence, "client_mod_allowed") ~= nil then
        if type(evidence.client_mod_allowed) ~= "boolean" then
            fail("CGCE-REPORT-PREFLIGHT", "platform_preflight.evidence.client_mod_allowed", "client_mod_allowed must be boolean")
        end
        projected_evidence.client_mod_allowed = evidence.client_mod_allowed
    end
    if rawget(evidence, "log_format") ~= nil then
        projected_evidence.log_format = validate_text(
            evidence.log_format,
            "platform_preflight.evidence.log_format",
            "CGCE-REPORT-PREFLIGHT",
            false
        )
    end

    if value.preflight_ok then
        if projected_evidence.public_lobby ~= true then
            fail("CGCE-REPORT-PREFLIGHT", "platform_preflight.evidence.public_lobby", "green preflight requires public lobby")
        end
        for _, name in ipairs({ "Steam", "PS5", "Mac" }) do
            if projected_evidence.required_platforms[name] ~= true then
                fail(
                    "CGCE-REPORT-PREFLIGHT",
                    "platform_preflight.evidence.required_platforms." .. name,
                    "green preflight requires every Tier 0 platform"
                )
            end
        end
        for _, name in ipairs({ "game_port", "public_port", "ini_public_port" }) do
            if projected_evidence[name] == nil then
                fail(
                    "CGCE-REPORT-PREFLIGHT",
                    "platform_preflight.evidence." .. name,
                    "green preflight requires every exact port"
                )
            end
        end
        if projected_evidence.game_port ~= projected_evidence.public_port
            or projected_evidence.game_port ~= projected_evidence.ini_public_port then
            fail("CGCE-REPORT-PREFLIGHT", "platform_preflight.evidence.public_port", "green preflight ports must match")
        end
        if projected_evidence.client_mod_allowed ~= false then
            fail("CGCE-REPORT-PREFLIGHT", "platform_preflight.evidence.client_mod_allowed", "green preflight requires client mods disabled")
        end
        if projected_evidence.log_format ~= "Json" then
            fail("CGCE-REPORT-PREFLIGHT", "platform_preflight.evidence.log_format", "green preflight requires JSON logging")
        end
    end

    return {
        preflight_ok = value.preflight_ok,
        state = value.state,
        certification = "UNPROVEN",
        diagnostic_only = true,
        evidence = projected_evidence,
    }
end

local function project_conflict(value)
    validate_object(value, conflict_fields, "conflict_summary", "CGCE-REPORT-CONFLICT")
    if value.coverage ~= "partial" and value.coverage ~= "complete" then
        fail("CGCE-REPORT-CONFLICT", "conflict_summary.coverage", "conflict coverage must be partial or complete")
    end
    for _, field in ipairs({ "blocking", "forced_noop" }) do
        if type(value[field]) ~= "boolean" then
            fail("CGCE-REPORT-CONFLICT", "conflict_summary." .. field, field .. " must be boolean")
        end
    end
    return {
        coverage = value.coverage,
        blocking = value.blocking,
        forced_noop = value.forced_noop,
    }
end

local function project_mod_inventory(value)
    local length = array_length(value, "mod_inventory", "CGCE-REPORT-MOD-INVENTORY")
    local result = json_array()
    for index = 1, length do
        local field = "mod_inventory[" .. tostring(index) .. "]"
        local item = rawget(value, index)
        validate_object(item, mod_fields, field, "CGCE-REPORT-MOD-INVENTORY")
        result[index] = {
            package_name = validate_text(item.package_name, field .. ".package_name", "CGCE-REPORT-MOD-INVENTORY", false),
            package_version = validate_text(item.package_version, field .. ".package_version", "CGCE-REPORT-MOD-INVENTORY", false),
        }
    end
    table.sort(result, function(left, right)
        if left.package_name ~= right.package_name then
            return left.package_name < right.package_name
        end
        return left.package_version < right.package_version
    end)
    return result
end

local function project_findings(value)
    local length = array_length(value, "findings", "CGCE-REPORT-FINDING")
    local result = json_array()
    for index = 1, length do
        local field = "findings[" .. tostring(index) .. "]"
        local item = rawget(value, index)
        validate_object(item, finding_fields, field, "CGCE-REPORT-FINDING")
        if not SEVERITIES[item.severity] then
            fail("CGCE-REPORT-FINDING", field .. ".severity", "finding severity is invalid")
        end
        if type(item.forced_noop) ~= "boolean" then
            fail("CGCE-REPORT-FINDING", field .. ".forced_noop", "forced_noop must be explicit boolean")
        end
        result[index] = {
            code = validate_text(item.code, field .. ".code", "CGCE-REPORT-FINDING", false),
            severity = item.severity,
            field = validate_text(item.field, field .. ".field", "CGCE-REPORT-FINDING", false),
            detail = validate_text(item.detail, field .. ".detail", "CGCE-REPORT-FINDING", false),
            forced_noop = item.forced_noop,
        }
    end
    table.sort(result, function(left, right)
        if left.code ~= right.code then
            return left.code < right.code
        end
        if left.field ~= right.field then
            return left.field < right.field
        end
        if left.detail ~= right.detail then
            return left.detail < right.detail
        end
        if left.severity ~= right.severity then
            return left.severity < right.severity
        end
        return left.forced_noop == false and right.forced_noop == true
    end)
    return result
end

local function validate_conflict_consistency(summary, findings)
    local blocking = false
    local forced_noop = false
    for _, finding in ipairs(findings) do
        if finding.code:sub(1, 14) == "CGCE-CONFLICT-" then
            blocking = blocking
                or finding.severity == "BLOCKING"
                or finding.severity == "CRITICAL"
            forced_noop = forced_noop or finding.forced_noop
        end
    end
    if summary.blocking ~= blocking then
        fail("CGCE-REPORT-CONFLICT", "conflict_summary.blocking", "conflict summary does not match exact findings")
    end
    if summary.forced_noop ~= forced_noop then
        fail("CGCE-REPORT-CONFLICT", "conflict_summary.forced_noop", "conflict summary does not match exact findings")
    end
end

local function validate_terminal_consistency(mode, state, audit_value, platform, conflict, findings)
    if mode == "audit" and state == "AWAITING_APPROVAL" then
        fail("CGCE-REPORT-STATE", "state", "audit mode cannot await operator approval")
    end

    local unified_blocking = false
    for _, finding in ipairs(findings) do
        unified_blocking = unified_blocking
            or finding.severity == "BLOCKING"
            or finding.severity == "CRITICAL"
    end
    local explicit_blocker = #audit_value.blocking_errors > 0
        or conflict.blocking
        or unified_blocking
    local must_block = explicit_blocker
        or (mode == "apply" and not platform.preflight_ok)
        or (mode == "apply" and conflict.coverage == "partial")
    if must_block and state ~= "BLOCKED" then
        fail("CGCE-REPORT-STATE", "state", "blocking evidence requires BLOCKED state")
    end
    if state == "BLOCKED" and not explicit_blocker then
        fail("CGCE-REPORT-STATE", "state", "BLOCKED state requires explicit blocking evidence")
    end
end

local function finalize(unsigned)
    local checksum = sha256_hex(json_encode(unsigned))
    unsigned.checksum = checksum
    local built = json_decode(json_encode(unsigned))
    built_reports[built] = json_encode(built)
    return built
end

function report.build(context)
    if not is_plain_table(context) then
        fail("CGCE-REPORT-CONTEXT", "context", "report context must be a plain object")
    end
    reject_secret_keys(context, "context", {})
    validate_object(context, context_fields, "context", "CGCE-REPORT-CONTEXT")

    if not MODES[context.mode] then
        fail("CGCE-REPORT-MODE", "mode", "report mode must be audit or apply")
    end
    if not TERMINAL_STATES[context.state] then
        fail("CGCE-REPORT-STATE", "state", "report state must be a post-audit discovery terminal")
    end
    local mod_version = validate_text(context.mod_version, "mod_version", "CGCE-REPORT-CONTEXT", false)
    if not is_sha256(context.binding_manifest_checksum) then
        fail("CGCE-REPORT-BINDING", "binding_manifest_checksum", "binding manifest checksum must be lowercase SHA-256")
    end

    local detached_audit, checksum = trusted_audit(context.audit)
    local platform = project_platform(context.platform_preflight)
    local conflict = project_conflict(context.conflict_summary)
    local inventory = project_mod_inventory(context.mod_inventory)
    local findings = project_findings(context.findings)
    validate_conflict_consistency(conflict, findings)
    validate_terminal_consistency(context.mode, context.state, detached_audit, platform, conflict, findings)
    local unsigned = {
        schema = REPORT_SCHEMA,
        report_kind = "operational",
        build_kind = "discovery",
        release_eligible = false,
        mode = context.mode,
        state = context.state,
        mod_version = mod_version,
        world_id = detached_audit.world_id,
        game_revision = detached_audit.game_revision,
        deployment_profile = detached_audit.deployment_profile,
        target_slots = detached_audit.target_slots,
        binding_manifest_checksum = context.binding_manifest_checksum,
        audit_checksum = checksum,
        audit = detached_audit,
        platform_preflight = platform,
        conflict_summary = conflict,
        mod_inventory = inventory,
        findings = findings,
    }
    reject_secret_keys(unsigned, "report", {})
    return finalize(unsigned)
end

local function validate_report(value)
    if not is_plain_table(value) then
        fail("CGCE-REPORT-TYPE", "report", "report must be a plain object")
    end
    reject_secret_keys(value, "report", {})
    validate_object(value, report_fields, "report", "CGCE-REPORT-TYPE")
    if value.schema ~= REPORT_SCHEMA
        or value.report_kind ~= "operational"
        or value.build_kind ~= "discovery"
        or value.release_eligible ~= false then
        fail("CGCE-REPORT-KIND", "report_kind", "artifact is not a discovery operational report")
    end
    if not MODES[value.mode] then
        fail("CGCE-REPORT-MODE", "mode", "report mode must be audit or apply")
    end
    if not TERMINAL_STATES[value.state] then
        fail("CGCE-REPORT-STATE", "state", "report state must be a post-audit discovery terminal")
    end
    validate_text(value.mod_version, "mod_version", "CGCE-REPORT-TYPE", false)
    validate_text(value.world_id, "world_id", "CGCE-REPORT-TYPE", false)
    validate_positive_integer(value.game_revision, "game_revision", "CGCE-REPORT-TYPE")
    validate_text(value.deployment_profile, "deployment_profile", "CGCE-REPORT-TYPE", false)
    validate_positive_integer(value.target_slots, "target_slots", "CGCE-REPORT-TYPE")
    if not is_sha256(value.binding_manifest_checksum) then
        fail("CGCE-REPORT-BINDING", "binding_manifest_checksum", "binding manifest checksum must be lowercase SHA-256")
    end
    if not is_sha256(value.audit_checksum) then
        fail("CGCE-REPORT-AUDIT", "audit_checksum", "audit checksum must be lowercase SHA-256")
    end
    if not is_sha256(value.checksum) then
        fail("CGCE-REPORT-CHECKSUM", "checksum", "report checksum must be lowercase SHA-256")
    end

    local detached_audit = validate_embedded_audit(value.audit, value.audit_checksum)
    if detached_audit.world_id ~= value.world_id
        or detached_audit.game_revision ~= value.game_revision
        or detached_audit.deployment_profile ~= value.deployment_profile
        or detached_audit.target_slots ~= value.target_slots then
        fail("CGCE-REPORT-AUDIT", "audit", "report identity does not match embedded audit")
    end

    local platform = project_platform(value.platform_preflight)
    local conflict = project_conflict(value.conflict_summary)
    local inventory = project_mod_inventory(value.mod_inventory)
    local findings = project_findings(value.findings)
    validate_conflict_consistency(conflict, findings)
    validate_terminal_consistency(value.mode, value.state, detached_audit, platform, conflict, findings)
    local normalized = {
        schema = REPORT_SCHEMA,
        report_kind = "operational",
        build_kind = "discovery",
        release_eligible = false,
        mode = value.mode,
        state = value.state,
        mod_version = value.mod_version,
        world_id = value.world_id,
        game_revision = value.game_revision,
        deployment_profile = value.deployment_profile,
        target_slots = value.target_slots,
        binding_manifest_checksum = value.binding_manifest_checksum,
        audit_checksum = value.audit_checksum,
        audit = detached_audit,
        platform_preflight = platform,
        conflict_summary = conflict,
        mod_inventory = inventory,
        findings = findings,
    }
    if sha256_hex(json_encode(normalized)) ~= value.checksum then
        fail("CGCE-REPORT-CHECKSUM", "checksum", "operational report self-checksum mismatch")
    end
    normalized.checksum = value.checksum
    local canonical = json_encode(normalized)
    local supplied = json_encode(value)
    if canonical ~= supplied then
        fail("CGCE-REPORT-CHECKSUM", "checksum", "operational report is not canonical")
    end
    return json_decode(canonical)
end

function report.validate(value)
    return validate_report(value)
end

local function capture_fs_ports(fs)
    if not is_plain_table(fs) then
        fail("CGCE-REPORT-PERSIST", "fs", "filesystem port must be a plain object")
    end
    local names = {
        "capabilities",
        "canonicalize",
        "inspect_no_follow",
        "propose_temp_sibling",
        "create_exclusive",
        "write_all",
        "flush_file",
        "close_file",
        "atomic_replace",
        "flush_directory",
        "read_all_no_follow",
    }
    local ports = {}
    for _, name in ipairs(names) do
        local port = rawget(fs, name)
        if type(port) ~= "function" then
            fail("CGCE-REPORT-PERSIST", name, "required filesystem operation is unavailable")
        end
        ports[name] = port
    end
    return ports
end

local function call_true(port, name, ...)
    local ok, value, secondary = pcall(port, ...)
    if not ok or value ~= true or secondary ~= nil then
        return false
    end
    return true
end

function report.persist(fs, root, relative_path, value)
    local registered = built_reports[value]
    local encoded_ok, supplied_bytes = pcall(json_encode, value)
    if registered == nil or not encoded_ok or supplied_bytes ~= registered then
        fail("CGCE-REPORT-PROVENANCE", "report", "only an unchanged report.build result may be persisted")
    end
    local validated = validate_report(value)
    local bytes = json_encode(validated)
    local ports = capture_fs_ports(fs)
    local guard_fs = {
        capabilities = ports.capabilities,
        canonicalize = ports.canonicalize,
        inspect_no_follow = ports.inspect_no_follow,
        propose_temp_sibling = ports.propose_temp_sibling,
    }
    local resolved_ok, resolved = pcall(path_resolve, guard_fs, root, relative_path)
    if not resolved_ok then
        if type(resolved) == "table"
            and type(resolved.code) == "string"
            and type(resolved.detail) == "string" then
            error(resolved, 0)
        end
        fail("CGCE-REPORT-PERSIST", "path_guard", "safe report path resolution failed")
    end

    local created_ok, handle, secondary = pcall(ports.create_exclusive, resolved.temp_sibling)
    local handle_type = type(handle)
    local opaque_handle = handle_type == "function"
        or handle_type == "userdata"
        or handle_type == "thread"
    if created_ok and handle ~= nil and (secondary ~= nil or not opaque_handle) then
        pcall(ports.close_file, handle)
    end
    if not created_ok
        or secondary ~= nil
        or not opaque_handle then
        fail("CGCE-REPORT-PERSIST", "create_exclusive", "exclusive temporary report creation failed")
    end

    local closed = false
    local function close_once()
        if closed then
            return true
        end
        closed = true
        return call_true(ports.close_file, "close_file", handle)
    end
    local function fail_after_create(code, field, detail)
        close_once()
        fail(code, field, detail)
    end

    if not call_true(ports.write_all, "write_all", handle, bytes) then
        fail_after_create("CGCE-REPORT-PERSIST", "write_all", "temporary report write failed")
    end
    if not call_true(ports.flush_file, "flush_file", handle) then
        fail_after_create("CGCE-REPORT-PERSIST", "flush_file", "temporary report durable flush failed")
    end
    if not close_once() then
        fail("CGCE-REPORT-PERSIST", "close_file", "temporary report close failed")
    end
    if not call_true(ports.atomic_replace, "atomic_replace", resolved.temp_sibling, resolved.target) then
        fail("CGCE-REPORT-PERSIST", "atomic_replace", "atomic report replace failed")
    end
    if not call_true(ports.flush_directory, "flush_directory", resolved.parent) then
        fail("CGCE-REPORT-PERSIST", "flush_directory", "report directory durability barrier failed")
    end

    local read_ok, read_bytes, read_error = pcall(ports.read_all_no_follow, resolved.target)
    if not read_ok or read_error ~= nil or type(read_bytes) ~= "string" then
        fail("CGCE-REPORT-READBACK", "read_all_no_follow", "persisted report could not be read back safely")
    end
    if read_bytes ~= bytes then
        fail("CGCE-REPORT-READBACK", "read_all_no_follow", "persisted report bytes do not match canonical bytes")
    end

    return {
        path = resolved.target,
        relative_path = resolved.relative_path,
        report_checksum = validated.checksum,
        audit_checksum = validated.audit_checksum,
        byte_length = #bytes,
        durable = true,
        read_back_verified = true,
    }
end

return report
