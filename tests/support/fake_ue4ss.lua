local fake_ue4ss = {}

local function copy_array(values)
    local result = {}
    for index = 1, #values do
        result[index] = values[index]
    end
    return result
end

function fake_ue4ss.new()
    local counters = {
        static_find_object = 0,
        find_all_of = 0,
        is_valid = 0,
        get_full_name = 0,
        get_type_signature = 0,
        get_short_name = 0,
        resolve_property = 0,
        get_property_value = 0,
        value_kind = 0,
        copy_json_scalar = 0,
        array_for_each = 0,
        array_element_get = 0,
        register_hook = 0,
        unregister_hook = 0,
        function_invoke = 0,
        raw_property_write = 0,
        tarray_write = 0,
        element_set = 0,
        element_other_access = 0,
        array_empty = 0,
        array_index_write = 0,
        array_callback_non_nil = 0,
        constructor = 0,
        tostring = 0,
    }

    local object_records = setmetatable({}, { __mode = "k" })
    local property_records = setmetatable({}, { __mode = "k" })
    local scalar_records = setmetatable({}, { __mode = "k" })
    local array_records = setmetatable({}, { __mode = "k" })
    local element_records = setmetatable({}, { __mode = "k" })
    local path_objects = {}
    local loaded_objects = {}
    local hooks = {}
    local register_log = {}
    local unregister_log = {}
    local unregister_failures = {}
    local next_hook_id = 100

    local function forbidden_tostring()
        counters.tostring = counters.tostring + 1
        error("raw UE value must not be stringified")
    end

    local function forbidden_method(counter_name)
        counters[counter_name] = counters[counter_name] + 1
        return function()
            counters[counter_name] = counters[counter_name] + 1
            error("forbidden fake UE4SS operation")
        end
    end

    local object_metatable = {
        __tostring = forbidden_tostring,
        __call = function()
            counters.function_invoke = counters.function_invoke + 1
            error("candidate UFunction invocation is forbidden")
        end,
        __index = function(raw, key)
            local record = object_records[raw] or property_records[raw]
            if key == "IsValid" then
                return function()
                    counters.is_valid = counters.is_valid + 1
                    return record ~= nil and record.valid ~= false
                end
            end
            if key == "GetFullName" then
                return function()
                    counters.get_full_name = counters.get_full_name + 1
                    return record and record.path or nil
                end
            end
            if key == "GetTypeSignature" then
                return function()
                    counters.get_type_signature = counters.get_type_signature + 1
                    return record and record.type_signature or nil
                end
            end
            if key == "GetShortName" then
                return function()
                    counters.get_short_name = counters.get_short_name + 1
                    return record and record.short_name or nil
                end
            end
            if key == "ResolveProperty" then
                return function(_, member_name)
                    counters.resolve_property = counters.resolve_property + 1
                    return record and record.properties and record.properties[member_name] or nil
                end
            end
            if key == "SetPropertyValue" then
                return forbidden_method("raw_property_write")
            end
            if key == "ImportText" or key == "ContainerPtrToValuePtr" then
                return forbidden_method("raw_property_write")
            end
            if key == "CallFunction" or key == "Invoke" then
                return forbidden_method("function_invoke")
            end
            return nil
        end,
        __newindex = function()
            counters.raw_property_write = counters.raw_property_write + 1
            error("raw UE property write is forbidden")
        end,
    }

    local scalar_metatable = {
        __tostring = forbidden_tostring,
        __newindex = function()
            counters.raw_property_write = counters.raw_property_write + 1
            error("raw scalar mutation is forbidden")
        end,
    }

    local element_metatable = {
        __tostring = forbidden_tostring,
        __index = function(raw, key)
            if key == "get" then
                return function()
                    counters.array_element_get = counters.array_element_get + 1
                    return element_records[raw]
                end
            end
            if key == "set" then
                return forbidden_method("element_set")
            end
            counters.element_other_access = counters.element_other_access + 1
            return nil
        end,
        __newindex = function()
            counters.element_set = counters.element_set + 1
            error("TArray element assignment is forbidden")
        end,
    }

    local array_metatable = {
        __tostring = forbidden_tostring,
        __index = function(raw, key)
            if key == "ForEach" then
                return function(_, callback)
                    counters.array_for_each = counters.array_for_each + 1
                    local values = assert(array_records[raw])
                    for engine_index = 0, #values - 1 do
                        local element = setmetatable({}, element_metatable)
                        element_records[element] = values[engine_index + 1]
                        local stop = callback(engine_index, element)
                        if stop ~= nil then
                            counters.array_callback_non_nil = counters.array_callback_non_nil + 1
                        end
                        if stop == true then
                            break
                        end
                    end
                end
            end
            if key == "Empty" then
                return forbidden_method("array_empty")
            end
            return nil
        end,
        __newindex = function()
            counters.array_index_write = counters.array_index_write + 1
            counters.tarray_write = counters.tarray_write + 1
            error("TArray index assignment is forbidden")
        end,
    }

    local function new_raw_object(record)
        local raw = setmetatable({}, object_metatable)
        record.valid = record.valid ~= false
        record.properties = record.properties or {}
        record.values = record.values or {}
        object_records[raw] = record
        if record.path ~= nil then
            path_objects[record.path] = raw
        end
        return raw
    end

    local port = {
        api_version = "3.0.1",
    }

    port.static_find_object = function(path)
        counters.static_find_object = counters.static_find_object + 1
        return path_objects[path]
    end

    port.find_all_of = function(short_name)
        counters.find_all_of = counters.find_all_of + 1
        return copy_array(loaded_objects[short_name] or {})
    end

    port.is_valid = function(raw)
        return raw:IsValid()
    end

    port.get_full_name = function(raw)
        return raw:GetFullName()
    end

    port.get_type_signature = function(raw)
        return raw:GetTypeSignature()
    end

    port.get_short_name = function(raw)
        return raw:GetShortName()
    end

    port.resolve_property = function(owner, member_name)
        return owner:ResolveProperty(member_name)
    end

    port.get_property_value = function(property, object)
        counters.get_property_value = counters.get_property_value + 1
        local property_record = assert(property_records[property])
        local object_record = assert(object_records[object])
        return object_record.values[property_record.member_name]
    end

    port.value_kind = function(raw)
        counters.value_kind = counters.value_kind + 1
        if object_records[raw] ~= nil then
            return "uobject"
        end
        if array_records[raw] ~= nil then
            return "tarray"
        end
        if scalar_records[raw] ~= nil
            or type(raw) == "string"
            or type(raw) == "number"
            or type(raw) == "boolean" then
            return "json"
        end
        return "unknown"
    end

    port.copy_json_scalar = function(raw)
        counters.copy_json_scalar = counters.copy_json_scalar + 1
        if scalar_records[raw] ~= nil then
            return scalar_records[raw]
        end
        return raw
    end

    port.array_for_each = function(raw, callback)
        return raw:ForEach(callback)
    end

    port.array_element_get = function(element)
        return element:get()
    end

    port.register_hook = function(path, callback1, callback2)
        counters.register_hook = counters.register_hook + 1
        next_hook_id = next_hook_id + 1
        local pre_id = next_hook_id
        next_hook_id = next_hook_id + 1
        local post_id = next_hook_id
        local record = {
            path = path,
            callback1 = callback1,
            callback2 = callback2,
            pre_id = pre_id,
            post_id = post_id,
            active = true,
        }
        hooks[#hooks + 1] = record
        register_log[#register_log + 1] = {
            path = path,
            callback_count = callback2 == nil and 1 or 2,
            pre_id = pre_id,
            post_id = post_id,
        }
        return pre_id, post_id
    end

    port.unregister_hook = function(path, pre_id, post_id)
        counters.unregister_hook = counters.unregister_hook + 1
        unregister_log[#unregister_log + 1] = {
            path = path,
            pre_id = pre_id,
            post_id = post_id,
        }
        if unregister_failures[path] then
            error("unregister failed at 0xDEADBEEF with secret callback context")
        end
        for _, hook in ipairs(hooks) do
            if hook.path == path and hook.pre_id == pre_id and hook.post_id == post_id then
                hook.active = false
            end
        end
    end

    local control = {}

    function control.add_object(descriptor)
        return new_raw_object({
            path = assert(descriptor.path),
            type_signature = assert(descriptor.type_signature),
            short_name = descriptor.short_name,
        })
    end

    function control.alias_static_path(path, raw)
        path_objects[path] = raw
    end

    function control.add_property(owner, descriptor)
        local owner_record = assert(object_records[owner])
        local property = setmetatable({}, object_metatable)
        property_records[property] = {
            path = assert(descriptor.path),
            type_signature = assert(descriptor.type_signature),
            member_name = assert(descriptor.member_name),
            valid = descriptor.valid ~= false,
        }
        owner_record.properties[assert(descriptor.member_name)] = property
        return property
    end

    function control.set_property_value(object, member_name, value)
        assert(object_records[object]).values[member_name] = value
    end

    function control.scalar(value)
        local raw = setmetatable({}, scalar_metatable)
        scalar_records[raw] = value
        return raw
    end

    function control.array(values)
        local raw = setmetatable({}, array_metatable)
        array_records[raw] = copy_array(values)
        return raw
    end

    function control.add_loaded(class_or_short_name, object)
        local short_name = class_or_short_name
        if type(class_or_short_name) ~= "string" then
            short_name = assert(object_records[class_or_short_name]).short_name
        end
        local values = loaded_objects[short_name]
        if values == nil then
            values = {}
            loaded_objects[short_name] = values
        end
        values[#values + 1] = object
    end

    function control.invalidate(raw)
        local record = object_records[raw] or property_records[raw]
        assert(record).valid = false
    end

    function control.fire(path, phase, ...)
        for _, hook in ipairs(hooks) do
            if hook.active and hook.path == path then
                local callback
                if path:sub(1, 8) == "/Script/" then
                    callback = phase == "pre" and hook.callback1 or hook.callback2
                elseif phase == "post" then
                    callback = hook.callback1
                end
                if callback ~= nil then
                    callback(...)
                end
            end
        end
    end

    function control.fire_late(registration_index, phase, ...)
        local hook = assert(hooks[registration_index])
        local callback
        if hook.path:sub(1, 8) == "/Script/" then
            callback = phase == "pre" and hook.callback1 or hook.callback2
        elseif phase == "post" then
            callback = hook.callback1
        end
        if callback ~= nil then
            return callback(...)
        end
    end

    function control.fail_unregister(path)
        unregister_failures[path] = true
    end

    function control.counters()
        local result = {}
        for key, value in pairs(counters) do
            result[key] = value
        end
        return result
    end

    function control.register_log()
        local result = {}
        for index, item in ipairs(register_log) do
            result[index] = {
                path = item.path,
                callback_count = item.callback_count,
                pre_id = item.pre_id,
                post_id = item.post_id,
            }
        end
        return result
    end

    function control.unregister_log()
        local result = {}
        for index, item in ipairs(unregister_log) do
            result[index] = {
                path = item.path,
                pre_id = item.pre_id,
                post_id = item.post_id,
            }
        end
        return result
    end

    function control.is_raw(value)
        return object_records[value] ~= nil
            or property_records[value] ~= nil
            or scalar_records[value] ~= nil
            or array_records[value] ~= nil
            or element_records[value] ~= nil
    end

    return port, control
end

return fake_ue4ss
