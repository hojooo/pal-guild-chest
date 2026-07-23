local fingerprint = require("CrossplayGuildChestExpander.Scripts.fingerprint")
local json = require("CrossplayGuildChestExpander.Scripts.json")
local sha256 = require("CrossplayGuildChestExpander.Scripts.sha256")

local audit = {}
local fingerprint_compute = fingerprint.compute
local json_array = json.array
local json_decode = json.decode
local json_encode = json.encode
local sha256_hex = sha256.hex

local captured = setmetatable({}, { __mode = "k" })

local context_keys = {
    world_id = true,
    game_revision = true,
    deployment_profile = true,
    target_slots = true,
    include_guild_ids = true,
    exclude_guild_ids = true,
    list_guilds = true,
    resolve_guild_chest = true,
    snapshot_container = true,
}

local guild_keys = {
    guild_id = true,
    guild_name = true,
    chest_container_id = true,
}

local resolved_keys = {
    container_id = true,
    owner_guild_id = true,
    is_guild_chest = true,
    container = true,
}

local snapshot_keys = {
    version = true,
    container_id = true,
    owner_guild_id = true,
    slot_count = true,
    occupied_slot_count = true,
    total_item_quantity = true,
    slots = true,
    item_fingerprint = true,
}

local empty_slot_keys = {
    index = true,
    empty = true,
}

local occupied_slot_keys = {
    index = true,
    empty = true,
    static_id = true,
    dynamic_guid = true,
    quantity = true,
    durability = true,
    instance_metadata_hash = true,
}

local function error_record(code, field, detail)
    return {
        code = code,
        field = field,
        detail = detail,
    }
end

local function fail(code, field, detail)
    error(error_record(code, field, detail), 0)
end

local function is_json_string(value, allow_empty)
    if type(value) ~= "string" or (not allow_empty and #value == 0) then
        return false
    end
    return pcall(json_encode, value)
end

local function is_integer(value, minimum)
    return type(value) == "number"
        and math.type(value) == "integer"
        and value >= minimum
end

local function table_has_only(value, allowed)
    if type(value) ~= "table" then
        return false
    end
    for key in next, value do
        if type(key) ~= "string" or not allowed[key] then
            return false
        end
    end
    return true
end

local function dense_length(value)
    if type(value) ~= "table" then
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

local function unknown_context_field(value, allowed)
    local unknown_strings = {}
    local has_non_string = false
    for key in next, value do
        if type(key) ~= "string" then
            has_non_string = true
        elseif not allowed[key] then
            unknown_strings[#unknown_strings + 1] = key
        end
    end
    if has_non_string then
        return "context"
    end
    table.sort(unknown_strings)
    return unknown_strings[1]
end

local function validate_filter(context, field)
    local source = rawget(context, field)
    local length = dense_length(source)
    if length == nil then
        fail("CGCE-AUD-CONTEXT", field, "guild filter must be a dense array")
    end

    local seen = {}
    local result = json_array()
    for index = 1, length do
        local guild_id = rawget(source, index)
        if not is_json_string(guild_id, false) or seen[guild_id] then
            fail("CGCE-AUD-CONTEXT", field, "guild filter must contain unique opaque IDs")
        end
        seen[guild_id] = true
        result[index] = guild_id
    end
    table.sort(result)
    return result, seen
end

local function validate_context(context)
    if type(context) ~= "table" then
        fail("CGCE-AUD-CONTEXT", "context", "audit context must be a table")
    end
    local unknown = unknown_context_field(context, context_keys)
    if unknown ~= nil then
        fail("CGCE-AUD-CONTEXT", unknown, "unknown audit context field")
    end

    local world_id = rawget(context, "world_id")
    if not is_json_string(world_id, false) then
        fail("CGCE-AUD-CONTEXT", "world_id", "world_id must be a non-empty opaque string")
    end
    local game_revision = rawget(context, "game_revision")
    if not is_integer(game_revision, 1) then
        fail("CGCE-AUD-CONTEXT", "game_revision", "game_revision must be a positive integer")
    end
    local deployment_profile = rawget(context, "deployment_profile")
    if not is_json_string(deployment_profile, false) then
        fail(
            "CGCE-AUD-CONTEXT",
            "deployment_profile",
            "deployment_profile must be a non-empty string"
        )
    end
    local target_slots = rawget(context, "target_slots")
    if not is_integer(target_slots, 1) then
        fail("CGCE-AUD-CONTEXT", "target_slots", "target_slots must be a positive integer")
    end

    local include_ids, include_set = validate_filter(context, "include_guild_ids")
    local exclude_ids, exclude_set = validate_filter(context, "exclude_guild_ids")

    local ports = {}
    for _, field in ipairs({ "list_guilds", "resolve_guild_chest", "snapshot_container" }) do
        local port = rawget(context, field)
        if type(port) ~= "function" then
            fail("CGCE-AUD-CONTEXT", field, "required read-only port is unavailable")
        end
        ports[field] = port
    end

    return {
        world_id = world_id,
        game_revision = game_revision,
        deployment_profile = deployment_profile,
        target_slots = target_slots,
        include_guild_ids = include_ids,
        exclude_guild_ids = exclude_ids,
        include_set = include_set,
        exclude_set = exclude_set,
        ports = ports,
    }
end

local function project_guilds(value)
    local length = dense_length(value)
    if length == nil then
        return nil
    end

    local projected = {}
    local seen = {}
    for index = 1, length do
        local source = rawget(value, index)
        if not table_has_only(source, guild_keys) then
            return nil
        end

        local guild_id = rawget(source, "guild_id")
        local guild_name = rawget(source, "guild_name")
        local chest_container_id = rawget(source, "chest_container_id")
        if not is_json_string(guild_id, false)
            or seen[guild_id]
            or not is_json_string(guild_name, true)
            or (chest_container_id ~= nil and not is_json_string(chest_container_id, false)) then
            return nil
        end

        seen[guild_id] = true
        projected[index] = {
            guild_id = guild_id,
            guild_name = guild_name,
            chest_container_id = chest_container_id,
        }
    end

    table.sort(projected, function(left, right)
        return left.guild_id < right.guild_id
    end)
    return projected
end

local function project_resolution(value, configured_id)
    if not table_has_only(value, resolved_keys) then
        return nil
    end
    local container_id = rawget(value, "container_id")
    local owner_guild_id = rawget(value, "owner_guild_id")
    local is_guild_chest = rawget(value, "is_guild_chest")
    local container = rawget(value, "container")
    local container_type = type(container)

    if not is_json_string(container_id, false)
        or container_id ~= configured_id
        or not is_json_string(owner_guild_id, false)
        or type(is_guild_chest) ~= "boolean"
        or (container_type ~= "table"
            and container_type ~= "userdata"
            and container_type ~= "function") then
        return nil
    end

    return {
        container_id = container_id,
        owner_guild_id = owner_guild_id,
        is_guild_chest = is_guild_chest,
        container = container,
    }
end

local function project_snapshot_slot(source, index)
    if type(source) ~= "table" or rawget(source, "index") ~= index then
        return nil
    end
    local empty = rawget(source, "empty")
    if empty == true then
        if not table_has_only(source, empty_slot_keys) then
            return nil
        end
        return { index = index, empty = true }, nil
    end
    if empty ~= false or not table_has_only(source, occupied_slot_keys) then
        return nil
    end

    local static_id = rawget(source, "static_id")
    local dynamic_guid = rawget(source, "dynamic_guid")
    local quantity = rawget(source, "quantity")
    local durability = rawget(source, "durability")
    local metadata_hash = rawget(source, "instance_metadata_hash")
    if not is_json_string(static_id, false)
        or not is_json_string(dynamic_guid, false)
        or not is_integer(quantity, 1)
        or not is_json_string(durability, false)
        or type(metadata_hash) ~= "string"
        or #metadata_hash ~= 64
        or not metadata_hash:match("^[0-9a-f]+$") then
        return nil
    end

    return {
        index = index,
        empty = false,
        static_id = static_id,
        dynamic_guid = dynamic_guid,
        quantity = quantity,
        durability = durability,
        instance_metadata_hash = metadata_hash,
    }, quantity
end

local function project_snapshot(value, expected_container_id, expected_owner_guild_id)
    if not table_has_only(value, snapshot_keys)
        or rawget(value, "version") ~= "1.0"
        or rawget(value, "container_id") ~= expected_container_id
        or rawget(value, "owner_guild_id") ~= expected_owner_guild_id then
        return nil
    end

    local slot_count = rawget(value, "slot_count")
    local occupied_count = rawget(value, "occupied_slot_count")
    local total_quantity = rawget(value, "total_item_quantity")
    local source_slots = rawget(value, "slots")
    local item_fingerprint = rawget(value, "item_fingerprint")
    if not is_integer(slot_count, 0)
        or not is_integer(occupied_count, 0)
        or occupied_count > slot_count
        or not is_integer(total_quantity, 0)
        or dense_length(source_slots) ~= slot_count
        or type(item_fingerprint) ~= "string"
        or #item_fingerprint ~= 64
        or not item_fingerprint:match("^[0-9a-f]+$") then
        return nil
    end

    local projected_slots = json_array()
    local occupied_records = json_array()
    local computed_quantity = 0
    for index = 1, slot_count do
        local record, quantity = project_snapshot_slot(rawget(source_slots, index), index)
        if record == nil then
            return nil
        end
        projected_slots[index] = record
        if quantity ~= nil then
            if quantity > math.maxinteger - computed_quantity then
                return nil
            end
            computed_quantity = computed_quantity + quantity
            occupied_records[#occupied_records + 1] = record
        end
    end

    local ok, computed_fingerprint = pcall(fingerprint_compute, occupied_records)
    if not ok
        or #occupied_records ~= occupied_count
        or computed_quantity ~= total_quantity
        or computed_fingerprint ~= item_fingerprint then
        return nil
    end

    return {
        version = "1.0",
        container_id = expected_container_id,
        owner_guild_id = expected_owner_guild_id,
        slot_count = slot_count,
        occupied_slot_count = occupied_count,
        total_item_quantity = total_quantity,
        slots = projected_slots,
        item_fingerprint = item_fingerprint,
    }
end

local function sort_errors(errors)
    table.sort(errors, function(left, right)
        if left.code ~= right.code then
            return left.code < right.code
        end
        if left.field ~= right.field then
            return left.field < right.field
        end
        return left.detail < right.detail
    end)
end

local function add_guild_error(record, blocking_errors, index, code, field, detail)
    record.errors[#record.errors + 1] = error_record(code, field, detail)
    blocking_errors[#blocking_errors + 1] = error_record(
        code,
        "guilds[" .. index .. "]." .. field,
        detail
    )
end

local function finalize(unsigned)
    local ok, unsigned_json = pcall(json_encode, unsigned)
    if not ok then
        fail("CGCE-AUD-CHECKSUM", "audit", "canonical audit encoding failed")
    end
    local checksum_ok, checksum = pcall(sha256_hex, unsigned_json)
    if not checksum_ok then
        fail("CGCE-AUD-CHECKSUM", "audit", "canonical audit checksum failed")
    end

    unsigned.checksum = checksum
    local signed_ok, canonical = pcall(json_encode, unsigned)
    if not signed_ok then
        fail("CGCE-AUD-CHECKSUM", "audit", "canonical audit encoding failed")
    end

    local handle = function() end
    captured[handle] = {
        canonical = canonical,
        checksum = checksum,
    }
    return handle
end

function audit.capture(context)
    local input = validate_context(context)
    local blocking_errors = json_array()
    local has_filter_overlap = false
    for guild_id in pairs(input.include_set) do
        if input.exclude_set[guild_id] then
            has_filter_overlap = true
            break
        end
    end
    if has_filter_overlap then
        blocking_errors[#blocking_errors + 1] = error_record(
            "CGCE-AUD-FILTER-OVERLAP",
            "filters",
            "include and exclude guild filters overlap"
        )
    end

    local listed_ok, listed = pcall(input.ports.list_guilds)
    local guilds = listed_ok and project_guilds(listed) or nil
    if guilds == nil then
        blocking_errors[#blocking_errors + 1] = error_record(
            "CGCE-AUD-GUILD-PROJECTION",
            "guilds",
            "read-only guild projection failed"
        )
        guilds = {}
    end

    local container_counts = {}
    for _, value in ipairs(guilds) do
        if value.chest_container_id ~= nil then
            container_counts[value.chest_container_id] =
                (container_counts[value.chest_container_id] or 0) + 1
        end
    end

    local records = json_array()
    for index, value in ipairs(guilds) do
        local record = {
            guild_id = value.guild_id,
            guild_name = value.guild_name,
            status = "not_initialized",
            eligible_action = "none",
            errors = json_array(),
        }
        if value.chest_container_id ~= nil then
            record.chest_container_id = value.chest_container_id
        end
        records[index] = record

        if value.chest_container_id == nil then
            -- A new guild may legitimately not have initialized its chest yet.
        elseif container_counts[value.chest_container_id] > 1 then
            record.status = "blocked"
            add_guild_error(
                record,
                blocking_errors,
                index,
                "CGCE-AUD-DUPLICATE-CONTAINER",
                "chest_container_id",
                "configured container ID is referenced by multiple guilds"
            )
        else
            local resolved_ok, resolved_value = pcall(
                input.ports.resolve_guild_chest,
                value.guild_id,
                value.chest_container_id
            )
            local resolved = resolved_ok
                and project_resolution(resolved_value, value.chest_container_id)
                or nil
            if resolved == nil then
                record.status = "blocked"
                add_guild_error(
                    record,
                    blocking_errors,
                    index,
                    "CGCE-AUD-CONTAINER-UNRESOLVED",
                    "chest_container_id",
                    "configured guild chest could not be resolved exactly"
                )
            else
                if resolved.owner_guild_id ~= value.guild_id then
                    record.status = "blocked"
                    add_guild_error(
                        record,
                        blocking_errors,
                        index,
                        "CGCE-AUD-OWNER-MISMATCH",
                        "owner_guild_id",
                        "resolved container owner does not match the guild"
                    )
                end
                if not resolved.is_guild_chest then
                    record.status = "blocked"
                    add_guild_error(
                        record,
                        blocking_errors,
                        index,
                        "CGCE-AUD-NON-GUILD-CONTAINER",
                        "chest_container_id",
                        "configured reference is not a guild chest"
                    )
                end

                if #record.errors == 0 then
                    local snapshot_ok, snapshot_value = pcall(
                        input.ports.snapshot_container,
                        resolved.container
                    )
                    local detached = snapshot_ok
                        and project_snapshot(snapshot_value, value.chest_container_id, value.guild_id)
                        or nil
                    if detached == nil then
                        record.status = "blocked"
                        add_guild_error(
                            record,
                            blocking_errors,
                            index,
                            "CGCE-AUD-SNAPSHOT",
                            "snapshot",
                            "detached container snapshot failed validation"
                        )
                    else
                        record.snapshot = detached
                        local selected = (#input.include_guild_ids == 0 or input.include_set[value.guild_id])
                            and not input.exclude_set[value.guild_id]
                        if has_filter_overlap then
                            local overlaps = input.include_set[value.guild_id]
                                and input.exclude_set[value.guild_id]
                            record.status = (not selected and not overlaps)
                                and "excluded_by_filter"
                                or "blocked"
                        elseif not selected then
                            record.status = "excluded_by_filter"
                        elseif detached.slot_count < input.target_slots then
                            record.status = "eligible_expand"
                            record.eligible_action = "expand"
                        else
                            record.status = "eligible_noop"
                            record.eligible_action = "noop"
                        end
                    end
                end
            end
        end
        sort_errors(record.errors)
    end

    sort_errors(blocking_errors)
    return finalize({
        schema = "cgce.audit.v1",
        world_id = input.world_id,
        game_revision = input.game_revision,
        deployment_profile = input.deployment_profile,
        target_slots = input.target_slots,
        include_guild_ids = input.include_guild_ids,
        exclude_guild_ids = input.exclude_guild_ids,
        guilds = records,
        blocking_errors = blocking_errors,
    })
end

local function require_captured(value)
    local trusted = captured[value]
    if trusted == nil then
        fail("CGCE-AUD-CHECKSUM", "audit", "value is not a captured audit")
    end
    return trusted
end

function audit.canonical_json(value)
    return require_captured(value).canonical
end

function audit.checksum(value)
    return require_captured(value).checksum
end

function audit.to_table(value)
    local trusted = require_captured(value)
    local ok, detached = pcall(json_decode, trusted.canonical)
    if not ok then
        fail("CGCE-AUD-CHECKSUM", "audit", "cached canonical audit could not be decoded")
    end
    return detached
end

return audit
