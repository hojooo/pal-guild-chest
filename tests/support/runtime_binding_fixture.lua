local fake_ue4ss = require("tests.support.fake_ue4ss")
local json = require("CrossplayGuildChestExpander.Scripts.json")
local revision_guard = require("CrossplayGuildChestExpander.Scripts.revision_guard")
local sha256 = require("CrossplayGuildChestExpander.Scripts.sha256")
local ue4ss_adapter = require("CrossplayGuildChestExpander.Scripts.ue4ss_adapter")

local runtime_binding_fixture = {}

local logical_kinds = {
    world_ready_function = "function",
    world_ready_state_property = "property",
    selected_world_class = "class",
    world_id_property = "property",
    selected_world_guild_manager_property = "property",
    selected_world_container_manager_property = "property",
    guild_manager_class = "class",
    guild_class = "class",
    guild_list_property = "property",
    guild_id_property = "property",
    guild_name_property = "property",
    guild_chest_container_id_property = "property",
    guild_chest_class = "class",
    guild_chest_container_manager_property = "property",
    container_manager_class = "class",
    find_container_function = "function",
    container_id_property = "property",
    container_owner_guild_id_property = "property",
    slot_array_property = "property",
    slot_occupancy_discriminator_property = "property",
    item_static_id_property = "property",
    item_dynamic_guid_property = "property",
    item_quantity_property = "property",
    item_durability_property = "property",
    item_metadata_hash_inputs_property = "property",
    empty_slot_type = "struct",
    resize_function = "function",
    mark_dirty_function = "function",
    replicate_function = "function",
    new_guild_function = "function",
    container_in_use_function = "function",
    fatal_safe_stop_function = "function",
}

local class_short_names = {
    selected_world_class = "CGCETestSelectedWorld",
    guild_manager_class = "CGCETestGuildManager",
    guild_class = "CGCETestGuild",
    guild_chest_class = "CGCETestGuildChest",
    container_manager_class = "CGCETestContainerManager",
}

local function descriptor(logical_name)
    local kind = assert(logical_kinds[logical_name])
    if kind == "property" then
        local owner_path = "/Script/CGCETest.Owner_" .. logical_name
        local member_name = "Member_" .. logical_name
        return {
            kind = kind,
            owner_path = owner_path,
            member_name = member_name,
            path = owner_path .. ":" .. member_name,
            type_signature = "Property<" .. logical_name .. ">",
        }
    end
    local path
    if logical_name == "world_ready_function" then
        path = "/Script/CGCETest.SelectedWorld:OnWorldReady"
    else
        path = "/Script/CGCETest." .. logical_name
    end
    return {
        kind = kind,
        path = path,
        type_signature = kind .. "<" .. logical_name .. ">",
    }
end

local function runtime_manifest()
    local symbols = {}
    for logical_name in pairs(logical_kinds) do
        symbols[logical_name] = descriptor(logical_name)
    end
    local value = {
        manifest_version = "1.0",
        kind = "runtime",
        game_revision = 123456,
        source_audit_checksum = string.rep("a", 64),
        symbols = symbols,
        tested_platform_matrix = { "SteamWindows", "PS5", "Mac" },
    }
    value.checksum = sha256.hex(json.encode(value))
    return value, json.encode(value)
end

local function install_descriptors(fake, descriptors)
    local raw_descriptors = {}
    for logical_name, value in pairs(descriptors) do
        if value.kind == "property" then
            local owner = fake.add_object({
                path = value.owner_path,
                type_signature = "Owner<" .. logical_name .. ">",
            })
            raw_descriptors[logical_name] = fake.add_property(owner, value)
        else
            raw_descriptors[logical_name] = fake.add_object({
                path = value.path,
                type_signature = value.type_signature,
                short_name = class_short_names[logical_name],
            })
        end
    end
    return raw_descriptors
end

function runtime_binding_fixture.new(options)
    options = options or {}
    local port, fake = fake_ue4ss.new()
    local manifest, manifest_text = runtime_manifest()
    local descriptors = manifest.symbols
    local raw_descriptors = install_descriptors(fake, descriptors)
    local runtime = {}

    local original_register = port.register_hook
    if options.on_register ~= nil then
        port.register_hook = function(path, first, second)
            options.on_register(runtime, path)
            return original_register(path, first, second)
        end
    end
    local original_find_all = port.find_all_of
    if options.on_find_all ~= nil then
        port.find_all_of = function(short_name)
            local values = original_find_all(short_name)
            options.on_find_all(runtime, short_name)
            return values
        end
    end
    local original_get_property_value = port.get_property_value
    if options.on_get_property ~= nil then
        port.get_property_value = function(property, object)
            local value = original_get_property_value(property, object)
            options.on_get_property(runtime, property, object, value)
            return value
        end
    end

    local selected_world = fake.add_object({
        path = "/Runtime/CGCETest/SelectedWorld/1",
        type_signature = "Object<CGCETestSelectedWorld>",
    })
    local guild_manager = fake.add_object({
        path = "/Runtime/CGCETest/GuildManager/1",
        type_signature = "Object<CGCETestGuildManager>",
    })
    local container_manager = fake.add_object({
        path = "/Runtime/CGCETest/ContainerManager/1",
        type_signature = "Object<CGCETestContainerManager>",
    })

    fake.add_loaded(raw_descriptors.selected_world_class, selected_world)
    local guild_manager_loaded = options.guild_manager_loaded ~= false
    local container_manager_loaded = options.container_manager_loaded ~= false
    if guild_manager_loaded then
        fake.add_loaded(raw_descriptors.guild_manager_class, guild_manager)
    end
    if container_manager_loaded then
        fake.add_loaded(raw_descriptors.container_manager_class, container_manager)
    end
    local guild_manager_reference = guild_manager
    if options.guild_manager_reference == false then
        guild_manager_reference = nil
    end
    local container_manager_reference = container_manager
    if options.container_manager_reference == false then
        container_manager_reference = nil
    end
    fake.set_property_value(
        selected_world,
        descriptors.world_ready_state_property.member_name,
        options.ready == nil and true or options.ready
    )
    fake.set_property_value(
        selected_world,
        descriptors.world_id_property.member_name,
        options.world_id == nil and "test-world-alpha" or options.world_id
    )
    fake.set_property_value(
        selected_world,
        descriptors.selected_world_guild_manager_property.member_name,
        guild_manager_reference
    )
    fake.set_property_value(
        selected_world,
        descriptors.selected_world_container_manager_property.member_name,
        container_manager_reference
    )

    local guilds = {}
    local guild_sequence = 0
    local guild_chest_sequence = 0
    local general_container_sequence = 0
    local slot_sequence = 0
    local function publish_guild_list()
        fake.set_property_value(
            guild_manager,
            descriptors.guild_list_property.member_name,
            fake.array(guilds)
        )
    end
    publish_guild_list()

    local adapter = ue4ss_adapter.new(port)

    local function check_session()
        return revision_guard.check({
            read_revision = function()
                return manifest.game_revision
            end,
            load_manifest = function(revision)
                assert(revision == manifest.game_revision)
                return manifest_text
            end,
            inspect_descriptor = function(_, expected)
                local actual, status = ue4ss_adapter.inspect_descriptor(adapter, expected)
                assert(status == "MATCHED")
                return actual
            end,
        })
    end

    local result, binding_session = check_session()
    assert(result.status == "SUPPORTED")

    runtime.adapter = adapter
    runtime.binding_session = binding_session
    runtime.descriptors = descriptors
    runtime.fake = fake
    runtime.manifest = manifest
    runtime.port = port
    runtime.raw = {
        selected_world = selected_world,
        guild_manager = guild_manager,
        container_manager = container_manager,
        descriptors = raw_descriptors,
    }

    function runtime:set_ready(value)
        fake.set_property_value(
            selected_world,
            descriptors.world_ready_state_property.member_name,
            value
        )
    end

    function runtime:set_world_id(value)
        fake.set_property_value(selected_world, descriptors.world_id_property.member_name, value)
    end

    function runtime:set_guild_manager(value)
        fake.set_property_value(
            selected_world,
            descriptors.selected_world_guild_manager_property.member_name,
            value
        )
    end

    function runtime:set_container_manager(value)
        fake.set_property_value(
            selected_world,
            descriptors.selected_world_container_manager_property.member_name,
            value
        )
    end

    function runtime:add_unlisted_guild_manager()
        return fake.add_object({
            path = "/Runtime/CGCETest/GuildManager/Unlisted",
            type_signature = "Object<CGCETestGuildManager>",
        })
    end

    function runtime:add_unlisted_container_manager()
        return fake.add_object({
            path = "/Runtime/CGCETest/ContainerManager/Unlisted",
            type_signature = "Object<CGCETestContainerManager>",
        })
    end

    function runtime:load_guild_manager()
        if not guild_manager_loaded then
            fake.add_loaded(raw_descriptors.guild_manager_class, guild_manager)
            guild_manager_loaded = true
        end
        return guild_manager
    end

    function runtime:load_container_manager()
        if not container_manager_loaded then
            fake.add_loaded(raw_descriptors.container_manager_class, container_manager)
            container_manager_loaded = true
        end
        return container_manager
    end

    function runtime:add_loaded_container_manager()
        local replacement = fake.add_object({
            path = "/Runtime/CGCETest/ContainerManager/Replacement",
            type_signature = "Object<CGCETestContainerManager>",
        })
        fake.add_loaded(raw_descriptors.container_manager_class, replacement)
        return replacement
    end

    function runtime:duplicate_guild_manager_inventory()
        fake.add_loaded(raw_descriptors.guild_manager_class, guild_manager)
    end

    function runtime:add_guild(guild_id, guild_name, chest_container_id, guild_options)
        guild_options = guild_options or {}
        guild_sequence = guild_sequence + 1
        local value = fake.add_object({
            path = "/Runtime/CGCETest/Guild/" .. guild_sequence,
            type_signature = "Object<CGCETestGuild>",
        })
        fake.set_property_value(value, descriptors.guild_id_property.member_name, guild_id)
        fake.set_property_value(value, descriptors.guild_name_property.member_name, guild_name)
        fake.set_property_value(
            value,
            descriptors.guild_chest_container_id_property.member_name,
            chest_container_id
        )
        if guild_options.loaded ~= false then
            fake.add_loaded(raw_descriptors.guild_class, value)
        end
        if guild_options.listed ~= false then
            guilds[#guilds + 1] = value
            publish_guild_list()
        end
        return value
    end

    function runtime:set_guild_list(values)
        for index = #guilds, 1, -1 do
            guilds[index] = nil
        end
        for index, value in ipairs(values) do
            guilds[index] = value
        end
        publish_guild_list()
    end

    function runtime:set_guild_list_null()
        fake.set_property_value(guild_manager, descriptors.guild_list_property.member_name, nil)
    end

    function runtime:duplicate_guild_inventory(value)
        fake.add_loaded(raw_descriptors.guild_class, value)
    end

    function runtime:add_guild_chest(container_id, owner_guild_id, chest_options)
        chest_options = chest_options or {}
        guild_chest_sequence = guild_chest_sequence + 1
        local value = fake.add_object({
            path = "/Runtime/CGCETest/GuildChest/" .. guild_chest_sequence,
            type_signature = "Object<CGCETestGuildChest>",
        })
        fake.set_property_value(
            value,
            descriptors.container_id_property.member_name,
            container_id
        )
        fake.set_property_value(
            value,
            descriptors.container_owner_guild_id_property.member_name,
            owner_guild_id
        )
        fake.set_property_value(
            value,
            descriptors.guild_chest_container_manager_property.member_name,
            chest_options.manager or container_manager
        )
        fake.set_property_value(
            value,
            descriptors.slot_array_property.member_name,
            fake.array(chest_options.slots or {})
        )
        if chest_options.loaded ~= false then
            fake.add_loaded(raw_descriptors.guild_chest_class, value)
        end
        return value
    end

    function runtime:set_slot_item(slot, item)
        local occupied = item ~= nil
        fake.set_property_value(
            slot,
            descriptors.slot_occupancy_discriminator_property.member_name,
            occupied
        )
        for logical_name, field in pairs({
            item_static_id_property = "static_id",
            item_dynamic_guid_property = "dynamic_guid",
            item_quantity_property = "quantity",
            item_durability_property = "durability",
            item_metadata_hash_inputs_property = "instance_metadata_hash",
        }) do
            fake.set_property_value(
                slot,
                descriptors[logical_name].member_name,
                occupied and item[field] or nil
            )
        end
    end

    function runtime:add_slot(item)
        slot_sequence = slot_sequence + 1
        local slot = fake.add_object({
            path = "/Runtime/CGCETest/Slot/" .. slot_sequence,
            type_signature = "Object<CGCETestSlot>",
        })
        runtime:set_slot_item(slot, item)
        return slot
    end

    function runtime:set_container_slots(value, slots)
        fake.set_property_value(
            value,
            descriptors.slot_array_property.member_name,
            fake.array(slots)
        )
    end

    function runtime:add_general_container(container_id, owner_guild_id, container_options)
        container_options = container_options or {}
        general_container_sequence = general_container_sequence + 1
        local value = fake.add_object({
            path = "/Runtime/CGCETest/GeneralContainer/" .. general_container_sequence,
            type_signature = "Object<CGCETestGeneralContainer>",
        })
        fake.set_property_value(
            value,
            descriptors.container_id_property.member_name,
            container_id
        )
        fake.set_property_value(
            value,
            descriptors.container_owner_guild_id_property.member_name,
            owner_guild_id
        )
        fake.set_property_value(
            value,
            descriptors.guild_chest_container_manager_property.member_name,
            container_options.manager or container_manager
        )
        if container_options.loaded ~= false then
            fake.add_loaded("CGCETestGeneralContainer", value)
        end
        return value
    end

    function runtime:duplicate_guild_chest_inventory(value)
        fake.add_loaded(raw_descriptors.guild_chest_class, value)
    end

    function runtime:set_container_id(value, container_id)
        fake.set_property_value(value, descriptors.container_id_property.member_name, container_id)
    end

    function runtime:set_container_owner_guild_id(value, owner_guild_id)
        fake.set_property_value(
            value,
            descriptors.container_owner_guild_id_property.member_name,
            owner_guild_id
        )
    end

    function runtime:set_container_object_manager(value, manager)
        fake.set_property_value(
            value,
            descriptors.guild_chest_container_manager_property.member_name,
            manager
        )
    end

    function runtime:set_guild_id(value, guild_id)
        fake.set_property_value(value, descriptors.guild_id_property.member_name, guild_id)
    end

    function runtime:set_guild_name(value, guild_name)
        fake.set_property_value(value, descriptors.guild_name_property.member_name, guild_name)
    end

    function runtime:set_guild_chest_id(value, chest_container_id)
        fake.set_property_value(
            value,
            descriptors.guild_chest_container_id_property.member_name,
            chest_container_id
        )
    end

    function runtime:add_selected_world()
        local extra = fake.add_object({
            path = "/Runtime/CGCETest/SelectedWorld/Extra",
            type_signature = "Object<CGCETestSelectedWorld>",
        })
        fake.add_loaded(raw_descriptors.selected_world_class, extra)
        return extra
    end

    function runtime:fire_world_ready()
        fake.fire(descriptors.world_ready_function.path, "post", "ignored-arg", "ignored-return")
    end

    function runtime:fire_world_ready_late()
        return fake.fire_late(1, "post", "ignored-arg", "ignored-return")
    end

    function runtime:fail_world_ready_unregister()
        fake.fail_unregister(descriptors.world_ready_function.path)
    end

    function runtime:supersede_session()
        local superseding, session = check_session()
        assert(superseding.status == "SUPPORTED")
        return session
    end

    return runtime
end

return runtime_binding_fixture
