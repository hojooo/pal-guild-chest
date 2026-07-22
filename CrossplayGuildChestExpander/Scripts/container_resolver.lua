local json = require("CrossplayGuildChestExpander.Scripts.json")
local revision_guard = require("CrossplayGuildChestExpander.Scripts.revision_guard")
local ue4ss_adapter = require("CrossplayGuildChestExpander.Scripts.ue4ss_adapter")
local world_ready = require("CrossplayGuildChestExpander.Scripts.world_ready")

local container_resolver = {}

local adapter_capabilities = ue4ss_adapter.capabilities
local adapter_inventory_loaded = ue4ss_adapter.inventory_loaded
local adapter_read_property = ue4ss_adapter.read_property
local adapter_resolve_exact = ue4ss_adapter.resolve_exact
local adapter_same_object = ue4ss_adapter.same_object
local binding_descriptor = revision_guard.descriptor
local json_encode = json.encode
local json_null = json.null
local world_assert_current = world_ready.assert_current
local world_assert_relation = world_ready.assert_relation

local descriptor_names = {
    "selected_world_class",
    "selected_world_container_manager_property",
    "container_manager_class",
    "guild_chest_class",
    "guild_chest_container_manager_property",
    "container_id_property",
    "container_owner_guild_id_property",
}

local resolver_problem_codes = {
    ["CGCE-CRES-INPUT"] = true,
    ["CGCE-CRES-AUTHORITY"] = true,
    ["CGCE-CRES-WORLD-CARDINALITY"] = true,
    ["CGCE-CRES-MANAGER-RELATION"] = true,
    ["CGCE-CRES-ID-PROJECTION"] = true,
    ["CGCE-CRES-ID-AMBIGUOUS"] = true,
    ["CGCE-CRES-WORLD-MISMATCH"] = true,
    ["CGCE-CRES-OWNER-PROJECTION"] = true,
    ["CGCE-CRES-OWNER-MISMATCH"] = true,
    ["CGCE-CRES-RELATION-CHANGED"] = true,
    ["CGCE-CRES-TOKEN"] = true,
}

local token_records = setmetatable({}, { __mode = "k" })

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

local function valid_json_string(value)
    if type(value) ~= "string" or #value == 0 then
        return false
    end
    local ok, encoded = pcall(json_encode, value)
    return ok and type(encoded) == "string" and encoded:sub(1, 1) == '"'
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

local function validate_read_only_capabilities(value)
    return type(value) == "table"
        and getmetatable(value) == nil
        and rawget(value, "mutation_capability") == false
        and rawget(value, "function_invoke_capability") == false
        and rawget(value, "raw_property_write_capability") == false
        and rawget(value, "tarray_write_capability") == false
end

local function assert_world_current(adapter, binding_session, world_epoch)
    local values = table.pack(pcall(
        world_assert_current,
        world_epoch,
        adapter,
        binding_session
    ))
    if not values[1] or values.n ~= 2 or values[2] ~= true then
        fail(
            "CGCE-CRES-AUTHORITY",
            "world_epoch",
            "active world epoch validation failed"
        )
    end
end

local function assert_world_relation(
    adapter,
    binding_session,
    world_epoch,
    selected_world,
    container_manager
)
    local values = table.pack(pcall(
        world_assert_relation,
        world_epoch,
        adapter,
        binding_session,
        "container_manager",
        selected_world,
        container_manager
    ))
    if not values[1] or values.n ~= 2 or values[2] ~= true then
        fail(
            "CGCE-CRES-AUTHORITY",
            "relation",
            "container-manager relation does not match the active world epoch"
        )
    end
end

local function assert_read_only_authority(adapter)
    local values = table.pack(pcall(adapter_capabilities, adapter))
    if values.n ~= 2
        or not values[1]
        or not validate_read_only_capabilities(values[2]) then
        fail(
            "CGCE-CRES-AUTHORITY",
            "adapter",
            "adapter is not an exact read-only authority"
        )
    end
end

local function descriptor_snapshot(binding_session)
    local descriptors = {}
    for _, logical_name in ipairs(descriptor_names) do
        local values = table.pack(pcall(binding_descriptor, binding_session, logical_name))
        if values.n ~= 2 or not values[1] or type(values[2]) ~= "table" then
            fail(
                "CGCE-CRES-AUTHORITY",
                "binding_session",
                "verified resolver binding is unavailable"
            )
        end
        descriptors[logical_name] = values[2]
    end
    return descriptors
end

local function resolve_class(adapter, descriptor, code, field, detail)
    local values = table.pack(pcall(adapter_resolve_exact, adapter, descriptor))
    if values.n ~= 3
        or not values[1]
        or type(values[2]) ~= "function"
        or values[3] ~= "MATCHED" then
        fail(code, field, detail)
    end
    return values[2]
end

local function inventory(adapter, class, code, field, detail)
    local values = table.pack(pcall(adapter_inventory_loaded, adapter, class))
    if values.n ~= 3 or not values[1] or dense_length(values[2]) == nil then
        fail(code, field, detail)
    end
    local count = #values[2]
    if (count == 0 and values[3] ~= "NOT_LOADED")
        or (count > 0 and values[3] ~= "LOADED") then
        fail(code, field, detail)
    end
    return values[2]
end

local function read_property(adapter, object, descriptor, code, field, detail)
    local values = table.pack(pcall(adapter_read_property, adapter, object, descriptor))
    if values.n ~= 2 or not values[1] then
        fail(code, field, detail)
    end
    return values[2]
end

local function same_object(adapter, left, right, code, field, detail)
    local values = table.pack(pcall(adapter_same_object, adapter, left, right))
    if values.n ~= 2 or not values[1] or type(values[2]) ~= "boolean" then
        fail(code, field, detail)
    end
    return values[2]
end

local function exact_match_count(adapter, reference, values, code, field, detail)
    if type(reference) ~= "function" then
        return nil
    end
    local count = 0
    for _, candidate in ipairs(values) do
        if same_object(adapter, reference, candidate, code, field, detail) then
            count = count + 1
        end
    end
    return count
end

local function observe(adapter, binding_session, world_epoch, descriptors, container_id)
    local selected_world_class = resolve_class(
        adapter,
        descriptors.selected_world_class,
        "CGCE-CRES-AUTHORITY",
        "selected_world_class",
        "exact selected-world class is unavailable"
    )
    local selected_worlds = inventory(
        adapter,
        selected_world_class,
        "CGCE-CRES-AUTHORITY",
        "selected_world",
        "exact selected-world inventory is unavailable"
    )
    if #selected_worlds ~= 1 then
        fail(
            "CGCE-CRES-WORLD-CARDINALITY",
            "selected_world",
            "exactly one selected-world instance is required"
        )
    end
    local selected_world = selected_worlds[1]

    local container_manager = read_property(
        adapter,
        selected_world,
        descriptors.selected_world_container_manager_property,
        "CGCE-CRES-MANAGER-RELATION",
        "container_manager",
        "selected-world container-manager projection failed"
    )
    local container_manager_class = resolve_class(
        adapter,
        descriptors.container_manager_class,
        "CGCE-CRES-MANAGER-RELATION",
        "container_manager",
        "exact container-manager class is unavailable"
    )
    local container_managers = inventory(
        adapter,
        container_manager_class,
        "CGCE-CRES-MANAGER-RELATION",
        "container_manager",
        "exact container-manager inventory is unavailable"
    )
    if container_manager == json_null
        or exact_match_count(
            adapter,
            container_manager,
            container_managers,
            "CGCE-CRES-MANAGER-RELATION",
            "container_manager",
            "container-manager identity comparison failed"
        ) ~= 1 then
        fail(
            "CGCE-CRES-MANAGER-RELATION",
            "container_manager",
            "selected-world container manager must match exact class inventory once"
        )
    end

    local guild_chest_class = resolve_class(
        adapter,
        descriptors.guild_chest_class,
        "CGCE-CRES-AUTHORITY",
        "guild_chest_class",
        "exact guild-chest class is unavailable"
    )
    local guild_chests = inventory(
        adapter,
        guild_chest_class,
        "CGCE-CRES-AUTHORITY",
        "guild_chest_class",
        "exact guild-chest inventory is unavailable"
    )

    local matched = {}
    for _, candidate in ipairs(guild_chests) do
        local observed_id = read_property(
            adapter,
            candidate,
            descriptors.container_id_property,
            "CGCE-CRES-ID-PROJECTION",
            "container_id",
            "guild-chest container ID projection failed"
        )
        if observed_id ~= json_null then
            if not valid_json_string(observed_id) then
                fail(
                    "CGCE-CRES-ID-PROJECTION",
                    "container_id",
                    "guild-chest container ID must be null or a nonempty JSON-safe string"
                )
            end
            if observed_id == container_id then
                matched[#matched + 1] = candidate
            end
        end
    end

    if #matched > 1 then
        fail(
            "CGCE-CRES-ID-AMBIGUOUS",
            "container_id",
            "container ID matches multiple exact guild-chest instances"
        )
    end

    local candidate
    local owner_guild_id
    if #matched == 1 then
        candidate = matched[1]
        local candidate_manager = read_property(
            adapter,
            candidate,
            descriptors.guild_chest_container_manager_property,
            "CGCE-CRES-WORLD-MISMATCH",
            "container_manager",
            "guild-chest container-manager projection failed"
        )
        if candidate_manager == json_null
            or type(candidate_manager) ~= "function"
            or not same_object(
                adapter,
                candidate_manager,
                container_manager,
                "CGCE-CRES-WORLD-MISMATCH",
                "container_manager",
                "guild-chest manager identity comparison failed"
            ) then
            fail(
                "CGCE-CRES-WORLD-MISMATCH",
                "container_manager",
                "guild chest does not belong to the active world's container manager"
            )
        end

        owner_guild_id = read_property(
            adapter,
            candidate,
            descriptors.container_owner_guild_id_property,
            "CGCE-CRES-OWNER-PROJECTION",
            "owner_guild_id",
            "guild-chest owner projection failed"
        )
        if not valid_json_string(owner_guild_id) then
            fail(
                "CGCE-CRES-OWNER-PROJECTION",
                "owner_guild_id",
                "guild-chest owner must be a nonempty JSON-safe string"
            )
        end
    end

    assert_world_relation(
        adapter,
        binding_session,
        world_epoch,
        selected_world,
        container_manager
    )
    return {
        selected_world = selected_world,
        container_manager = container_manager,
        match_count = #matched,
        candidate = candidate,
        owner_guild_id = owner_guild_id,
    }
end

local function require_stable(adapter, before, after)
    if before.match_count ~= after.match_count then
        fail(
            "CGCE-CRES-RELATION-CHANGED",
            "container_id",
            "guild-chest match count changed during resolution"
        )
    end
    if not same_object(
        adapter,
        before.selected_world,
        after.selected_world,
        "CGCE-CRES-RELATION-CHANGED",
        "selected_world",
        "selected-world identity comparison failed"
    ) or not same_object(
        adapter,
        before.container_manager,
        after.container_manager,
        "CGCE-CRES-RELATION-CHANGED",
        "container_manager",
        "container-manager identity comparison failed"
    ) then
        fail(
            "CGCE-CRES-RELATION-CHANGED",
            "relation",
            "selected-world container relation changed during resolution"
        )
    end
    if before.match_count == 0 then
        return
    end
    if not same_object(
        adapter,
        before.candidate,
        after.candidate,
        "CGCE-CRES-RELATION-CHANGED",
        "container",
        "guild-chest identity comparison failed"
    ) then
        fail(
            "CGCE-CRES-RELATION-CHANGED",
            "container",
            "resolved guild-chest identity changed during resolution"
        )
    end
    if before.owner_guild_id ~= after.owner_guild_id then
        fail(
            "CGCE-CRES-RELATION-CHANGED",
            "owner_guild_id",
            "guild-chest owner changed during resolution"
        )
    end
end

local function stable_observation(adapter, binding_session, world_epoch, container_id)
    assert_world_current(adapter, binding_session, world_epoch)
    assert_read_only_authority(adapter)
    local descriptors = descriptor_snapshot(binding_session)
    local before = observe(
        adapter,
        binding_session,
        world_epoch,
        descriptors,
        container_id
    )
    local after = observe(
        adapter,
        binding_session,
        world_epoch,
        descriptors,
        container_id
    )
    require_stable(adapter, before, after)
    local verified = observe(
        adapter,
        binding_session,
        world_epoch,
        descriptors,
        container_id
    )
    require_stable(adapter, after, verified)
    assert_world_current(adapter, binding_session, world_epoch)
    return verified
end

local function trusted_problem(value)
    if type(value) ~= "table"
        or not resolver_problem_codes[rawget(value, "code")]
        or type(rawget(value, "field")) ~= "string"
        or type(rawget(value, "detail")) ~= "string" then
        return nil
    end
    return problem(
        rawget(value, "code"),
        rawget(value, "field"),
        rawget(value, "detail")
    )
end

local function make_token(record)
    local token = function() end
    token_records[token] = record
    return token
end

local function revoke(record)
    if not record.revoked then
        record.generation = function() end
    end
    record.revoked = true
    record.validation_in_progress = false
end

function container_resolver.resolve(
    adapter,
    binding_session,
    world_epoch,
    guild_id,
    container_id
)
    if container_id == nil or container_id == json_null then
        return nil
    end
    if not valid_json_string(guild_id) then
        fail(
            "CGCE-CRES-INPUT",
            "guild_id",
            "guild ID must be a nonempty JSON-safe string"
        )
    end
    if not valid_json_string(container_id) then
        fail(
            "CGCE-CRES-INPUT",
            "container_id",
            "container ID must be a nonempty JSON-safe string"
        )
    end

    local observed = stable_observation(
        adapter,
        binding_session,
        world_epoch,
        container_id
    )
    if observed.match_count == 0 then
        return nil
    end

    local authorized = observed.owner_guild_id == guild_id
    local token = make_token({
        adapter = adapter,
        binding_session = binding_session,
        world_epoch = world_epoch,
        guild_id = guild_id,
        container_id = container_id,
        owner_guild_id = observed.owner_guild_id,
        candidate = observed.candidate,
        authorized = authorized,
        revoked = false,
        validation_in_progress = false,
        generation = function() end,
    })
    return {
        container_id = container_id,
        owner_guild_id = observed.owner_guild_id,
        is_guild_chest = true,
        container = token,
    }
end

function container_resolver.assert_current(
    token,
    adapter,
    binding_session,
    world_epoch
)
    local record = token_records[token]
    if record == nil or record.revoked then
        fail(
            "CGCE-CRES-TOKEN",
            "container",
            "container token is invalid or revoked"
        )
    end
    if record.validation_in_progress then
        revoke(record)
        fail(
            "CGCE-CRES-TOKEN",
            "container",
            "reentrant container token validation is forbidden"
        )
    end
    if not rawequal(record.adapter, adapter) then
        revoke(record)
        fail("CGCE-CRES-TOKEN", "adapter", "container token adapter authority does not match")
    end
    if not rawequal(record.binding_session, binding_session) then
        revoke(record)
        fail(
            "CGCE-CRES-TOKEN",
            "binding_session",
            "container token binding authority does not match"
        )
    end
    if not rawequal(record.world_epoch, world_epoch) then
        revoke(record)
        fail("CGCE-CRES-TOKEN", "world_epoch", "container token world epoch does not match")
    end
    if not record.authorized then
        revoke(record)
        fail(
            "CGCE-CRES-OWNER-MISMATCH",
            "owner_guild_id",
            "container token owner does not match the requested guild"
        )
    end

    local validation_generation = record.generation
    record.validation_in_progress = true
    local values = table.pack(pcall(function()
        local observed = stable_observation(
            adapter,
            binding_session,
            world_epoch,
            record.container_id
        )
        if observed.match_count ~= 1 then
            fail(
                "CGCE-CRES-RELATION-CHANGED",
                "container_id",
                "resolved guild chest is no longer unique and loaded"
            )
        end
        if not same_object(
            adapter,
            record.candidate,
            observed.candidate,
            "CGCE-CRES-RELATION-CHANGED",
            "container",
            "resolved guild-chest identity comparison failed"
        ) then
            fail(
                "CGCE-CRES-RELATION-CHANGED",
                "container",
                "resolved guild-chest identity changed"
            )
        end
        if observed.owner_guild_id ~= record.owner_guild_id
            or observed.owner_guild_id ~= record.guild_id then
            fail(
                "CGCE-CRES-RELATION-CHANGED",
                "owner_guild_id",
                "resolved guild-chest owner changed"
            )
        end
        return true
    end))
    local validation_owned = record.validation_in_progress == true
    record.validation_in_progress = false

    if not values[1] or values.n ~= 2 or values[2] ~= true then
        revoke(record)
        local err = trusted_problem(values[2])
        if err ~= nil and err.code ~= "CGCE-CRES-AUTHORITY" then
            error(err, 0)
        end
        fail(
            "CGCE-CRES-TOKEN",
            "world_epoch",
            "container token could not be revalidated against its active world epoch"
        )
    end
    if not validation_owned
        or record.validation_in_progress
        or record.revoked
        or not rawequal(record.generation, validation_generation) then
        revoke(record)
        fail(
            "CGCE-CRES-TOKEN",
            "container",
            "container token validation fence was invalidated"
        )
    end
    return true
end

return container_resolver
