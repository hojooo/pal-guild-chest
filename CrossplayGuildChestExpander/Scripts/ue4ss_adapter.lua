local json = require("CrossplayGuildChestExpander.Scripts.json")

local ue4ss_adapter = {}

local json_array = json.array
local json_encode = json.encode
local json_null = json.null

local REQUIRED_API_VERSION = "3.0.1"

local port_fields = {
    api_version = true,
    static_find_object = true,
    find_all_of = true,
    is_valid = true,
    get_full_name = true,
    get_type_signature = true,
    get_short_name = true,
    resolve_property = true,
    get_property_value = true,
    value_kind = true,
    copy_json_scalar = true,
    array_for_each = true,
    array_element_get = true,
    register_hook = true,
    unregister_hook = true,
}

local function_port_order = {
    "static_find_object",
    "find_all_of",
    "is_valid",
    "get_full_name",
    "get_type_signature",
    "get_short_name",
    "resolve_property",
    "get_property_value",
    "value_kind",
    "copy_json_scalar",
    "array_for_each",
    "array_element_get",
    "register_hook",
    "unregister_hook",
}

local descriptor_fields = {
    kind = true,
    path = true,
    type_signature = true,
}

local property_descriptor_fields = {
    kind = true,
    owner_path = true,
    member_name = true,
    path = true,
    type_signature = true,
}

local descriptor_field_order = { "kind", "path", "type_signature" }
local property_descriptor_field_order = {
    "kind",
    "owner_path",
    "member_name",
    "path",
    "type_signature",
}

local descriptor_kinds = {
    class = true,
    ["function"] = true,
    property = true,
    struct = true,
}

local adapter_records = setmetatable({}, { __mode = "k" })
local object_records = setmetatable({}, { __mode = "k" })
local observation_records = setmetatable({}, { __mode = "k" })

local function problem(code, field, detail)
    return { code = code, field = field, detail = detail }
end

local function observer_problem(code, path, detail)
    return { code = code, path = path, detail = detail }
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

local function is_control_free(value)
    if type(value) ~= "string" then
        return false
    end
    for index = 1, #value do
        local byte = value:byte(index)
        if byte <= 31 or byte == 127 then
            return false
        end
    end
    return true
end

local function is_exact_path(value)
    return is_control_free(value)
        and #value > 1
        and value:sub(1, 1) == "/"
        and value:match("^%s") == nil
        and value:match("%s$") == nil
        and value:find("*", 1, true) == nil
        and value:find("?", 1, true) == nil
        and value:find("[", 1, true) == nil
        and value:find("]", 1, true) == nil
        and value:find("...", 1, true) == nil
end

local function has_wildcard_star(value)
    local start = 1
    while true do
        local index = value:find("*", start, true)
        if index == nil then
            return false
        end
        local previous = value:sub(index - 1, index - 1)
        local following = value:sub(index + 1, index + 1)
        local pointer_prefix = previous:match("[A-Za-z0-9_>]") ~= nil
        local pointer_suffix = following == ""
            or following == ">"
            or following == ","
            or following == ")"
            or following == " "
            or following == "&"
        if not pointer_prefix or not pointer_suffix then
            return true
        end
        start = index + 1
    end
end

local function is_exact_signature(value)
    return is_control_free(value)
        and #value > 0
        and value:match("^%s") == nil
        and value:match("%s$") == nil
        and not has_wildcard_star(value)
        and value:find("?", 1, true) == nil
        and value:find("[", 1, true) == nil
        and value:find("]", 1, true) == nil
        and value:find("...", 1, true) == nil
end

local function is_member_name(value)
    return is_control_free(value) and value:match("^[A-Za-z_][A-Za-z0-9_]*$") ~= nil
end

local function is_short_name(value)
    return is_member_name(value)
end

local function capture_port(port)
    if type(port) ~= "table" or getmetatable(port) ~= nil then
        fail("CGCE-UE4SS-PORT-TYPE", "port", "UE4SS API port must be a plain table")
    end

    local unknown = sorted_unknown_key(port, port_fields)
    if unknown == false then
        fail("CGCE-UE4SS-PORT-UNKNOWN", "port", "UE4SS API port keys must be strings")
    end
    if unknown ~= nil then
        fail("CGCE-UE4SS-PORT-UNKNOWN", unknown, "unknown UE4SS API port field")
    end

    if rawget(port, "api_version") == nil then
        fail("CGCE-UE4SS-PORT-MISSING", "api_version", "required UE4SS API version is unavailable")
    end
    if rawget(port, "api_version") ~= REQUIRED_API_VERSION then
        fail("CGCE-UE4SS-PORT-VERSION", "api_version", "UE4SS API version must exactly match 3.0.1")
    end

    local captured = { api_version = REQUIRED_API_VERSION }
    for _, field in ipairs(function_port_order) do
        local value = rawget(port, field)
        if value == nil then
            fail("CGCE-UE4SS-PORT-MISSING", field, "required read-only UE4SS API port is unavailable")
        end
        if type(value) ~= "function" then
            fail("CGCE-UE4SS-PORT-TYPE", field, "UE4SS API port field must be a function")
        end
        captured[field] = value
    end
    return captured
end

local function validate_descriptor(value)
    if type(value) ~= "table" or getmetatable(value) ~= nil then
        fail("CGCE-UE4SS-DESCRIPTOR-TYPE", "descriptor", "descriptor must be a plain table")
    end

    local kind = rawget(value, "kind")
    if not descriptor_kinds[kind] then
        fail("CGCE-UE4SS-DESCRIPTOR-KIND", "descriptor.kind", "descriptor kind is unsupported")
    end
    local allowed = kind == "property" and property_descriptor_fields or descriptor_fields
    local ordered = kind == "property" and property_descriptor_field_order or descriptor_field_order
    local unknown = sorted_unknown_key(value, allowed)
    if unknown == false then
        fail("CGCE-UE4SS-DESCRIPTOR-KEY", "descriptor", "descriptor keys must be strings")
    end
    if unknown ~= nil then
        fail("CGCE-UE4SS-DESCRIPTOR-KEY", "descriptor." .. unknown, "unknown descriptor field")
    end
    for _, field in ipairs(ordered) do
        if rawget(value, field) == nil then
            fail("CGCE-UE4SS-DESCRIPTOR-TYPE", "descriptor." .. field, "required descriptor field is missing")
        end
    end
    if not is_exact_path(rawget(value, "path")) then
        fail("CGCE-UE4SS-DESCRIPTOR-TYPE", "descriptor.path", "descriptor path must be exact and absolute")
    end
    if not is_exact_signature(rawget(value, "type_signature")) then
        fail(
            "CGCE-UE4SS-DESCRIPTOR-TYPE",
            "descriptor.type_signature",
            "descriptor type signature must be exact"
        )
    end
    if kind == "property" then
        if not is_exact_path(rawget(value, "owner_path")) then
            fail(
                "CGCE-UE4SS-DESCRIPTOR-TYPE",
                "descriptor.owner_path",
                "property owner path must be exact and absolute"
            )
        end
        if not is_member_name(rawget(value, "member_name")) then
            fail(
                "CGCE-UE4SS-DESCRIPTOR-TYPE",
                "descriptor.member_name",
                "property member name must be an exact identifier"
            )
        end
    end

    local copy = {
        kind = kind,
        path = rawget(value, "path"),
        type_signature = rawget(value, "type_signature"),
    }
    if kind == "property" then
        copy.owner_path = rawget(value, "owner_path")
        copy.member_name = rawget(value, "member_name")
    end
    return copy
end

local function descriptors_equal(expected, actual)
    if expected.kind ~= actual.kind
        or expected.path ~= actual.path
        or expected.type_signature ~= actual.type_signature then
        return false
    end
    if expected.kind == "property" then
        return expected.owner_path == actual.owner_path
            and expected.member_name == actual.member_name
    end
    return true
end

local function safe_port_one(adapter, port_name, code, field, detail, ...)
    local results = table.pack(pcall(adapter.port[port_name], ...))
    if not results[1] or results.n > 3 or results[3] ~= nil then
        fail(code, field, detail)
    end
    return results[2]
end

local function require_adapter(handle, allow_closed, allow_poisoned)
    local record = adapter_records[handle]
    if record == nil then
        fail("CGCE-UE4SS-ADAPTER-HANDLE", "adapter", "adapter handle is invalid")
    end
    if record.closed and not allow_closed then
        fail("CGCE-UE4SS-CLOSED", "adapter", "adapter is closed")
    end
    if record.poisoned and not allow_poisoned then
        fail("CGCE-UE4SS-POISONED", "adapter", "adapter cleanup state is terminally unsafe")
    end
    return record
end

local function require_object(adapter_handle, adapter, handle)
    local record = object_records[handle]
    if record == nil or record.adapter_handle ~= adapter_handle or record.generation ~= adapter.generation then
        fail("CGCE-UE4SS-OBJECT-HANDLE", "object", "object handle is invalid for this adapter")
    end
    return record
end

local function make_object_handle(adapter_handle, adapter, raw, kind)
    local handle = function() end
    object_records[handle] = {
        adapter_handle = adapter_handle,
        generation = adapter.generation,
        raw = raw,
        kind = kind,
    }
    return handle
end

local function loaded_raw(adapter, raw, code, field, detail)
    if raw == nil then
        return false
    end
    local valid = safe_port_one(adapter, "is_valid", code, field, detail, raw)
    if type(valid) ~= "boolean" then
        fail(code, field, detail)
    end
    return valid
end

local function observed_identity(adapter, raw, code, field, detail)
    local path = safe_port_one(adapter, "get_full_name", code, field, detail, raw)
    local signature = safe_port_one(adapter, "get_type_signature", code, field, detail, raw)
    if not is_exact_path(path) or not is_exact_signature(signature) then
        fail(code, field, detail)
    end
    return path, signature
end

local function inspect_raw(adapter, descriptor)
    if descriptor.kind == "property" then
        local owner = safe_port_one(
            adapter,
            "static_find_object",
            "CGCE-UE4SS-LOOKUP",
            "descriptor.owner_path",
            "exact property owner lookup failed",
            descriptor.owner_path
        )
        if not loaded_raw(
            adapter,
            owner,
            "CGCE-UE4SS-LOOKUP",
            "descriptor.owner_path",
            "exact property owner validation failed"
        ) then
            return nil, nil, "NOT_LOADED"
        end
        local observed_owner_path = safe_port_one(
            adapter,
            "get_full_name",
            "CGCE-UE4SS-LOOKUP",
            "descriptor.owner_path",
            "exact property owner identity inspection failed",
            owner
        )
        if not is_exact_path(observed_owner_path) or observed_owner_path ~= descriptor.owner_path then
            fail("CGCE-UE4SS-DESCRIPTOR-MISMATCH", "descriptor", "observed descriptor identity does not match")
        end

        local property = safe_port_one(
            adapter,
            "resolve_property",
            "CGCE-UE4SS-LOOKUP",
            "descriptor.member_name",
            "exact property resolution failed",
            owner,
            descriptor.member_name
        )
        if not loaded_raw(
            adapter,
            property,
            "CGCE-UE4SS-LOOKUP",
            "descriptor.member_name",
            "resolved property validation failed"
        ) then
            return nil, nil, "NOT_LOADED"
        end
        local path, signature = observed_identity(
            adapter,
            property,
            "CGCE-UE4SS-LOOKUP",
            "descriptor",
            "resolved property identity inspection failed"
        )
        local actual = {
            kind = "property",
            owner_path = observed_owner_path,
            member_name = descriptor.member_name,
            path = path,
            type_signature = signature,
        }
        return actual, property, descriptors_equal(descriptor, actual) and "MATCHED" or "MISMATCH"
    end

    local raw = safe_port_one(
        adapter,
        "static_find_object",
        "CGCE-UE4SS-LOOKUP",
        "descriptor.path",
        "exact UObject lookup failed",
        descriptor.path
    )
    if not loaded_raw(
        adapter,
        raw,
        "CGCE-UE4SS-LOOKUP",
        "descriptor.path",
        "exact UObject validation failed"
    ) then
        return nil, nil, "NOT_LOADED"
    end
    local path, signature = observed_identity(
        adapter,
        raw,
        "CGCE-UE4SS-LOOKUP",
        "descriptor",
        "exact UObject identity inspection failed"
    )
    local actual = {
        kind = descriptor.kind,
        path = path,
        type_signature = signature,
    }
    return actual, raw, descriptors_equal(descriptor, actual) and "MATCHED" or "MISMATCH"
end

local function require_exact_raw(adapter, descriptor)
    local actual, raw, status = inspect_raw(adapter, descriptor)
    if status == "NOT_LOADED" then
        return nil, status
    end
    if status ~= "MATCHED" then
        fail("CGCE-UE4SS-DESCRIPTOR-MISMATCH", "descriptor", "observed descriptor identity does not match")
    end
    return raw, status, actual
end

local function dense_array_length(value)
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

local function valid_json_scalar(value)
    if value == json_null then
        return true
    end
    local value_type = type(value)
    if value_type == "string" or value_type == "boolean" then
        local ok = pcall(json_encode, value)
        return ok
    end
    if value_type == "number" then
        return value == value and value ~= math.huge and value ~= -math.huge
    end
    return false
end

local copy_raw_value

local function copy_array_value(adapter_handle, adapter, raw, seen_arrays)
    if seen_arrays[raw] then
        fail("CGCE-UE4SS-READ-ARRAY", "value", "TArray value is cyclic")
    end
    seen_arrays[raw] = true
    local result = json_array()
    local expected_engine_index = 0
    safe_port_one(
        adapter,
        "array_for_each",
        "CGCE-UE4SS-READ-ARRAY",
        "value",
        "TArray iteration failed",
        raw,
        function(engine_index, element)
            if type(engine_index) ~= "number"
                or math.type(engine_index) ~= "integer"
                or engine_index ~= expected_engine_index then
                fail("CGCE-UE4SS-READ-ARRAY", "value", "TArray engine indexes are not contiguous")
            end
            expected_engine_index = expected_engine_index + 1
            local element_value = safe_port_one(
                adapter,
                "array_element_get",
                "CGCE-UE4SS-READ-ARRAY",
                "value",
                "TArray element read failed",
                element
            )
            result[#result + 1] = copy_raw_value(adapter_handle, adapter, element_value, seen_arrays)
            return nil
        end
    )
    seen_arrays[raw] = nil
    return result
end

copy_raw_value = function(adapter_handle, adapter, raw, seen_arrays)
    if raw == nil then
        return json_null
    end
    local kind = safe_port_one(
        adapter,
        "value_kind",
        "CGCE-UE4SS-READ-VALUE",
        "value",
        "property value classification failed",
        raw
    )
    if kind == "json" then
        local copied = safe_port_one(
            adapter,
            "copy_json_scalar",
            "CGCE-UE4SS-READ-VALUE",
            "value",
            "JSON scalar conversion failed",
            raw
        )
        if copied == nil then
            return json_null
        end
        if not valid_json_scalar(copied) then
            fail("CGCE-UE4SS-READ-VALUE", "value", "property value is not a detached JSON scalar")
        end
        return copied
    end
    if kind == "uobject" then
        if not loaded_raw(
            adapter,
            raw,
            "CGCE-UE4SS-READ-VALUE",
            "value",
            "UObject property reference is invalid"
        ) then
            fail("CGCE-UE4SS-READ-VALUE", "value", "UObject property reference is invalid")
        end
        return make_object_handle(adapter_handle, adapter, raw, "object")
    end
    if kind == "tarray" then
        return copy_array_value(adapter_handle, adapter, raw, seen_arrays)
    end
    fail("CGCE-UE4SS-READ-VALUE", "value", "property value kind is unsupported")
end

local function copy_observer_errors(errors)
    local result = json_array()
    for index, item in ipairs(errors) do
        result[index] = {
            code = item.code,
            path = item.path,
            detail = item.detail,
        }
    end
    return result
end

local function same_observer_error(left, right)
    return left.code == right.code
        and left.path == right.path
        and left.detail == right.detail
end

local function poison_adapter(adapter, err)
    if not adapter.poisoned then
        adapter.poisoned = true
        adapter.generation = adapter.generation + 1
    end
    for _, existing in ipairs(adapter.terminal_errors) do
        if same_observer_error(existing, err) then
            return
        end
    end
    adapter.terminal_errors[#adapter.terminal_errors + 1] = err
end

local function valid_hook_id(value)
    return type(value) == "number" and math.type(value) == "integer" and value > 0
end

local function attempt_unregister(adapter, path, pre_id, post_id)
    local results = table.pack(pcall(adapter.port.unregister_hook, path, pre_id, post_id))
    return results[1]
        and results.n <= 3
        and results[3] == nil
        and results[2] ~= false
end

local function close_observation_record(adapter, observation)
    if observation.state == "CLOSED" then
        return observation.cleanup_error == nil, observation.cleanup_error
    end
    observation.state = "CLOSED"
    observation.generation = observation.generation + 1
    if not observation.registered then
        return true, nil
    end
    observation.registered = false
    if attempt_unregister(adapter, observation.path, observation.pre_id, observation.post_id) then
        return true, nil
    end
    local err = observer_problem(
        "CGCE-UE4SS-OBSERVER-UNREGISTER",
        observation.path,
        "hook unregister failed"
    )
    observation.cleanup_error = err
    observation.errors[#observation.errors + 1] = err
    poison_adapter(adapter, err)
    return false, err
end

function ue4ss_adapter.new(port)
    local handle = function() end
    adapter_records[handle] = {
        port = capture_port(port),
        generation = 1,
        closed = false,
        poisoned = false,
        terminal_errors = {},
        observations = {},
    }
    return handle
end

function ue4ss_adapter.capabilities(handle)
    require_adapter(handle, true, true)
    return {
        mutation_capability = false,
        function_invoke_capability = false,
        raw_property_write_capability = false,
        tarray_write_capability = false,
    }
end

function ue4ss_adapter.inspect_descriptor(handle, value)
    local adapter = require_adapter(handle, false)
    local descriptor = validate_descriptor(value)
    local actual, _, status = inspect_raw(adapter, descriptor)
    return actual, status
end

function ue4ss_adapter.resolve_exact(handle, value)
    local adapter = require_adapter(handle, false)
    local descriptor = validate_descriptor(value)
    local raw, status = require_exact_raw(adapter, descriptor)
    if raw == nil then
        return nil, status
    end
    return make_object_handle(handle, adapter, raw, descriptor.kind), status
end

function ue4ss_adapter.inventory_loaded(handle, class_handle)
    local adapter = require_adapter(handle, false)
    local class = require_object(handle, adapter, class_handle)
    if class.kind ~= "class" then
        fail("CGCE-UE4SS-INVENTORY", "class", "loaded inventory requires a verified class handle")
    end
    if not loaded_raw(
        adapter,
        class.raw,
        "CGCE-UE4SS-INVENTORY",
        "class",
        "verified class is no longer valid"
    ) then
        fail("CGCE-UE4SS-INVENTORY", "class", "verified class is no longer valid")
    end
    local short_name = safe_port_one(
        adapter,
        "get_short_name",
        "CGCE-UE4SS-INVENTORY",
        "class",
        "verified class short-name inspection failed",
        class.raw
    )
    if not is_short_name(short_name) then
        fail("CGCE-UE4SS-INVENTORY", "class", "verified class short name is invalid")
    end
    local raw_inventory = safe_port_one(
        adapter,
        "find_all_of",
        "CGCE-UE4SS-INVENTORY",
        "class",
        "loaded-instance inventory failed",
        short_name
    )
    local length = dense_array_length(raw_inventory)
    if length == nil then
        fail("CGCE-UE4SS-INVENTORY", "class", "loaded-instance inventory must be a dense array")
    end
    local result = json_array()
    for index = 1, length do
        local raw = rawget(raw_inventory, index)
        if not loaded_raw(
            adapter,
            raw,
            "CGCE-UE4SS-INVENTORY",
            "class",
            "loaded-instance inventory contains an invalid UObject"
        ) then
            fail("CGCE-UE4SS-INVENTORY", "class", "loaded-instance inventory contains an invalid UObject")
        end
        result[index] = make_object_handle(handle, adapter, raw, "object")
    end
    return result, length == 0 and "NOT_LOADED" or "LOADED"
end

function ue4ss_adapter.same_object(handle, left_handle, right_handle)
    local adapter = require_adapter(handle, false)
    local left = require_object(handle, adapter, left_handle)
    local right = require_object(handle, adapter, right_handle)
    return left.raw == right.raw
end

function ue4ss_adapter.read_property(handle, object_handle, value)
    local adapter = require_adapter(handle, false)
    local object = require_object(handle, adapter, object_handle)
    local descriptor = validate_descriptor(value)
    if descriptor.kind ~= "property" then
        fail("CGCE-UE4SS-READ", "descriptor.kind", "property read requires a property descriptor")
    end
    if not loaded_raw(
        adapter,
        object.raw,
        "CGCE-UE4SS-READ",
        "object",
        "property owner object is invalid"
    ) then
        fail("CGCE-UE4SS-READ", "object", "property owner object is invalid")
    end
    local raw_property, status = require_exact_raw(adapter, descriptor)
    if raw_property == nil or status ~= "MATCHED" then
        fail("CGCE-UE4SS-READ", "property", "exact property is not loaded")
    end
    local raw_value = safe_port_one(
        adapter,
        "get_property_value",
        "CGCE-UE4SS-READ",
        "property",
        "verified property read failed",
        raw_property,
        object.raw
    )
    return copy_raw_value(handle, adapter, raw_value, {})
end

function ue4ss_adapter.observe_function(handle, value, observer)
    local adapter = require_adapter(handle, false)
    local descriptor = validate_descriptor(value)
    if descriptor.kind ~= "function" then
        fail("CGCE-UE4SS-OBSERVER", "descriptor.kind", "observation requires a function descriptor")
    end
    if type(observer) ~= "function" then
        fail("CGCE-UE4SS-OBSERVER", "observer", "observer must be a function")
    end
    local raw_function, status = require_exact_raw(adapter, descriptor)
    if raw_function == nil or status ~= "MATCHED" then
        fail("CGCE-UE4SS-OBSERVER", "descriptor.path", "exact UFunction is not loaded")
    end

    local observation = {
        adapter_handle = handle,
        adapter_generation = adapter.generation,
        generation = 1,
        path = descriptor.path,
        state = "ACTIVE",
        errors = {},
        registered = false,
    }
    local callback_generation = observation.generation
    local function post_callback(...)
        if adapter.closed
            or adapter.generation ~= observation.adapter_generation
            or observation.generation ~= callback_generation
            or observation.state ~= "ACTIVE" then
            return nil
        end
        local observer_ok = pcall(observer, {
            phase = "post",
            path = observation.path,
        })
        if not observer_ok and observation.state ~= "CLOSED" then
            observation.state = "FAILED"
            observation.errors[#observation.errors + 1] = observer_problem(
                "CGCE-UE4SS-OBSERVER-CALLBACK",
                observation.path,
                "observer callback failed"
            )
        end
        return nil
    end
    local function noop_pre_callback(...)
        return nil
    end

    local registration
    if descriptor.path:sub(1, 8) == "/Script/" then
        registration = table.pack(pcall(adapter.port.register_hook, descriptor.path, noop_pre_callback, post_callback))
    else
        registration = table.pack(pcall(adapter.port.register_hook, descriptor.path, post_callback, nil))
    end
    local pre_id = registration[2]
    local post_id = registration[3]
    local registration_error = registration[4]
    local ids_valid = valid_hook_id(pre_id) and valid_hook_id(post_id)
    if not registration[1]
        or registration.n > 4
        or registration_error ~= nil
        or not ids_valid
        or adapter.closed
        or adapter.generation ~= observation.adapter_generation then
        observation.state = "FAILED"
        observation.generation = observation.generation + 1
        local cleanup_ok = false
        if ids_valid then
            cleanup_ok = attempt_unregister(adapter, descriptor.path, pre_id, post_id)
        end
        if not ids_valid then
            poison_adapter(adapter, observer_problem(
                "CGCE-UE4SS-OBSERVER-CLEANUP-UNCERTAIN",
                descriptor.path,
                "hook registration cleanup is uncertain"
            ))
        elseif not cleanup_ok then
            poison_adapter(adapter, observer_problem(
                "CGCE-UE4SS-OBSERVER-UNREGISTER",
                descriptor.path,
                "hook unregister failed"
            ))
        end
        fail("CGCE-UE4SS-OBSERVER-REGISTER", "descriptor.path", "hook registration failed")
    end

    observation.pre_id = pre_id
    observation.post_id = post_id
    observation.registered = true
    local observation_handle = function() end
    observation_records[observation_handle] = observation
    adapter.observations[#adapter.observations + 1] = observation
    return observation_handle
end

local function require_observation(adapter_handle, observation_handle)
    local observation = observation_records[observation_handle]
    if observation == nil or observation.adapter_handle ~= adapter_handle then
        fail("CGCE-UE4SS-OBSERVER-HANDLE", "observer", "observation handle is invalid for this adapter")
    end
    return observation
end

function ue4ss_adapter.observation_status(adapter_handle, observation_handle)
    require_adapter(adapter_handle, true, true)
    local observation = require_observation(adapter_handle, observation_handle)
    return {
        state = observation.state,
        errors = copy_observer_errors(observation.errors),
    }
end

function ue4ss_adapter.close_observation(adapter_handle, observation_handle)
    local adapter = require_adapter(adapter_handle, true, true)
    local observation = require_observation(adapter_handle, observation_handle)
    local ok, err = close_observation_record(adapter, observation)
    if ok then
        return true, json_array()
    end
    return false, json_array({
        { code = err.code, path = err.path, detail = err.detail },
    })
end

function ue4ss_adapter.close(handle)
    local adapter = require_adapter(handle, true, true)
    if adapter.closed then
        local closed_errors = copy_observer_errors(adapter.terminal_errors)
        return #closed_errors == 0, closed_errors
    end
    adapter.closed = true
    adapter.generation = adapter.generation + 1

    for index = #adapter.observations, 1, -1 do
        close_observation_record(adapter, adapter.observations[index])
    end
    local errors = copy_observer_errors(adapter.terminal_errors)
    return #errors == 0, errors
end

return ue4ss_adapter
