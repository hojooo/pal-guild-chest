local a = require("tests.support.assertions")
local binding_symbols = require("CrossplayGuildChestExpander.Scripts.binding_symbols")

local expected = {
    { name = "world_ready_function", kind = "function" },
    { name = "world_ready_state_property", kind = "property" },
    { name = "selected_world_class", kind = "class" },
    { name = "world_id_property", kind = "property" },
    { name = "selected_world_guild_manager_property", kind = "property" },
    { name = "selected_world_container_manager_property", kind = "property" },
    { name = "guild_manager_class", kind = "class" },
    { name = "guild_class", kind = "class" },
    { name = "guild_list_property", kind = "property" },
    { name = "guild_id_property", kind = "property" },
    { name = "guild_name_property", kind = "property" },
    { name = "guild_chest_container_id_property", kind = "property" },
    { name = "guild_chest_class", kind = "class" },
    { name = "guild_chest_container_manager_property", kind = "property" },
    { name = "container_manager_class", kind = "class" },
    { name = "find_container_function", kind = "function" },
    { name = "container_id_property", kind = "property" },
    { name = "container_owner_guild_id_property", kind = "property" },
    { name = "slot_array_property", kind = "property" },
    { name = "slot_occupancy_discriminator_property", kind = "property" },
    { name = "item_static_id_property", kind = "property" },
    { name = "item_dynamic_guid_property", kind = "property" },
    { name = "item_quantity_property", kind = "property" },
    { name = "item_durability_property", kind = "property" },
    { name = "item_metadata_hash_inputs_property", kind = "property" },
    { name = "empty_slot_type", kind = "struct" },
    { name = "resize_function", kind = "function" },
    { name = "mark_dirty_function", kind = "function" },
    { name = "replicate_function", kind = "function" },
    { name = "new_guild_function", kind = "function" },
    { name = "container_in_use_function", kind = "function" },
    { name = "fatal_safe_stop_function", kind = "function" },
}

describe("binding_symbols catalog", function()
    it("returns the exact ordered 32-symbol catalog as detached data", function()
        local first = binding_symbols.list()
        local second = binding_symbols.list()

        a.deep_equal(expected, first)
        a.deep_equal(expected, second)
        a.equal(32, #first)
        a.equal(false, rawequal(first, second))
        a.equal(false, rawequal(first[1], second[1]))

        first[1].name = "forged"
        first[2] = nil
        a.deep_equal(expected, binding_symbols.list())
    end)

    it("exports only the detached list accessor", function()
        local exports = {}
        for key in pairs(binding_symbols) do
            exports[#exports + 1] = key
        end
        table.sort(exports)
        a.deep_equal({ "list" }, exports)
        a.equal(nil, binding_symbols.catalog)
        a.equal(nil, binding_symbols.kinds)
    end)
end)
