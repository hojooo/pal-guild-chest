local json = require("CrossplayGuildChestExpander.Scripts.json")
local revision_guard = require("CrossplayGuildChestExpander.Scripts.revision_guard")
local scheduler = require("CrossplayGuildChestExpander.Scripts.scheduler")
local ue4ss_adapter = require("CrossplayGuildChestExpander.Scripts.ue4ss_adapter")

local world_ready = {}

local adapter_capabilities = ue4ss_adapter.capabilities
local adapter_close_observation = ue4ss_adapter.close_observation
local adapter_inventory_loaded = ue4ss_adapter.inventory_loaded
local adapter_observe_function = ue4ss_adapter.observe_function
local adapter_read_property = ue4ss_adapter.read_property
local adapter_resolve_exact = ue4ss_adapter.resolve_exact
local adapter_same_object = ue4ss_adapter.same_object
local binding_metadata = revision_guard.binding_metadata
local binding_descriptor = revision_guard.descriptor
local json_array = json.array
local json_encode = json.encode
local json_null = json.null
local scheduler_cancel = scheduler.cancel
local scheduler_retry = scheduler.retry
local scheduler_status = scheduler.status
local scheduler_wake = scheduler.wake

local MAX_ATTEMPTS = 60
local DELAY_SECONDS = 1

local option_fields = {
    adapter = true,
    binding_session = true,
    schedule = true,
    cancel = true,
}

local option_field_order = {
    "adapter",
    "binding_session",
    "schedule",
    "cancel",
}

local relation_descriptor_names = {
    "selected_world_class",
    "world_ready_state_property",
    "world_id_property",
    "selected_world_guild_manager_property",
    "selected_world_container_manager_property",
    "guild_manager_class",
    "container_manager_class",
}

local detector_records = setmetatable({}, { __mode = "k" })
local epoch_records = setmetatable({}, { __mode = "k" })
local validate_epoch

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
        fail("CGCE-WORLD-OPTIONS", "options", "world readiness options must be a plain table")
    end
    local unknown = sorted_unknown_key(options, option_fields)
    if unknown == false then
        fail("CGCE-WORLD-OPTIONS", "options", "world readiness option keys must be strings")
    end
    if unknown ~= nil then
        fail("CGCE-WORLD-OPTIONS", unknown, "unknown world readiness option")
    end

    local captured = {}
    for _, field in ipairs(option_field_order) do
        local value = rawget(options, field)
        if value == nil then
            fail("CGCE-WORLD-OPTIONS", field, "required world readiness option is missing")
        end
        captured[field] = value
    end
    if type(captured.schedule) ~= "function" then
        fail("CGCE-WORLD-OPTIONS", "schedule", "schedule must be a function")
    end
    if type(captured.cancel) ~= "function" then
        fail("CGCE-WORLD-OPTIONS", "cancel", "cancel must be a function")
    end
    return captured
end

local function copy_errors(errors)
    local result = json_array()
    for index, item in ipairs(errors) do
        result[index] = {
            code = item.code,
            field = item.field,
            detail = item.detail,
        }
    end
    return result
end

local function same_problem(left, right)
    return left.code == right.code
        and left.field == right.field
        and left.detail == right.detail
end

local function record_problem(record, value)
    for _, existing in ipairs(record.errors) do
        if same_problem(existing, value) then
            return
        end
    end
    record.errors[#record.errors + 1] = value
end

local function require_detector(handle)
    local record = detector_records[handle]
    if record == nil then
        fail("CGCE-WORLD-DETECTOR", "detector", "world readiness detector handle is invalid")
    end
    return record
end

local function metadata_equal(left, right)
    return type(left) == "table"
        and left.game_revision == right.game_revision
        and left.manifest_checksum == right.manifest_checksum
        and left.source_audit_checksum == right.source_audit_checksum
        and left.manifest_kind == right.manifest_kind
end

local function validate_read_only_capabilities(value)
    return type(value) == "table"
        and value.mutation_capability == false
        and value.function_invoke_capability == false
        and value.raw_property_write_capability == false
        and value.tarray_write_capability == false
end

local function valid_world_id(value)
    if type(value) ~= "string" or #value == 0 then
        return false
    end
    local ok, encoded = pcall(json_encode, value)
    return ok and type(encoded) == "string" and encoded:sub(1, 1) == '"'
end

local function exact_match_count(adapter, reference, inventory)
    if type(reference) ~= "function" then
        return nil
    end
    local count = 0
    for _, candidate in ipairs(inventory) do
        if adapter_same_object(adapter, reference, candidate) then
            count = count + 1
        end
    end
    return count
end

local function inspect_relation(record)
    local current_metadata = binding_metadata(record.binding_session)
    if not metadata_equal(current_metadata, record.binding_metadata) then
        return "BLOCKED", nil, problem(
            "CGCE-WORLD-AUTHORITY",
            "binding_session",
            "verified binding metadata changed"
        )
    end

    local capabilities = adapter_capabilities(record.adapter)
    if not validate_read_only_capabilities(capabilities) then
        return "BLOCKED", nil, problem(
            "CGCE-WORLD-AUTHORITY",
            "adapter",
            "adapter is not an exact read-only authority"
        )
    end

    local descriptors = {}
    for _, logical_name in ipairs(relation_descriptor_names) do
        descriptors[logical_name] = binding_descriptor(record.binding_session, logical_name)
    end

    local selected_world_class, selected_class_status = adapter_resolve_exact(
        record.adapter,
        descriptors.selected_world_class
    )
    if selected_world_class == nil or selected_class_status ~= "MATCHED" then
        return "BLOCKED", nil, problem(
            "CGCE-WORLD-AUTHORITY",
            "selected_world_class",
            "exact selected-world class is unavailable"
        )
    end

    local selected_worlds = adapter_inventory_loaded(record.adapter, selected_world_class)
    if #selected_worlds == 0 then
        return "PENDING", nil, nil
    end
    if #selected_worlds ~= 1 then
        return "BLOCKED", nil, problem(
            "CGCE-WORLD-SELECTED-CARDINALITY",
            "selected_world",
            "exactly one selected-world instance is required"
        )
    end

    local selected_world = selected_worlds[1]
    local ready = adapter_read_property(
        record.adapter,
        selected_world,
        descriptors.world_ready_state_property
    )
    if ready == false then
        return "PENDING", nil, nil
    end
    if ready ~= true then
        return "BLOCKED", nil, problem(
            "CGCE-WORLD-READY-STATE",
            "world_ready_state",
            "world readiness state must be an exact boolean"
        )
    end

    local world_id = adapter_read_property(
        record.adapter,
        selected_world,
        descriptors.world_id_property
    )
    if not valid_world_id(world_id) then
        return "BLOCKED", nil, problem(
            "CGCE-WORLD-ID",
            "world_id",
            "selected-world ID must be a nonempty JSON-safe string"
        )
    end

    local guild_manager = adapter_read_property(
        record.adapter,
        selected_world,
        descriptors.selected_world_guild_manager_property
    )
    local guild_manager_class, guild_class_status = adapter_resolve_exact(
        record.adapter,
        descriptors.guild_manager_class
    )
    if guild_manager_class == nil or guild_class_status ~= "MATCHED" then
        return "BLOCKED", nil, problem(
            "CGCE-WORLD-AUTHORITY",
            "guild_manager_class",
            "exact guild-manager class is unavailable"
        )
    end
    local guild_inventory, guild_inventory_status = adapter_inventory_loaded(
        record.adapter,
        guild_manager_class
    )
    if guild_manager == json_null
        or guild_inventory_status == "NOT_LOADED"
        or #guild_inventory == 0 then
        return "PENDING", nil, nil
    end
    if exact_match_count(record.adapter, guild_manager, guild_inventory) ~= 1 then
        return "BLOCKED", nil, problem(
            "CGCE-WORLD-GUILD-MANAGER-RELATION",
            "guild_manager",
            "selected-world guild-manager reference must match exact class inventory once"
        )
    end

    local container_manager = adapter_read_property(
        record.adapter,
        selected_world,
        descriptors.selected_world_container_manager_property
    )
    local container_manager_class, container_class_status = adapter_resolve_exact(
        record.adapter,
        descriptors.container_manager_class
    )
    if container_manager_class == nil or container_class_status ~= "MATCHED" then
        return "BLOCKED", nil, problem(
            "CGCE-WORLD-AUTHORITY",
            "container_manager_class",
            "exact container-manager class is unavailable"
        )
    end
    local container_inventory, container_inventory_status = adapter_inventory_loaded(
        record.adapter,
        container_manager_class
    )
    if container_manager == json_null
        or container_inventory_status == "NOT_LOADED"
        or #container_inventory == 0 then
        return "PENDING", nil, nil
    end
    if exact_match_count(record.adapter, container_manager, container_inventory) ~= 1 then
        return "BLOCKED", nil, problem(
            "CGCE-WORLD-CONTAINER-MANAGER-RELATION",
            "container_manager",
            "selected-world container-manager reference must match exact class inventory once"
        )
    end

    local final_selected_worlds = adapter_inventory_loaded(record.adapter, selected_world_class)
    if #final_selected_worlds == 0 then
        return "PENDING", nil, nil
    end
    if #final_selected_worlds ~= 1
        or not adapter_same_object(record.adapter, selected_world, final_selected_worlds[1]) then
        return "BLOCKED", nil, problem(
            "CGCE-WORLD-RELATION-CHANGED",
            "selected_world",
            "selected-world identity changed during relation inspection"
        )
    end

    local final_guild_inventory, final_guild_inventory_status = adapter_inventory_loaded(
        record.adapter,
        guild_manager_class
    )
    local final_container_inventory, final_container_inventory_status = adapter_inventory_loaded(
        record.adapter,
        container_manager_class
    )
    local final_ready = adapter_read_property(
        record.adapter,
        selected_world,
        descriptors.world_ready_state_property
    )
    local final_world_id = adapter_read_property(
        record.adapter,
        selected_world,
        descriptors.world_id_property
    )
    local final_guild_manager = adapter_read_property(
        record.adapter,
        selected_world,
        descriptors.selected_world_guild_manager_property
    )
    local final_container_manager = adapter_read_property(
        record.adapter,
        selected_world,
        descriptors.selected_world_container_manager_property
    )

    if final_ready == false
        or final_guild_manager == json_null
        or final_container_manager == json_null
        or final_guild_inventory_status == "NOT_LOADED"
        or final_container_inventory_status == "NOT_LOADED"
        or #final_guild_inventory == 0
        or #final_container_inventory == 0 then
        return "PENDING", nil, nil
    end
    if final_ready ~= true then
        return "BLOCKED", nil, problem(
            "CGCE-WORLD-READY-STATE",
            "world_ready_state",
            "world readiness state must remain an exact boolean"
        )
    end
    if not valid_world_id(final_world_id) then
        return "BLOCKED", nil, problem(
            "CGCE-WORLD-ID",
            "world_id",
            "selected-world ID must remain a nonempty JSON-safe string"
        )
    end
    if final_world_id ~= world_id
        or not adapter_same_object(record.adapter, guild_manager, final_guild_manager)
        or not adapter_same_object(record.adapter, container_manager, final_container_manager) then
        return "BLOCKED", nil, problem(
            "CGCE-WORLD-RELATION-CHANGED",
            "relation",
            "selected-world relation changed during relation inspection"
        )
    end
    if exact_match_count(record.adapter, final_guild_manager, final_guild_inventory) ~= 1 then
        return "BLOCKED", nil, problem(
            "CGCE-WORLD-GUILD-MANAGER-RELATION",
            "guild_manager",
            "selected-world guild-manager relation changed during inspection"
        )
    end
    if exact_match_count(record.adapter, final_container_manager, final_container_inventory) ~= 1 then
        return "BLOCKED", nil, problem(
            "CGCE-WORLD-CONTAINER-MANAGER-RELATION",
            "container_manager",
            "selected-world container-manager relation changed during inspection"
        )
    end

    local final_metadata = binding_metadata(record.binding_session)
    if not metadata_equal(final_metadata, record.binding_metadata) then
        return "BLOCKED", nil, problem(
            "CGCE-WORLD-AUTHORITY",
            "binding_session",
            "verified binding authority changed during relation inspection"
        )
    end

    return "READY", {
        selected_world = selected_world,
        guild_manager = guild_manager,
        container_manager = container_manager,
        world_id = world_id,
    }, nil
end

local function safe_inspect_relation(record)
    local values = table.pack(pcall(inspect_relation, record))
    if not values[1] or values.n ~= 4 then
        return "BLOCKED", nil, problem(
            "CGCE-WORLD-AUTHORITY",
            "relation",
            "selected-world relation inspection failed"
        )
    end
    return values[2], values[3], values[4]
end

local function invalidate_epoch(record)
    record.generation = record.generation + 1
    record.epoch = nil
end

local function mark_blocked(record, value)
    if record.state ~= "BLOCKED" then
        invalidate_epoch(record)
    end
    record.state = "BLOCKED"
    record_problem(record, value)
end

local function mark_cleanup_failed(record, value)
    record.cleanup_failed = true
    mark_blocked(record, value)
end

local function cleanup_observation(record)
    if record.observation == nil or record.observation_cleanup_attempted then
        return true
    end
    record.observation_cleanup_attempted = true
    local values = table.pack(pcall(
        adapter_close_observation,
        record.adapter,
        record.observation
    ))
    if not values[1]
        or values.n > 3
        or values[2] ~= true
        or values[3] == nil then
        mark_cleanup_failed(record, problem(
            "CGCE-WORLD-HOOK-CLEANUP",
            "observation",
            "world-ready hook cleanup failed"
        ))
        return false
    end
    return true
end

local function cleanup_timer(record)
    if record.controller == nil or record.timer_cleanup_attempted then
        return true
    end
    record.timer_cleanup_attempted = true

    local before_values = table.pack(pcall(scheduler_status, record.controller))
    if not before_values[1]
        or before_values.n > 3
        or before_values[2] == nil
        or before_values[3] ~= nil then
        mark_cleanup_failed(record, problem(
            "CGCE-WORLD-TIMER-CLEANUP",
            "timer",
            "world-ready timer state inspection failed"
        ))
        return false
    end
    if before_values[2].state ~= "PENDING" then
        return true
    end

    local cancel_values = table.pack(pcall(scheduler_cancel, record.controller))
    if not cancel_values[1]
        or cancel_values.n > 3
        or cancel_values[2] == nil
        or cancel_values[3] ~= nil
        or cancel_values[2].state ~= "CANCELLED" then
        mark_cleanup_failed(record, problem(
            "CGCE-WORLD-TIMER-CLEANUP",
            "timer",
            "world-ready timer cancellation failed"
        ))
        return false
    end
    return true
end

local function block_and_cleanup_observation(record, value)
    mark_blocked(record, value)
    cleanup_observation(record)
end

local function create_epoch(record, relation)
    local handle = function() end
    epoch_records[handle] = {
        detector = record.handle,
        detector_generation = record.generation,
        adapter = record.adapter,
        binding_session = record.binding_session,
        selected_world = relation.selected_world,
        guild_manager = relation.guild_manager,
        container_manager = relation.container_manager,
        world_id = relation.world_id,
    }
    record.epoch = handle
    return handle
end

local function same_relation(adapter, left, right)
    if left == nil or right == nil or left.world_id ~= right.world_id then
        return false
    end
    local values = table.pack(pcall(function()
        return adapter_same_object(
            adapter,
            left.selected_world,
            right.selected_world
        ) and adapter_same_object(
            adapter,
            left.guild_manager,
            right.guild_manager
        ) and adapter_same_object(
            adapter,
            left.container_manager,
            right.container_manager
        )
    end))
    return values[1] and values.n == 2 and values[2] == true
end

local function scheduler_terminal(record, snapshot)
    if record.close_requested then
        return
    end
    if record.state ~= "PENDING" then
        return
    end

    if snapshot.state == "READY"
        and snapshot.result ~= nil
        and snapshot.result.outcome == "READY"
        and record.probe_relation ~= nil then
        record.state = "READY"
        create_epoch(record, record.probe_relation)
        return
    end

    if snapshot.state == "READY"
        and snapshot.result ~= nil
        and snapshot.result.outcome == "BLOCKED"
        and record.probe_problem ~= nil then
        block_and_cleanup_observation(record, record.probe_problem)
        return
    end

    if snapshot.state == "EXHAUSTED" then
        block_and_cleanup_observation(record, problem(
            "CGCE-WORLD-TIMEOUT",
            "world_ready",
            "world readiness did not become authoritative within sixty attempts"
        ))
        return
    end

    block_and_cleanup_observation(record, problem(
        "CGCE-WORLD-SCHEDULER",
        "scheduler",
        "bounded world readiness scheduler failed"
    ))
end

local function wake_pending(record)
    if record.state ~= "PENDING" or record.controller == nil then
        return
    end
    local values = table.pack(pcall(scheduler_wake, record.controller))
    if not values[1]
        or values.n > 3
        or values[2] == nil
        or values[3] ~= nil then
        block_and_cleanup_observation(record, problem(
            "CGCE-WORLD-SCHEDULER",
            "scheduler",
            "world-ready wake failed"
        ))
    end
end

function world_ready.start(options)
    local ports = capture_options(options)
    local capabilities = adapter_capabilities(ports.adapter)
    if not validate_read_only_capabilities(capabilities) then
        fail("CGCE-WORLD-OPTIONS", "adapter", "adapter must be exact and read-only")
    end
    local metadata = binding_metadata(ports.binding_session)

    local detector = function() end
    local record = {
        handle = detector,
        adapter = ports.adapter,
        binding_session = ports.binding_session,
        binding_metadata = {
            game_revision = metadata.game_revision,
            manifest_checksum = metadata.manifest_checksum,
            source_audit_checksum = metadata.source_audit_checksum,
            manifest_kind = metadata.manifest_kind,
        },
        generation = 1,
        state = "PENDING",
        errors = {},
        cleanup_failed = false,
        close_requested = false,
        observation_cleanup_attempted = false,
        timer_cleanup_attempted = false,
        observed_event_epoch = function() end,
    }
    detector_records[detector] = record

    local function probe()
        local probe_event_epoch = record.observed_event_epoch
        local outcome, relation, relation_problem = safe_inspect_relation(record)
        if not rawequal(probe_event_epoch, record.observed_event_epoch) then
            record.probe_relation = nil
            record.probe_problem = nil
            return false, { outcome = "PENDING" }
        end
        if outcome == "BLOCKED" then
            record.probe_relation = nil
            record.probe_problem = relation_problem
            return true, { outcome = "BLOCKED" }
        end
        if outcome ~= "READY" or relation == nil then
            record.probe_relation = nil
            record.probe_problem = nil
            return false, { outcome = "PENDING" }
        end

        local confirmed_outcome, confirmed_relation, confirmed_problem = safe_inspect_relation(record)
        if not rawequal(probe_event_epoch, record.observed_event_epoch) then
            record.probe_relation = nil
            record.probe_problem = nil
            return false, { outcome = "PENDING" }
        end
        if confirmed_outcome == "BLOCKED" then
            record.probe_relation = nil
            record.probe_problem = confirmed_problem
            return true, { outcome = "BLOCKED" }
        end
        if confirmed_outcome ~= "READY" or confirmed_relation == nil then
            record.probe_relation = nil
            record.probe_problem = nil
            return false, { outcome = "PENDING" }
        end
        if not same_relation(record.adapter, relation, confirmed_relation) then
            record.probe_relation = nil
            record.probe_problem = problem(
                "CGCE-WORLD-RELATION-CHANGED",
                "relation",
                "selected-world relation changed before epoch issuance"
            )
            return true, { outcome = "BLOCKED" }
        end

        record.probe_relation = confirmed_relation
        record.probe_problem = nil
        return true, { outcome = "READY" }
    end

    local controller = scheduler_retry({
        max_attempts = MAX_ATTEMPTS,
        delay_seconds = DELAY_SECONDS,
        schedule = ports.schedule,
        cancel = ports.cancel,
        on_terminal = function(snapshot)
            scheduler_terminal(record, snapshot)
        end,
    }, probe)
    record.controller = controller

    if record.state ~= "PENDING" then
        return detector
    end

    local observation_generation = record.generation
    local observed = table.pack(pcall(function()
        local descriptor = binding_descriptor(record.binding_session, "world_ready_function")
        return adapter_observe_function(record.adapter, descriptor, function(...)
            if record.close_requested or record.generation ~= observation_generation then
                return nil
            end
            record.observed_event_epoch = function() end
            if record.state == "PENDING" then
                wake_pending(record)
            elseif record.state == "READY" then
                block_and_cleanup_observation(record, problem(
                    "CGCE-WORLD-EPOCH-STALE",
                    "epoch",
                    "world-ready event invalidated the selected-world epoch"
                ))
            end
            return nil
        end)
    end))
    if not observed[1] or observed.n ~= 2 or observed[2] == nil then
        block_and_cleanup_observation(record, problem(
            "CGCE-WORLD-HOOK-REGISTER",
            "observation",
            "exact world-ready hook registration failed"
        ))
        cleanup_timer(record)
        return detector
    end
    record.observation = observed[2]

    if record.state == "BLOCKED" or record.close_requested then
        cleanup_observation(record)
        return detector
    end

    wake_pending(record)
    return detector
end

function world_ready.status(detector)
    local record = require_detector(detector)
    if record.state == "READY" and record.epoch ~= nil then
        pcall(validate_epoch, record.epoch)
    end
    local attempts = 0
    local timer_pending = false
    if record.controller ~= nil then
        local ok, snapshot, status_error = pcall(scheduler_status, record.controller)
        if ok and snapshot ~= nil and status_error == nil then
            attempts = snapshot.attempts
            timer_pending = snapshot.timer_pending
        end
    end
    return {
        state = record.state,
        attempts = attempts,
        max_attempts = MAX_ATTEMPTS,
        timer_pending = timer_pending,
        errors = copy_errors(record.errors),
    }
end

function world_ready.epoch(detector)
    local record = require_detector(detector)
    if record.state ~= "READY" then
        return nil
    end
    validate_epoch(record.epoch)
    return record.epoch
end

local function require_epoch(epoch)
    local trusted = epoch_records[epoch]
    if trusted == nil then
        fail("CGCE-WORLD-EPOCH", "epoch", "world readiness epoch handle is invalid")
    end
    local detector = detector_records[trusted.detector]
    if detector == nil
        or detector.state ~= "READY"
        or detector.generation ~= trusted.detector_generation
        or detector.epoch ~= epoch then
        fail("CGCE-WORLD-EPOCH", "epoch", "world readiness epoch is no longer active")
    end
    return trusted, detector
end

validate_epoch = function(epoch)
    local trusted, detector = require_epoch(epoch)
    local validation_generation = detector.generation
    local validation_event_epoch = detector.observed_event_epoch
    local outcome, relation = safe_inspect_relation(detector)
    local final_trusted, final_detector = require_epoch(epoch)
    if not rawequal(final_trusted, trusted)
        or not rawequal(final_detector, detector)
        or final_detector.generation ~= validation_generation
        or not rawequal(final_detector.observed_event_epoch, validation_event_epoch) then
        block_and_cleanup_observation(detector, problem(
            "CGCE-WORLD-EPOCH-STALE",
            "epoch",
            "selected-world epoch changed during fresh validation"
        ))
        fail("CGCE-WORLD-EPOCH-STALE", "epoch", "selected-world epoch is stale")
    end
    if outcome ~= "READY" or relation == nil or not same_relation(trusted.adapter, trusted, relation) then
        block_and_cleanup_observation(detector, problem(
            "CGCE-WORLD-EPOCH-STALE",
            "epoch",
            "selected-world epoch failed fresh relation validation"
        ))
        fail("CGCE-WORLD-EPOCH-STALE", "epoch", "selected-world epoch is stale")
    end
    return trusted, detector, relation
end

function world_ready.world_id(epoch)
    local _, _, relation = validate_epoch(epoch)
    return relation.world_id
end

function world_ready.assert_current(epoch, adapter, binding_session)
    local trusted = require_epoch(epoch)
    if not rawequal(adapter, trusted.adapter) then
        fail(
            "CGCE-WORLD-AUTHORITY",
            "adapter",
            "world epoch and read-only adapter authority do not match"
        )
    end
    if not rawequal(binding_session, trusted.binding_session) then
        fail(
            "CGCE-WORLD-AUTHORITY",
            "binding_session",
            "world epoch and verified binding authority do not match"
        )
    end
    validate_epoch(epoch)
    return true
end

function world_ready.close(detector)
    local record = require_detector(detector)
    if record.close_requested then
        return not record.cleanup_failed, copy_errors(record.errors)
    end
    record.close_requested = true
    if record.state ~= "BLOCKED" and record.state ~= "CLOSED" then
        invalidate_epoch(record)
    end

    cleanup_timer(record)
    cleanup_observation(record)
    if record.cleanup_failed then
        record.state = "BLOCKED"
    else
        record.state = "CLOSED"
    end
    return not record.cleanup_failed, copy_errors(record.errors)
end

return world_ready
