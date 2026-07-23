local fingerprint = require("CrossplayGuildChestExpander.Scripts.fingerprint")
local json = require("CrossplayGuildChestExpander.Scripts.json")

local snapshot = {}
local fingerprint_compute = fingerprint.compute
local json_array = json.array
local json_encode = json.encode

local item_fields = {
    static_id = true,
    dynamic_guid = true,
    quantity = true,
    durability = true,
    instance_metadata_hash = true,
}

local function fail(code, field, detail)
    error({ code = code, field = field, detail = detail }, 0)
end

local function is_json_string(value, allow_empty)
    if type(value) ~= "string" or (not allow_empty and #value == 0) then
        return false
    end
    return pcall(json_encode, value)
end

local function require_adapter(adapter)
    if type(adapter) ~= "table" then
        fail("CGCE-SNAP-ADAPTER", nil, "snapshot adapter must be a table")
    end
    for _, method in ipairs({ "container_id", "owner_guild_id", "slots", "slot_item" }) do
        if type(adapter[method]) ~= "function" then
            fail("CGCE-SNAP-ADAPTER", method, "required read-only adapter method is unavailable")
        end
    end
end

local function read_adapter(adapter, method, argument, code, field)
    local ok, value = pcall(adapter[method], argument)
    if not ok then
        fail(code, field, "read-only adapter projection failed")
    end
    return value
end

local function validate_id(value, code, field)
    if not is_json_string(value, false) then
        fail(code, field, field .. " must be a non-empty opaque string")
    end
    return value
end

local function array_length(slots)
    if type(slots) ~= "table" then
        fail("CGCE-SNAP-SLOTS", "slots", "slots must be a dense 1-based engine-order array")
    end

    local count = 0
    local largest = 0
    for key in pairs(slots) do
        if type(key) ~= "number" or math.type(key) ~= "integer" or key < 1 then
            fail("CGCE-SNAP-SLOTS", "slots", "slots must be a dense 1-based engine-order array")
        end
        count = count + 1
        if key > largest then
            largest = key
        end
    end
    if largest ~= count then
        fail("CGCE-SNAP-SLOTS", "slots", "slots must be a dense 1-based engine-order array")
    end
    return count
end

local function validate_item(item, index)
    local prefix = "slots[" .. index .. "]"
    if type(item) ~= "table" then
        fail("CGCE-SNAP-ITEM", prefix, "occupied slot projection must be a table")
    end
    for key in pairs(item) do
        if not item_fields[key] then
            local field = type(key) == "string"
                and prefix .. "." .. key
                or prefix .. ".invalid_field"
            fail("CGCE-SNAP-ITEM", field, "unknown occupied-item projection field")
        end
    end

    if not is_json_string(item.static_id, false) then
        fail("CGCE-SNAP-ITEM", prefix .. ".static_id", "static_id must be a non-empty opaque string")
    end
    if not is_json_string(item.dynamic_guid, false) then
        fail("CGCE-SNAP-ITEM", prefix .. ".dynamic_guid", "dynamic_guid must be a non-empty opaque string")
    end
    if type(item.quantity) ~= "number" or math.type(item.quantity) ~= "integer" or item.quantity < 1 then
        fail("CGCE-SNAP-ITEM", prefix .. ".quantity", "quantity must be an integer greater than or equal to one")
    end
    if not is_json_string(item.durability, false) then
        fail("CGCE-SNAP-ITEM", prefix .. ".durability", "durability must be a canonical non-empty string")
    end
    if type(item.instance_metadata_hash) ~= "string"
        or #item.instance_metadata_hash ~= 64
        or not item.instance_metadata_hash:match("^[0-9a-f]+$") then
        fail(
            "CGCE-SNAP-ITEM",
            prefix .. ".instance_metadata_hash",
            "instance_metadata_hash must be lowercase SHA-256"
        )
    end

    return {
        index = index,
        empty = false,
        static_id = item.static_id,
        dynamic_guid = item.dynamic_guid,
        quantity = item.quantity,
        durability = item.durability,
        instance_metadata_hash = item.instance_metadata_hash,
    }
end

local function add_quantity(total, quantity)
    if quantity > math.maxinteger - total then
        fail(
            "CGCE-SNAP-QUANTITY-OVERFLOW",
            "total_item_quantity",
            "total item quantity exceeds Lua integer range"
        )
    end
    return total + quantity
end

function snapshot.capture(adapter, container)
    require_adapter(adapter)

    local container_id = validate_id(
        read_adapter(adapter, "container_id", container, "CGCE-SNAP-CONTAINER-ID", "container_id"),
        "CGCE-SNAP-CONTAINER-ID",
        "container_id"
    )
    local owner_guild_id = validate_id(
        read_adapter(adapter, "owner_guild_id", container, "CGCE-SNAP-OWNER-GUILD-ID", "owner_guild_id"),
        "CGCE-SNAP-OWNER-GUILD-ID",
        "owner_guild_id"
    )
    local adapter_slots = read_adapter(adapter, "slots", container, "CGCE-SNAP-SLOTS", "slots")
    local slot_count = array_length(adapter_slots)
    local records = json_array()
    local occupied_records = json_array()
    local total_quantity = 0

    for index = 1, slot_count do
        local item = read_adapter(
            adapter,
            "slot_item",
            adapter_slots[index],
            "CGCE-SNAP-SLOT-ITEM",
            "slots[" .. index .. "]"
        )
        if item == nil then
            records[index] = { index = index, empty = true }
        else
            local record = validate_item(item, index)
            records[index] = record
            occupied_records[#occupied_records + 1] = record
            total_quantity = add_quantity(total_quantity, record.quantity)
        end
    end

    return {
        version = "1.0",
        container_id = container_id,
        owner_guild_id = owner_guild_id,
        slot_count = slot_count,
        occupied_slot_count = #occupied_records,
        total_item_quantity = total_quantity,
        slots = records,
        item_fingerprint = fingerprint_compute(occupied_records),
    }
end

return snapshot
