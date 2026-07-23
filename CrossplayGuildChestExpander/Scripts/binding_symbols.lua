local binding_symbols = {}

local catalog = {
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

function binding_symbols.list()
    local result = {}
    for index, symbol in ipairs(catalog) do
        result[index] = {
            name = symbol.name,
            kind = symbol.kind,
        }
    end
    return result
end

return binding_symbols
