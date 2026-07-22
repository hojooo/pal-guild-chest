local json = require("CrossplayGuildChestExpander.Scripts.json")
local revision_guard = require("CrossplayGuildChestExpander.Scripts.revision_guard")
local ue4ss_adapter = require("CrossplayGuildChestExpander.Scripts.ue4ss_adapter")
local world_ready = require("CrossplayGuildChestExpander.Scripts.world_ready")

local guild_repository = {}

local adapter_capabilities = ue4ss_adapter.capabilities
local adapter_inventory_loaded = ue4ss_adapter.inventory_loaded
local adapter_read_property = ue4ss_adapter.read_property
local adapter_resolve_exact = ue4ss_adapter.resolve_exact
local adapter_same_object = ue4ss_adapter.same_object
local binding_descriptor = revision_guard.descriptor
local json_array = json.array
local json_encode = json.encode
local json_null = json.null
local world_assert_current = world_ready.assert_current
local world_assert_relation = world_ready.assert_relation
local world_id = world_ready.world_id

local option_fields = {
    adapter = true,
    binding_session = true,
    world_epoch = true,
}

local option_field_order = {
    "adapter",
    "binding_session",
    "world_epoch",
}

local descriptor_names = {
    "selected_world_class",
    "world_id_property",
    "selected_world_guild_manager_property",
    "guild_manager_class",
    "guild_list_property",
    "guild_class",
    "guild_id_property",
    "guild_name_property",
    "guild_chest_container_id_property",
}

local function problem(code, field, detail)
    return {
        code = code,
        field = field,
        detail = detail,
    }
end

local function fail(code, field, detail)
    error(problem(code, field, detail), 0)
end

local function sorted_unknown_key(value, allowed)
    local unknown = {}
    local non_string = false
    for key in next, value do
        if type(key) ~= "string" then
            non_string = true
        elseif not allowed[key] then
            unknown[#unknown + 1] = key
        end
    end
    if non_string then
        return false
    end
    table.sort(unknown)
    return unknown[1]
end

local function capture_options(options)
    if type(options) ~= "table" or getmetatable(options) ~= nil then
        fail("CGCE-GUILD-OPTIONS", "options", "guild repository options must be a plain table")
    end
    local unknown = sorted_unknown_key(options, option_fields)
    if unknown == false then
        fail("CGCE-GUILD-OPTIONS", "options", "guild repository option keys must be strings")
    end
    if unknown ~= nil then
        fail("CGCE-GUILD-OPTIONS", unknown, "unknown guild repository option")
    end

    local captured = {}
    for _, field in ipairs(option_field_order) do
        local value = rawget(options, field)
        if value == nil then
            fail("CGCE-GUILD-OPTIONS", field, "required guild repository option is missing")
        end
        captured[field] = value
    end
    return captured
end

local function dense_length(value)
    if type(value) ~= "table" or getmetatable(value) ~= nil then
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

local function valid_json_string(value, allow_empty)
    if type(value) ~= "string" or (not allow_empty and #value == 0) then
        return false
    end
    local ok, encoded = pcall(json_encode, value)
    return ok and type(encoded) == "string" and encoded:sub(1, 1) == '"'
end

local function validate_read_only_capabilities(value)
    return type(value) == "table"
        and value.mutation_capability == false
        and value.function_invoke_capability == false
        and value.raw_property_write_capability == false
        and value.tarray_write_capability == false
end

local function resolve_class(adapter, descriptor, code, field, detail)
    local ok, class, status = pcall(adapter_resolve_exact, adapter, descriptor)
    if not ok or class == nil or status ~= "MATCHED" then
        fail(code, field, detail)
    end
    return class
end

local function inventory(adapter, class, code, field, detail)
    local ok, values = pcall(adapter_inventory_loaded, adapter, class)
    if not ok or dense_length(values) == nil then
        fail(code, field, detail)
    end
    return values
end

local function read_property(adapter, object, descriptor, code, field, detail)
    local ok, value = pcall(adapter_read_property, adapter, object, descriptor)
    if not ok then
        fail(code, field, detail)
    end
    return value
end

local function same_object(adapter, left, right)
    local ok, equal = pcall(adapter_same_object, adapter, left, right)
    return ok and equal == true
end

local function exact_match_count(adapter, reference, values)
    if type(reference) ~= "function" then
        return nil
    end
    local count = 0
    for _, candidate in ipairs(values) do
        if same_object(adapter, reference, candidate) then
            count = count + 1
        end
    end
    return count
end

local function descriptor_snapshot(binding_session)
    local descriptors = {}
    for _, logical_name in ipairs(descriptor_names) do
        descriptors[logical_name] = binding_descriptor(binding_session, logical_name)
    end
    return descriptors
end

local function collect(options, descriptors, expected_world_id)
    local selected_world_class = resolve_class(
        options.adapter,
        descriptors.selected_world_class,
        "CGCE-GUILD-SELECTED-WORLD-RELATION",
        "selected_world",
        "exact selected-world class is unavailable"
    )
    local selected_worlds = inventory(
        options.adapter,
        selected_world_class,
        "CGCE-GUILD-SELECTED-WORLD-RELATION",
        "selected_world",
        "exact selected-world inventory is unavailable"
    )
    if #selected_worlds ~= 1 then
        fail(
            "CGCE-GUILD-SELECTED-WORLD-RELATION",
            "selected_world",
            "exactly one selected-world instance is required"
        )
    end
    local selected_world = selected_worlds[1]

    local observed_world_id = read_property(
        options.adapter,
        selected_world,
        descriptors.world_id_property,
        "CGCE-GUILD-SELECTED-WORLD-RELATION",
        "world_id",
        "selected-world ID projection failed"
    )
    if not valid_json_string(observed_world_id, false)
        or observed_world_id ~= expected_world_id then
        fail(
            "CGCE-GUILD-SELECTED-WORLD-RELATION",
            "world_id",
            "selected-world ID does not match the active epoch"
        )
    end

    local guild_manager = read_property(
        options.adapter,
        selected_world,
        descriptors.selected_world_guild_manager_property,
        "CGCE-GUILD-MANAGER-RELATION",
        "guild_manager",
        "selected-world guild-manager projection failed"
    )
    local guild_manager_class = resolve_class(
        options.adapter,
        descriptors.guild_manager_class,
        "CGCE-GUILD-MANAGER-RELATION",
        "guild_manager",
        "exact guild-manager class is unavailable"
    )
    local guild_managers = inventory(
        options.adapter,
        guild_manager_class,
        "CGCE-GUILD-MANAGER-RELATION",
        "guild_manager",
        "exact guild-manager inventory is unavailable"
    )
    if guild_manager == json_null
        or exact_match_count(options.adapter, guild_manager, guild_managers) ~= 1 then
        fail(
            "CGCE-GUILD-MANAGER-RELATION",
            "guild_manager",
            "selected-world guild-manager reference must match exact class inventory once"
        )
    end

    local guild_list = read_property(
        options.adapter,
        guild_manager,
        descriptors.guild_list_property,
        "CGCE-GUILD-LIST",
        "guild_list",
        "current-world guild list projection failed"
    )
    local guild_count = dense_length(guild_list)
    if guild_list == json_null or guild_count == nil then
        fail("CGCE-GUILD-LIST", "guild_list", "current-world guild list must be a dense array")
    end

    local guild_class = resolve_class(
        options.adapter,
        descriptors.guild_class,
        "CGCE-GUILD-CLASS-RELATION",
        "guild_class",
        "exact guild class is unavailable"
    )
    local loaded_guilds = inventory(
        options.adapter,
        guild_class,
        "CGCE-GUILD-CLASS-RELATION",
        "guild_class",
        "exact guild inventory is unavailable"
    )

    local entries = {}
    for index = 1, guild_count do
        local object = rawget(guild_list, index)
        if exact_match_count(options.adapter, object, loaded_guilds) ~= 1 then
            fail(
                "CGCE-GUILD-CLASS-RELATION",
                "guilds[" .. index .. "]",
                "current-world guild reference must match exact class inventory once"
            )
        end

        local field_prefix = "guilds[" .. index .. "]."
        local guild_id = read_property(
            options.adapter,
            object,
            descriptors.guild_id_property,
            "CGCE-GUILD-PROJECTION",
            field_prefix .. "guild_id",
            "guild ID projection failed"
        )
        if not valid_json_string(guild_id, false) then
            fail(
                "CGCE-GUILD-PROJECTION",
                field_prefix .. "guild_id",
                "guild ID must be a nonempty JSON-safe string"
            )
        end

        local guild_name = read_property(
            options.adapter,
            object,
            descriptors.guild_name_property,
            "CGCE-GUILD-PROJECTION",
            field_prefix .. "guild_name",
            "guild name projection failed"
        )
        if not valid_json_string(guild_name, true) then
            fail(
                "CGCE-GUILD-PROJECTION",
                field_prefix .. "guild_name",
                "guild name must be a JSON-safe string"
            )
        end

        local chest_container_id = read_property(
            options.adapter,
            object,
            descriptors.guild_chest_container_id_property,
            "CGCE-GUILD-PROJECTION",
            field_prefix .. "chest_container_id",
            "guild chest container ID projection failed"
        )
        if chest_container_id == json_null then
            chest_container_id = nil
        elseif not valid_json_string(chest_container_id, false) then
            fail(
                "CGCE-GUILD-PROJECTION",
                field_prefix .. "chest_container_id",
                "guild chest container ID must be null or a nonempty JSON-safe string"
            )
        end

        entries[index] = {
            object = object,
            guild_id = guild_id,
            guild_name = guild_name,
            chest_container_id = chest_container_id,
        }
    end

    return {
        selected_world = selected_world,
        guild_manager = guild_manager,
        world_id = observed_world_id,
        entries = entries,
    }
end

local function require_stable(options, before, after)
    if before.world_id ~= after.world_id
        or not same_object(options.adapter, before.selected_world, after.selected_world)
        or not same_object(options.adapter, before.guild_manager, after.guild_manager) then
        fail(
            "CGCE-GUILD-DRIFT",
            "relation",
            "selected-world guild relation changed during traversal"
        )
    end
    if #before.entries ~= #after.entries then
        fail("CGCE-GUILD-DRIFT", "guild_list", "current-world guild list changed during traversal")
    end
    for index, left in ipairs(before.entries) do
        local right = after.entries[index]
        if not same_object(options.adapter, left.object, right.object) then
            fail("CGCE-GUILD-DRIFT", "guild_list", "current-world guild list changed during traversal")
        end
        for _, field in ipairs({ "guild_id", "guild_name", "chest_container_id" }) do
            if left[field] ~= right[field] then
                fail(
                    "CGCE-GUILD-DRIFT",
                    "guilds[" .. index .. "]." .. field,
                    "guild projection changed during traversal"
                )
            end
        end
    end
end

local function detached_projection(entries)
    local seen_ids = {}
    local result = json_array()
    for _, entry in ipairs(entries) do
        if seen_ids[entry.guild_id] then
            fail("CGCE-GUILD-DUPLICATE-ID", "guild_id", "current-world guild IDs must be unique")
        end
        seen_ids[entry.guild_id] = true
        local record = {
            guild_id = entry.guild_id,
            guild_name = entry.guild_name,
        }
        if entry.chest_container_id ~= nil then
            record.chest_container_id = entry.chest_container_id
        end
        result[#result + 1] = record
    end
    table.sort(result, function(left, right)
        return left.guild_id < right.guild_id
    end)
    return result
end

function guild_repository.list(options)
    local captured = capture_options(options)
    world_assert_current(
        captured.world_epoch,
        captured.adapter,
        captured.binding_session
    )

    local capabilities = adapter_capabilities(captured.adapter)
    if not validate_read_only_capabilities(capabilities) then
        fail("CGCE-GUILD-AUTHORITY", "adapter", "adapter is not an exact read-only authority")
    end

    local expected_world_id = world_id(captured.world_epoch)
    local descriptors = descriptor_snapshot(captured.binding_session)
    local before = collect(captured, descriptors, expected_world_id)
    world_assert_relation(
        captured.world_epoch,
        captured.adapter,
        captured.binding_session,
        "guild_manager",
        before.selected_world,
        before.guild_manager
    )
    local after = collect(captured, descriptors, expected_world_id)
    world_assert_relation(
        captured.world_epoch,
        captured.adapter,
        captured.binding_session,
        "guild_manager",
        after.selected_world,
        after.guild_manager
    )
    require_stable(captured, before, after)
    local verified = collect(captured, descriptors, expected_world_id)
    world_assert_relation(
        captured.world_epoch,
        captured.adapter,
        captured.binding_session,
        "guild_manager",
        verified.selected_world,
        verified.guild_manager
    )
    require_stable(captured, after, verified)
    local result = detached_projection(verified.entries)

    world_assert_current(
        captured.world_epoch,
        captured.adapter,
        captured.binding_session
    )
    return result
end

return guild_repository
