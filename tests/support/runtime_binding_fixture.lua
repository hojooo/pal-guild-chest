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
    fake.add_loaded(raw_descriptors.guild_manager_class, guild_manager)
    fake.add_loaded(raw_descriptors.container_manager_class, container_manager)
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
        guild_manager
    )
    fake.set_property_value(
        selected_world,
        descriptors.selected_world_container_manager_property.member_name,
        container_manager
    )

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

    function runtime:duplicate_guild_manager_inventory()
        fake.add_loaded(raw_descriptors.guild_manager_class, guild_manager)
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
