local a = require("tests.support.assertions")
local fake_adapter = require("tests.support.fake_adapter")
local snapshot = require("CrossplayGuildChestExpander.Scripts.snapshot")
local validator = require("CrossplayGuildChestExpander.Scripts.validator")

local function item(name, quantity)
    local byte = name == "wood" and "b" or "c"
    return fake_adapter.item({
        static_id = "PalItem/" .. name,
        dynamic_guid = "guid/" .. name,
        quantity = quantity or 1,
        durability = name == "wood" and "80.000000" or "60.000000",
        instance_metadata_hash = string.rep(byte, 64),
    })
end

local function captured(slot_count, occupied, overrides)
    local slots = {}
    for index = 1, slot_count do
        slots[index] = fake_adapter.slot(occupied and occupied[index] or nil)
    end
    local container = fake_adapter.container({ slots = slots })
    for key, value in pairs(overrides or {}) do
        container[key] = value
    end
    return snapshot.capture(fake_adapter.new(), container)
end

local function clone(value, seen)
    if type(value) ~= "table" then
        return value
    end
    seen = seen or {}
    if seen[value] then
        return seen[value]
    end
    local copy = {}
    seen[value] = copy
    for key, item_value in pairs(value) do
        copy[clone(key, seen)] = clone(item_value, seen)
    end
    return copy
end

local function find_violation(violations, code, field)
    for _, violation in ipairs(violations) do
        if violation.code == code and (field == nil or violation.field == field) then
            return violation
        end
    end
    return nil
end

local function expect_violation(violations, code, field)
    local violation = find_violation(violations, code, field)
    a.equal("table", type(violation))
    a.equal("string", type(violation.detail))
    return violation
end

describe("validator.compare", function()
    it("accepts append-only empty expansion with preserved items", function()
        local before = captured(2, { [1] = item("wood", 7) })
        local after = captured(4, { [1] = item("wood", 7) })
        local ok, violations = validator.compare(before, after, 4)

        a.equal(true, ok)
        a.deep_equal({}, violations)
    end)

    it("accepts derived no-ops at target and above target", function()
        for _, slot_count in ipairs({ 358, 400 }) do
            local before = captured(slot_count, { [1] = item("wood", 7) })
            local after = captured(slot_count, { [1] = item("wood", 7) })
            local ok, violations = validator.compare(before, after, 358)
            a.equal(true, ok)
            a.deep_equal({}, violations)
        end
    end)

    it("rejects undershoot, overshoot, and shrink slot counts", function()
        local scenarios = {
            { before = 2, after = 3, target = 4, expected = 4 },
            { before = 2, after = 5, target = 4, expected = 4 },
            { before = 400, after = 358, target = 358, expected = 400 },
        }
        for _, scenario in ipairs(scenarios) do
            local ok, violations = validator.compare(
                captured(scenario.before),
                captured(scenario.after),
                scenario.target
            )
            a.equal(false, ok)
            local violation = expect_violation(violations, "CGCE-VAL-003", "slot_count")
            a.equal(scenario.expected, violation.expected)
            a.equal(scenario.after, violation.actual)
        end
    end)

    it("reports container and owner identity changes", function()
        local before = captured(1)
        local after = captured(1, nil, {
            container_id = "container/other",
            owner_guild_id = "guild/other",
        })
        local ok, violations = validator.compare(before, after, 1)

        a.equal(false, ok)
        expect_violation(violations, "CGCE-VAL-001", "container_id")
        expect_violation(violations, "CGCE-VAL-002", "owner_guild_id")
    end)

    it("reports every existing occupied-slot preservation field change", function()
        local before_item = item("wood", 7)
        local scenarios = {
            { field = "static_id", value = "PalItem/other" },
            { field = "dynamic_guid", value = "guid/other" },
            { field = "quantity", value = 8 },
            { field = "durability", value = "79.000000" },
            { field = "instance_metadata_hash", value = string.rep("d", 64) },
        }
        for _, scenario in ipairs(scenarios) do
            local changed = item("wood", 7)
            changed[scenario.field] = scenario.value
            local ok, violations = validator.compare(
                captured(1, { [1] = before_item }),
                captured(1, { [1] = changed }),
                1
            )
            a.equal(false, ok)
            expect_violation(violations, "CGCE-VAL-004", "item_fingerprint")
            local field = "slots[1]." .. scenario.field
            local violation = expect_violation(violations, "CGCE-VAL-007", field)
            a.equal(1, violation.index)
        end
    end)

    it("checks the stored index even when aggregate fingerprint is unchanged", function()
        local before = captured(1, { [1] = item("wood", 7) })
        local after = clone(before)
        after.slots[1].index = 2
        local ok, violations = validator.compare(before, after, 1)

        a.equal(false, ok)
        expect_violation(violations, "CGCE-VAL-007", "slots[1].index")
        a.equal(nil, find_violation(violations, "CGCE-VAL-004"))
    end)

    it("reports empty-to-occupied and occupied-to-empty transitions", function()
        local scenarios = {
            { before = captured(1), after = captured(1, { [1] = item("wood", 7) }) },
            { before = captured(1, { [1] = item("wood", 7) }), after = captured(1) },
        }
        for _, scenario in ipairs(scenarios) do
            local ok, violations = validator.compare(scenario.before, scenario.after, 1)
            a.equal(false, ok)
            expect_violation(violations, "CGCE-VAL-004", "item_fingerprint")
            expect_violation(violations, "CGCE-VAL-005", "occupied_slot_count")
            expect_violation(violations, "CGCE-VAL-006", "total_item_quantity")
            expect_violation(violations, "CGCE-VAL-007", "slots[1].empty")
        end
    end)

    it("detects item index swaps even when aggregate counts are unchanged", function()
        local before = captured(2, { item("wood", 7), item("stone", 11) })
        local after = captured(2, { item("stone", 11), item("wood", 7) })
        local ok, violations = validator.compare(before, after, 2)

        a.equal(false, ok)
        expect_violation(violations, "CGCE-VAL-004", "item_fingerprint")
        expect_violation(violations, "CGCE-VAL-007", "slots[1].dynamic_guid")
        expect_violation(violations, "CGCE-VAL-007", "slots[2].dynamic_guid")
        a.equal(nil, find_violation(violations, "CGCE-VAL-005"))
        a.equal(nil, find_violation(violations, "CGCE-VAL-006"))
    end)

    it("reports every appended non-empty slot", function()
        local before = captured(1, { [1] = item("wood", 7) })
        local after = captured(4, {
            [1] = item("wood", 7),
            [2] = item("stone", 2),
            [4] = item("stone", 3),
        })
        local ok, violations = validator.compare(before, after, 4)

        a.equal(false, ok)
        local first = expect_violation(violations, "CGCE-VAL-008", "slots[2]")
        local second = expect_violation(violations, "CGCE-VAL-008", "slots[4]")
        a.equal(2, first.index)
        a.equal(4, second.index)
    end)

    it("returns all violations in deterministic code, index, and field order", function()
        local before = captured(2, { [1] = item("wood", 7) })
        local after = captured(5, {
            [1] = item("stone", 11),
            [3] = item("wood", 1),
            [5] = item("stone", 1),
        }, {
            container_id = "container/other",
            owner_guild_id = "guild/other",
        })
        local ok, violations = validator.compare(before, after, 4)

        a.equal(false, ok)
        local previous_code = ""
        local previous_index = 0
        local previous_field = ""
        for _, violation in ipairs(violations) do
            a.equal("string", type(violation.code))
            a.equal("string", type(violation.field))
            a.equal("string", type(violation.detail))
            if violation.code == previous_code then
                local index = violation.index or 0
                a.equal(true, index >= previous_index)
                if index == previous_index then
                    a.equal(true, violation.field > previous_field)
                end
                previous_index = index
                previous_field = violation.field
            else
                a.equal(true, violation.code > previous_code)
                previous_code = violation.code
                previous_index = violation.index or 0
                previous_field = violation.field
            end
        end

        for number = 1, 8 do
            expect_violation(violations, string.format("CGCE-VAL-%03d", number))
        end
    end)
end)
