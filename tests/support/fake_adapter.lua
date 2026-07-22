local fake_adapter = {}

function fake_adapter.new()
    return {
        container_id = function(container)
            return container.container_id
        end,
        owner_guild_id = function(container)
            return container.owner_guild_id
        end,
        slots = function(container)
            return container.slots
        end,
        slot_item = function(slot)
            return slot.item
        end,
    }
end

function fake_adapter.container(overrides)
    local container = {
        container_id = "container/opaque",
        owner_guild_id = "guild/opaque",
        slots = {},
    }
    for key, value in pairs(overrides or {}) do
        container[key] = value
    end
    return container
end

function fake_adapter.slot(item)
    return { item = item }
end

function fake_adapter.item(overrides)
    local item = {
        static_id = "PalItem/Stone",
        dynamic_guid = "guid/opaque",
        quantity = 1,
        durability = "100.000000",
        instance_metadata_hash = string.rep("a", 64),
    }
    for key, value in pairs(overrides or {}) do
        item[key] = value
    end
    return item
end

return fake_adapter
