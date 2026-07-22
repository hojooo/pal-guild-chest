local a = require("tests.support.assertions")
local fake_adapter = require("tests.support.fake_adapter")
local json = require("CrossplayGuildChestExpander.Scripts.json")
local sha256 = require("CrossplayGuildChestExpander.Scripts.sha256")
local snapshot = require("CrossplayGuildChestExpander.Scripts.snapshot")

local function expect_error(code, field, fn)
    local ok, err = pcall(fn)
    a.equal(false, ok)
    a.equal("table", type(err))
    a.equal(code, err.code)
    a.equal(field, err.field)
    a.equal("string", type(err.detail))
end

local function capture(container, adapter)
    return snapshot.capture(adapter or fake_adapter.new(), container)
end

describe("snapshot.capture", function()
    it("captures every preservation field in engine slot order", function()
        local first = fake_adapter.item({
            static_id = "PalItem/Wood",
            dynamic_guid = "guid/wood",
            quantity = 7,
            durability = "88.500000",
            instance_metadata_hash = string.rep("b", 64),
        })
        local third = fake_adapter.item({
            static_id = "PalItem/Stone",
            dynamic_guid = "guid/stone",
            quantity = 11,
            durability = "0.000000",
            instance_metadata_hash = string.rep("c", 64),
        })
        local actual = capture(fake_adapter.container({
            container_id = "container/한글",
            owner_guild_id = "guild/한글",
            slots = {
                fake_adapter.slot(first),
                fake_adapter.slot(nil),
                fake_adapter.slot(third),
                fake_adapter.slot(nil),
            },
        }))

        a.equal("1.0", actual.version)
        a.equal("container/한글", actual.container_id)
        a.equal("guild/한글", actual.owner_guild_id)
        a.equal(4, actual.slot_count)
        a.equal(2, actual.occupied_slot_count)
        a.equal(18, actual.total_item_quantity)
        a.deep_equal({ index = 2, empty = true }, actual.slots[2])
        a.deep_equal({
            index = 3,
            empty = false,
            static_id = "PalItem/Stone",
            dynamic_guid = "guid/stone",
            quantity = 11,
            durability = "0.000000",
            instance_metadata_hash = string.rep("c", 64),
        }, actual.slots[3])
        a.equal("[]", json.encode(snapshot.capture(fake_adapter.new(), fake_adapter.container()).slots))
    end)

    it("fingerprints canonical occupied records regardless of Lua insertion order", function()
        local item = {}
        item.quantity = 7
        item.instance_metadata_hash = string.rep("d", 64)
        item.static_id = "PalItem/Wood"
        item.durability = "88.500000"
        item.dynamic_guid = "guid/wood"

        local actual = capture(fake_adapter.container({
            slots = { fake_adapter.slot(item), fake_adapter.slot(nil) },
        }))
        local occupied = {
            index = 1,
            empty = false,
            static_id = "PalItem/Wood",
            dynamic_guid = "guid/wood",
            quantity = 7,
            durability = "88.500000",
            instance_metadata_hash = string.rep("d", 64),
        }
        local expected = sha256.hex(json.encode({
            schema = "cgce.item-fingerprint.v1",
            items = json.array({ occupied }),
        }))

        a.equal(expected, actual.item_fingerprint)
        local reordered = capture(fake_adapter.container({
            slots = { fake_adapter.slot(fake_adapter.item({
                static_id = "PalItem/Wood",
                dynamic_guid = "guid/wood",
                quantity = 7,
                durability = "88.500000",
                instance_metadata_hash = string.rep("d", 64),
            })) },
        }))
        a.equal(actual.item_fingerprint, reordered.item_fingerprint)
    end)

    it("includes slot index but ignores trailing empty slots", function()
        local item = fake_adapter.item()
        local at_one = capture(fake_adapter.container({
            slots = { fake_adapter.slot(item) },
        }))
        local with_trailing_empty = capture(fake_adapter.container({
            slots = { fake_adapter.slot(item), fake_adapter.slot(nil) },
        }))
        local at_two = capture(fake_adapter.container({
            slots = { fake_adapter.slot(nil), fake_adapter.slot(item) },
        }))

        a.equal(at_one.item_fingerprint, with_trailing_empty.item_fingerprint)
        a.equal(false, at_one.item_fingerprint == at_two.item_fingerprint)
    end)

    it("detaches snapshots from adapter-owned slot and item objects", function()
        local item = fake_adapter.item()
        local slot = fake_adapter.slot(item)
        local container = fake_adapter.container({ slots = { slot } })
        local actual = capture(container)

        item.quantity = 999
        item.dynamic_guid = "changed"
        slot.item = nil
        container.slots[1] = { uobject = true }

        a.equal(1, actual.slots[1].quantity)
        a.equal("guid/opaque", actual.slots[1].dynamic_guid)
        a.equal(nil, actual.slots[1].item)
        a.equal(nil, actual.slots[1].uobject)
    end)

    it("rejects missing adapter methods", function()
        for _, method in ipairs({ "container_id", "owner_guild_id", "slots", "slot_item" }) do
            local adapter = fake_adapter.new()
            adapter[method] = nil
            expect_error("CGCE-SNAP-ADAPTER", method, function()
                capture(fake_adapter.container(), adapter)
            end)
        end
    end)

    it("fails closed when any adapter method raises", function()
        local scenarios = {
            { method = "container_id", code = "CGCE-SNAP-CONTAINER-ID", field = "container_id" },
            { method = "owner_guild_id", code = "CGCE-SNAP-OWNER-GUILD-ID", field = "owner_guild_id" },
            { method = "slots", code = "CGCE-SNAP-SLOTS", field = "slots" },
            { method = "slot_item", code = "CGCE-SNAP-SLOT-ITEM", field = "slots[1]" },
        }
        for _, scenario in ipairs(scenarios) do
            local adapter = fake_adapter.new()
            adapter[scenario.method] = function()
                error("adapter failure")
            end
            local container = fake_adapter.container({ slots = { fake_adapter.slot(nil) } })
            expect_error(scenario.code, scenario.field, function()
                capture(container, adapter)
            end)
        end
    end)

    it("rejects malformed opaque IDs", function()
        for _, scenario in ipairs({
            { key = "container_id", code = "CGCE-SNAP-CONTAINER-ID", value = nil },
            { key = "container_id", code = "CGCE-SNAP-CONTAINER-ID", value = "" },
            { key = "container_id", code = "CGCE-SNAP-CONTAINER-ID", value = 1 },
            { key = "owner_guild_id", code = "CGCE-SNAP-OWNER-GUILD-ID", value = nil },
            { key = "owner_guild_id", code = "CGCE-SNAP-OWNER-GUILD-ID", value = "" },
            { key = "owner_guild_id", code = "CGCE-SNAP-OWNER-GUILD-ID", value = false },
        }) do
            local container = fake_adapter.container()
            container[scenario.key] = scenario.value
            expect_error(scenario.code, scenario.key, function()
                capture(container)
            end)
        end
    end)

    it("rejects malformed slot arrays", function()
        for _, slots in ipairs({
            false,
            { named = fake_adapter.slot(nil) },
            { [1] = fake_adapter.slot(nil), [3] = fake_adapter.slot(nil) },
            { [0] = fake_adapter.slot(nil) },
        }) do
            expect_error("CGCE-SNAP-SLOTS", "slots", function()
                capture(fake_adapter.container({ slots = slots }))
            end)
        end
    end)

    it("rejects missing, malformed, and unknown occupied-item fields", function()
        local valid = fake_adapter.item()
        local scenarios = {
            { field = "static_id", value = nil },
            { field = "static_id", value = "" },
            { field = "dynamic_guid", value = nil },
            { field = "dynamic_guid", value = "" },
            { field = "quantity", value = nil },
            { field = "quantity", value = 0 },
            { field = "quantity", value = 1.5 },
            { field = "durability", value = nil },
            { field = "durability", value = 100 },
            { field = "instance_metadata_hash", value = nil },
            { field = "instance_metadata_hash", value = string.rep("A", 64) },
            { field = "instance_metadata_hash", value = string.rep("a", 63) },
        }
        for _, scenario in ipairs(scenarios) do
            local item = {}
            for key, value in pairs(valid) do
                item[key] = value
            end
            item[scenario.field] = scenario.value
            expect_error("CGCE-SNAP-ITEM", "slots[1]." .. scenario.field, function()
                capture(fake_adapter.container({ slots = { fake_adapter.slot(item) } }))
            end)
        end

        expect_error("CGCE-SNAP-ITEM", "slots[1]", function()
            capture(fake_adapter.container({ slots = { fake_adapter.slot(false) } }))
        end)
        local with_unknown = fake_adapter.item({ uobject = {} })
        expect_error("CGCE-SNAP-ITEM", "slots[1].uobject", function()
            capture(fake_adapter.container({ slots = { fake_adapter.slot(with_unknown) } }))
        end)
    end)
end)
