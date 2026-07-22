local validator = {}

local existing_slot_fields = {
    "durability",
    "dynamic_guid",
    "empty",
    "index",
    "instance_metadata_hash",
    "quantity",
    "static_id",
}

local function violation(code, field, detail, expected, actual, index)
    return {
        code = code,
        field = field,
        detail = detail,
        expected = expected,
        actual = actual,
        index = index,
    }
end

local function add_if_changed(violations, code, field, detail, expected, actual)
    if expected ~= actual then
        violations[#violations + 1] = violation(code, field, detail, expected, actual)
    end
end

function validator.compare(before, after, target)
    local violations = {}

    add_if_changed(
        violations,
        "CGCE-VAL-001",
        "container_id",
        "container_id_changed",
        before.container_id,
        after.container_id
    )
    add_if_changed(
        violations,
        "CGCE-VAL-002",
        "owner_guild_id",
        "owner_guild_id_changed",
        before.owner_guild_id,
        after.owner_guild_id
    )

    local expected_slot_count = before.slot_count < target and target or before.slot_count
    add_if_changed(
        violations,
        "CGCE-VAL-003",
        "slot_count",
        "slot_count_mismatch",
        expected_slot_count,
        after.slot_count
    )
    add_if_changed(
        violations,
        "CGCE-VAL-004",
        "item_fingerprint",
        "item_fingerprint_changed",
        before.item_fingerprint,
        after.item_fingerprint
    )
    add_if_changed(
        violations,
        "CGCE-VAL-005",
        "occupied_slot_count",
        "occupied_slot_count_changed",
        before.occupied_slot_count,
        after.occupied_slot_count
    )
    add_if_changed(
        violations,
        "CGCE-VAL-006",
        "total_item_quantity",
        "total_item_quantity_changed",
        before.total_item_quantity,
        after.total_item_quantity
    )

    for index = 1, before.slot_count do
        local expected_record = before.slots[index]
        local actual_record = after.slots[index]
        for _, field in ipairs(existing_slot_fields) do
            local expected = expected_record and expected_record[field] or nil
            local actual = actual_record and actual_record[field] or nil
            if expected ~= actual then
                local path = "slots[" .. index .. "]." .. field
                violations[#violations + 1] = violation(
                    "CGCE-VAL-007",
                    path,
                    "existing_slot_field_changed",
                    expected,
                    actual,
                    index
                )
            end
        end
    end

    for index = before.slot_count + 1, after.slot_count do
        local record = after.slots[index]
        if record == nil or record.empty ~= true then
            violations[#violations + 1] = violation(
                "CGCE-VAL-008",
                "slots[" .. index .. "]",
                "appended_slot_not_empty",
                true,
                record and record.empty or nil,
                index
            )
        end
    end

    return #violations == 0, violations
end

return validator
