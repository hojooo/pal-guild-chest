local a = require("tests.support.assertions")
local fake_ue4ss = require("tests.support.fake_ue4ss")
local json = require("CrossplayGuildChestExpander.Scripts.json")
local ue4ss_adapter = require("CrossplayGuildChestExpander.Scripts.ue4ss_adapter")

local function clone_port(port)
    local copy = {}
    for key, value in next, port do
        copy[key] = value
    end
    return copy
end

local function class_descriptor(path, signature)
    return {
        kind = "class",
        path = path or "/OwnerSupplied/ExactGuildChestClass",
        type_signature = signature or "Class<OwnerSuppliedGuildChest>",
    }
end

local function function_descriptor(path)
    return {
        kind = "function",
        path = path or "/Script/OwnerSupplied.ExactOwner:ExactReadyFunction",
        type_signature = "Function<void()>",
    }
end

local function property_descriptor()
    return {
        kind = "property",
        owner_path = "/OwnerSupplied/ExactPropertyOwner",
        member_name = "ExactIdentifier",
        path = "/OwnerSupplied/ExactPropertyOwner:ExactIdentifier",
        type_signature = "Property<OpaqueIdentifier>",
    }
end

local function expect_problem(code, field, operation)
    local ok, err = pcall(operation)
    a.equal(false, ok)
    a.equal("table", type(err))
    a.equal(code, err.code)
    a.equal(field, err.field)
    a.equal("string", type(err.detail))
    return err
end

local function install_exact(fake, descriptor, short_name)
    return fake.add_object({
        path = descriptor.path,
        type_signature = descriptor.type_signature,
        short_name = short_name,
    })
end

local function install_property(fake, descriptor)
    local owner = fake.add_object({
        path = descriptor.owner_path,
        type_signature = "Class<ExactPropertyOwner>",
        short_name = "ExactPropertyOwner",
    })
    local property = fake.add_property(owner, descriptor)
    return owner, property
end

local function assert_zero_write_calls(counters)
    for _, key in ipairs({
        "function_invoke",
        "raw_property_write",
        "tarray_write",
        "element_set",
        "element_other_access",
        "array_empty",
        "array_index_write",
        "array_callback_non_nil",
        "constructor",
        "tostring",
    }) do
        a.equal(0, counters[key])
    end
end

local function assert_no_counter_delta(before, after)
    for key, value in pairs(before) do
        a.equal(value, after[key])
    end
end

describe("ue4ss_adapter strict read-only port", function()
    it("copies only the exact UE4SS 3.0.1 read and observe allow-list", function()
        local port, fake = fake_ue4ss.new()
        local descriptor = class_descriptor()
        install_exact(fake, descriptor, "ExactGuildChestClass")
        local adapter = ue4ss_adapter.new(port)

        a.equal("function", type(adapter))
        a.deep_equal({
            mutation_capability = false,
            function_invoke_capability = false,
            raw_property_write_capability = false,
            tarray_write_capability = false,
        }, ue4ss_adapter.capabilities(adapter))

        local detached = ue4ss_adapter.capabilities(adapter)
        detached.mutation_capability = true
        a.equal(false, ue4ss_adapter.capabilities(adapter).mutation_capability)
        a.equal(false, pcall(function() rawset(adapter, "mutation_capability", true) end))

        port.static_find_object = function()
            error("mutable sibling dispatch must not be observed")
        end
        local object = ue4ss_adapter.resolve_exact(adapter, descriptor)
        a.equal("function", type(object))
        assert_zero_write_calls(fake.counters())
    end)

    it("rejects missing, unknown, mutating, malformed, and wrong-version ports deterministically", function()
        local port = fake_ue4ss.new()

        local missing = clone_port(port)
        missing.array_element_get = nil
        expect_problem("CGCE-UE4SS-PORT-MISSING", "array_element_get", function()
            ue4ss_adapter.new(missing)
        end)

        local unknown = clone_port(port)
        unknown.z_extra = function() end
        unknown.a_extra = function() end
        expect_problem("CGCE-UE4SS-PORT-UNKNOWN", "a_extra", function()
            ue4ss_adapter.new(unknown)
        end)

        local mutating = clone_port(port)
        mutating.SetPropertyValue = function() end
        expect_problem("CGCE-UE4SS-PORT-UNKNOWN", "SetPropertyValue", function()
            ue4ss_adapter.new(mutating)
        end)

        local wrong_version = clone_port(port)
        wrong_version.api_version = "main"
        expect_problem("CGCE-UE4SS-PORT-VERSION", "api_version", function()
            ue4ss_adapter.new(wrong_version)
        end)

        local non_string_key = clone_port(port)
        non_string_key[1] = function() end
        expect_problem("CGCE-UE4SS-PORT-UNKNOWN", "port", function()
            ue4ss_adapter.new(non_string_key)
        end)

        local metatable_port = clone_port(port)
        setmetatable(metatable_port, {})
        expect_problem("CGCE-UE4SS-PORT-TYPE", "port", function()
            ue4ss_adapter.new(metatable_port)
        end)
    end)

    it("exports no generic invocation, hook, write, construction, or game-thread surface", function()
        for _, key in ipairs({
            "invoke",
            "call_function",
            "register_hook",
            "set_property_value",
            "import_text",
            "container_ptr_to_value_ptr",
            "empty_array",
            "append",
            "construct",
            "execute_in_game_thread",
        }) do
            a.equal(nil, ue4ss_adapter[key])
        end
    end)
end)

describe("ue4ss_adapter exact object resolution", function()
    it("compares private raw identity across resolve, inventory, and read handles", function()
        local port, fake = fake_ue4ss.new()
        local class = class_descriptor()
        local raw_class = install_exact(fake, class, "ExactGuildChestClass")
        local property = property_descriptor()
        install_property(fake, property)
        local same_descriptor = {
            kind = "struct",
            path = "/Runtime/SameObject",
            type_signature = "Object<ExactGuildChestClass>",
        }
        local other_descriptor = {
            kind = "struct",
            path = "/Runtime/OtherObject",
            type_signature = "Object<ExactGuildChestClass>",
        }
        local raw_same = install_exact(fake, same_descriptor)
        install_exact(fake, other_descriptor)
        fake.add_loaded(raw_class, raw_same)
        fake.set_property_value(raw_same, property.member_name, raw_same)

        local adapter = ue4ss_adapter.new(port)
        local class_handle = ue4ss_adapter.resolve_exact(adapter, class)
        local resolved = ue4ss_adapter.resolve_exact(adapter, same_descriptor)
        local resolved_again = ue4ss_adapter.resolve_exact(adapter, same_descriptor)
        local other = ue4ss_adapter.resolve_exact(adapter, other_descriptor)
        local inventory = ue4ss_adapter.inventory_loaded(adapter, class_handle)
        local reference = ue4ss_adapter.read_property(adapter, resolved, property)
        local before = fake.counters()

        local direct = table.pack(ue4ss_adapter.same_object(adapter, resolved, resolved_again))
        a.equal(1, direct.n)
        a.equal(true, direct[1])
        a.equal(true, ue4ss_adapter.same_object(adapter, resolved, inventory[1]))
        a.equal(true, ue4ss_adapter.same_object(adapter, resolved, reference))
        a.equal(false, ue4ss_adapter.same_object(adapter, resolved, other))

        assert_no_counter_delta(before, fake.counters())
        assert_zero_write_calls(fake.counters())
    end)

    it("rejects forged, cross-adapter, closed, stale, and poisoned handles without port calls", function()
        local port, fake = fake_ue4ss.new()
        local descriptor = class_descriptor()
        install_exact(fake, descriptor, "ExactGuildChestClass")
        local adapter = ue4ss_adapter.new(port)
        local object = ue4ss_adapter.resolve_exact(adapter, descriptor)

        local other_port, other_fake = fake_ue4ss.new()
        install_exact(other_fake, descriptor, "ExactGuildChestClass")
        local other_adapter = ue4ss_adapter.new(other_port)
        local other_object = ue4ss_adapter.resolve_exact(other_adapter, descriptor)
        local before = fake.counters()
        local other_before = other_fake.counters()

        expect_problem("CGCE-UE4SS-ADAPTER-HANDLE", "adapter", function()
            ue4ss_adapter.same_object(function() end, object, object)
        end)
        expect_problem("CGCE-UE4SS-OBJECT-HANDLE", "object", function()
            ue4ss_adapter.same_object(adapter, object, function() end)
        end)
        expect_problem("CGCE-UE4SS-OBJECT-HANDLE", "object", function()
            ue4ss_adapter.same_object(adapter, object, other_object)
        end)
        assert_no_counter_delta(before, fake.counters())
        assert_no_counter_delta(other_before, other_fake.counters())

        ue4ss_adapter.close(adapter)
        local closed_before = fake.counters()
        expect_problem("CGCE-UE4SS-CLOSED", "adapter", function()
            ue4ss_adapter.same_object(adapter, object, object)
        end)
        assert_no_counter_delta(closed_before, fake.counters())

        local poisoned_port, poisoned_fake = fake_ue4ss.new()
        local function_value = function_descriptor()
        install_exact(poisoned_fake, function_value)
        install_exact(poisoned_fake, descriptor, "ExactGuildChestClass")
        local poisoned_adapter = ue4ss_adapter.new(poisoned_port)
        local poisoned_object = ue4ss_adapter.resolve_exact(poisoned_adapter, descriptor)
        local observation = ue4ss_adapter.observe_function(
            poisoned_adapter,
            function_value,
            function() end
        )
        poisoned_fake.fail_unregister(function_value.path)
        local close_ok = ue4ss_adapter.close_observation(poisoned_adapter, observation)
        a.equal(false, close_ok)
        local poisoned_before = poisoned_fake.counters()
        expect_problem("CGCE-UE4SS-POISONED", "adapter", function()
            ue4ss_adapter.same_object(poisoned_adapter, poisoned_object, poisoned_object)
        end)
        assert_no_counter_delta(poisoned_before, poisoned_fake.counters())

        assert_zero_write_calls(fake.counters())
        assert_zero_write_calls(other_fake.counters())
        assert_zero_write_calls(poisoned_fake.counters())
    end)

    it("uses StaticFindObject only with an exact absolute descriptor and compares identity", function()
        local port, fake = fake_ue4ss.new()
        local descriptor = class_descriptor()
        install_exact(fake, descriptor, "ExactGuildChestClass")
        local adapter = ue4ss_adapter.new(port)

        local inspected, status = ue4ss_adapter.inspect_descriptor(adapter, descriptor)
        a.deep_equal(descriptor, inspected)
        a.equal("MATCHED", status)
        a.equal("function", type(ue4ss_adapter.resolve_exact(adapter, descriptor)))

        for _, path in ipairs({
            "Relative/Class",
            "/OwnerSupplied/*",
            "/OwnerSupplied/Fuzzy...Class",
            "/OwnerSupplied/Maybe?",
        }) do
            local malformed = class_descriptor(path)
            expect_problem("CGCE-UE4SS-DESCRIPTOR-TYPE", "descriptor.path", function()
                ue4ss_adapter.resolve_exact(adapter, malformed)
            end)
        end

        local missing, missing_status = ue4ss_adapter.resolve_exact(
            adapter,
            class_descriptor("/OwnerSupplied/ExactButNotLoaded")
        )
        a.equal(nil, missing)
        a.equal("NOT_LOADED", missing_status)

        local requested = class_descriptor("/OwnerSupplied/ExpectedClass")
        local wrong = install_exact(fake, class_descriptor("/OwnerSupplied/ObservedOtherClass"), "OtherClass")
        fake.alias_static_path(requested.path, wrong)
        expect_problem("CGCE-UE4SS-DESCRIPTOR-MISMATCH", "descriptor", function()
            ue4ss_adapter.resolve_exact(adapter, requested)
        end)

        assert_zero_write_calls(fake.counters())
    end)

    it("sanitizes port exceptions and secondary-return errors without addresses or raw values", function()
        local first_port = fake_ue4ss.new()
        first_port.static_find_object = function()
            error("secret raw object at 0xDEADBEEF")
        end
        local first = ue4ss_adapter.new(first_port)
        local thrown = expect_problem("CGCE-UE4SS-LOOKUP", "descriptor.path", function()
            ue4ss_adapter.resolve_exact(first, class_descriptor())
        end)
        local thrown_json = json.encode(thrown)
        a.equal(nil, thrown_json:find("DEADBEEF", 1, true))
        a.equal(nil, thrown_json:find("secret", 1, true))

        local second_port, second_fake = fake_ue4ss.new()
        local descriptor = class_descriptor()
        local raw = install_exact(second_fake, descriptor, "ExactGuildChestClass")
        second_port.static_find_object = function()
            return raw, "secondary secret at 0xCAFEBABE"
        end
        local second = ue4ss_adapter.new(second_port)
        local secondary = expect_problem("CGCE-UE4SS-LOOKUP", "descriptor.path", function()
            ue4ss_adapter.resolve_exact(second, descriptor)
        end)
        local secondary_json = json.encode(secondary)
        a.equal(nil, secondary_json:find("CAFEBABE", 1, true))
        a.equal(nil, secondary_json:find("secret", 1, true))
    end)

    it("derives FindAllOf short names from verified class handles and keeps empty as NOT_LOADED", function()
        local port, fake = fake_ue4ss.new()
        local descriptor = class_descriptor()
        local raw_class = install_exact(fake, descriptor, "ExactGuildChestClass")
        local raw_first = fake.add_object({
            path = "/Runtime/LoadedChest_2",
            type_signature = "Object<ExactGuildChestClass>",
        })
        local raw_second = fake.add_object({
            path = "/Runtime/LoadedChest_1",
            type_signature = "Object<ExactGuildChestClass>",
        })
        fake.add_loaded(raw_class, raw_first)
        fake.add_loaded(raw_class, raw_second)

        local seen_short_name
        local original_find_all = port.find_all_of
        port.find_all_of = function(short_name)
            seen_short_name = short_name
            return original_find_all(short_name)
        end

        local adapter = ue4ss_adapter.new(port)
        local class_handle = ue4ss_adapter.resolve_exact(adapter, descriptor)
        local inventory, status = ue4ss_adapter.inventory_loaded(adapter, class_handle)
        a.equal("LOADED", status)
        a.equal("ExactGuildChestClass", seen_short_name)
        a.equal(2, #inventory)
        a.equal("function", type(inventory[1]))
        a.equal("function", type(inventory[2]))

        local empty_port, empty_fake = fake_ue4ss.new()
        local empty_class = install_exact(empty_fake, descriptor, "ExactGuildChestClass")
        local empty_adapter = ue4ss_adapter.new(empty_port)
        local empty_handle = ue4ss_adapter.resolve_exact(empty_adapter, descriptor)
        local empty, empty_status = ue4ss_adapter.inventory_loaded(empty_adapter, empty_handle)
        a.equal("NOT_LOADED", empty_status)
        a.equal("[]", json.encode(empty))

        expect_problem("CGCE-UE4SS-OBJECT-HANDLE", "object", function()
            ue4ss_adapter.inventory_loaded(adapter, function() end)
        end)

        local bad_port, bad_fake = fake_ue4ss.new()
        local bad_class = install_exact(bad_fake, descriptor, "Fuzzy*Class")
        local bad_adapter = ue4ss_adapter.new(bad_port)
        local bad_handle = ue4ss_adapter.resolve_exact(bad_adapter, descriptor)
        expect_problem("CGCE-UE4SS-INVENTORY", "class", function()
            ue4ss_adapter.inventory_loaded(bad_adapter, bad_handle)
        end)

        a.equal(true, raw_class ~= nil and empty_class ~= nil and bad_class ~= nil)
        assert_zero_write_calls(fake.counters())
    end)

    it("rejects sparse or non-array FindAllOf results without exposing raw instances", function()
        for _, malformed_result in ipairs({
            { item = "not-an-array" },
            { [1] = "first", [3] = "third" },
        }) do
            local port, fake = fake_ue4ss.new()
            local descriptor = class_descriptor()
            install_exact(fake, descriptor, "ExactGuildChestClass")
            port.find_all_of = function()
                return malformed_result
            end
            local adapter = ue4ss_adapter.new(port)
            local class_handle = ue4ss_adapter.resolve_exact(adapter, descriptor)
            expect_problem("CGCE-UE4SS-INVENTORY", "class", function()
                ue4ss_adapter.inventory_loaded(adapter, class_handle)
            end)
            assert_zero_write_calls(fake.counters())
        end
    end)
end)

describe("ue4ss_adapter exact property reads", function()
    it("resolves and verifies the raw field before reading detached scalars and UObject references", function()
        local port, fake = fake_ue4ss.new()
        local property = property_descriptor()
        install_property(fake, property)
        local raw_instance = fake.add_object({
            path = "/Runtime/ExactInstance",
            type_signature = "Object<ExactPropertyOwner>",
        })
        local instance_descriptor = {
            kind = "struct",
            path = "/Runtime/ExactInstance",
            type_signature = "Object<ExactPropertyOwner>",
        }
        local scalar = fake.scalar("identifier/opaque")
        fake.set_property_value(raw_instance, property.member_name, scalar)

        local adapter = ue4ss_adapter.new(port)
        local instance = ue4ss_adapter.resolve_exact(adapter, instance_descriptor)
        a.equal("identifier/opaque", ue4ss_adapter.read_property(adapter, instance, property))

        fake.set_property_value(raw_instance, property.member_name, nil)
        local absent = ue4ss_adapter.read_property(adapter, instance, property)
        a.equal(json.null, absent)
        a.equal("null", json.encode(absent))

        local raw_reference = fake.add_object({
            path = "/Runtime/ReferencedObject",
            type_signature = "Object<Referenced>",
        })
        fake.set_property_value(raw_instance, property.member_name, raw_reference)
        local reference = ue4ss_adapter.read_property(adapter, instance, property)
        a.equal("function", type(reference))
        a.equal(false, pcall(function() rawset(reference, "raw", raw_reference) end))

        local counts = fake.counters()
        a.equal(3, counts.get_property_value)
        assert_zero_write_calls(counts)
    end)

    it("copies TArray elements in engine order only through elem:get and emits explicit empty arrays", function()
        local port, fake = fake_ue4ss.new()
        local property = property_descriptor()
        install_property(fake, property)
        local raw_instance = fake.add_object({
            path = "/Runtime/ArrayOwner",
            type_signature = "Object<ExactPropertyOwner>",
        })
        local instance_descriptor = {
            kind = "struct",
            path = "/Runtime/ArrayOwner",
            type_signature = "Object<ExactPropertyOwner>",
        }
        local raw_reference = fake.add_object({
            path = "/Runtime/ArrayReference",
            type_signature = "Object<Referenced>",
        })
        fake.set_property_value(raw_instance, property.member_name, fake.array({
            fake.scalar("first"),
            raw_reference,
            fake.scalar(3),
        }))

        local adapter = ue4ss_adapter.new(port)
        local instance = ue4ss_adapter.resolve_exact(adapter, instance_descriptor)
        local values = ue4ss_adapter.read_property(adapter, instance, property)
        a.equal(3, #values)
        a.equal("first", values[1])
        a.equal("function", type(values[2]))
        a.equal(3, values[3])

        fake.set_property_value(raw_instance, property.member_name, fake.array({}))
        local empty = ue4ss_adapter.read_property(adapter, instance, property)
        a.equal("[]", json.encode(empty))

        local counts = fake.counters()
        a.equal(3, counts.array_element_get)
        assert_zero_write_calls(counts)

        local bad_port, bad_fake = fake_ue4ss.new()
        install_property(bad_fake, property)
        local bad_raw = bad_fake.add_object({
            path = "/Runtime/BadArrayOwner",
            type_signature = "Object<ExactPropertyOwner>",
        })
        bad_fake.set_property_value(bad_raw, property.member_name, bad_fake.array({
            bad_fake.scalar("first"),
            bad_fake.scalar("second"),
        }))
        local original_each = bad_port.array_for_each
        bad_port.array_for_each = function(raw, callback)
            return original_each(raw, function(index, element)
                if index == 1 then
                    index = 2
                end
                return callback(index, element)
            end)
        end
        local bad_adapter = ue4ss_adapter.new(bad_port)
        local bad_instance = ue4ss_adapter.resolve_exact(bad_adapter, {
            kind = "struct",
            path = "/Runtime/BadArrayOwner",
            type_signature = "Object<ExactPropertyOwner>",
        })
        expect_problem("CGCE-UE4SS-READ-ARRAY", "value", function()
            ue4ss_adapter.read_property(bad_adapter, bad_instance, property)
        end)
        assert_zero_write_calls(bad_fake.counters())
    end)

    it("blocks property metadata mismatch and invalid JSON conversions before exposing values", function()
        local port, fake = fake_ue4ss.new()
        local expected = property_descriptor()
        local observed = property_descriptor()
        observed.path = "/OwnerSupplied/ExactPropertyOwner:DifferentObservedField"
        install_property(fake, observed)
        local raw_instance = fake.add_object({
            path = "/Runtime/MismatchOwner",
            type_signature = "Object<ExactPropertyOwner>",
        })
        fake.set_property_value(raw_instance, expected.member_name, fake.scalar("must-not-read"))
        local adapter = ue4ss_adapter.new(port)
        local instance = ue4ss_adapter.resolve_exact(adapter, {
            kind = "struct",
            path = "/Runtime/MismatchOwner",
            type_signature = "Object<ExactPropertyOwner>",
        })

        expect_problem("CGCE-UE4SS-DESCRIPTOR-MISMATCH", "descriptor", function()
            ue4ss_adapter.read_property(adapter, instance, expected)
        end)
        a.equal(0, fake.counters().get_property_value)

        local invalid_port, invalid_fake = fake_ue4ss.new()
        install_property(invalid_fake, expected)
        local invalid_raw = invalid_fake.add_object({
            path = "/Runtime/InvalidScalarOwner",
            type_signature = "Object<ExactPropertyOwner>",
        })
        invalid_fake.set_property_value(invalid_raw, expected.member_name, { raw = "not detached" })
        local invalid_adapter = ue4ss_adapter.new(invalid_port)
        local invalid_instance = ue4ss_adapter.resolve_exact(invalid_adapter, {
            kind = "struct",
            path = "/Runtime/InvalidScalarOwner",
            type_signature = "Object<ExactPropertyOwner>",
        })
        expect_problem("CGCE-UE4SS-READ-VALUE", "value", function()
            ue4ss_adapter.read_property(invalid_adapter, invalid_instance, expected)
        end)
        assert_zero_write_calls(invalid_fake.counters())
    end)

    it("fails closed on property getter secondary errors without leaking them", function()
        local port, fake = fake_ue4ss.new()
        local property = property_descriptor()
        install_property(fake, property)
        local raw_instance = fake.add_object({
            path = "/Runtime/SecondaryErrorOwner",
            type_signature = "Object<ExactPropertyOwner>",
        })
        fake.set_property_value(raw_instance, property.member_name, fake.scalar("hidden"))
        local original_get = port.get_property_value
        port.get_property_value = function(raw_property, raw_object)
            local value = original_get(raw_property, raw_object)
            return value, "secret at 0xDEADC0DE"
        end
        local adapter = ue4ss_adapter.new(port)
        local instance = ue4ss_adapter.resolve_exact(adapter, {
            kind = "struct",
            path = "/Runtime/SecondaryErrorOwner",
            type_signature = "Object<ExactPropertyOwner>",
        })
        local err = expect_problem("CGCE-UE4SS-READ", "property", function()
            ue4ss_adapter.read_property(adapter, instance, property)
        end)
        local encoded = json.encode(err)
        a.equal(nil, encoded:find("DEADC0DE", 1, true))
        a.equal(nil, encoded:find("secret", 1, true))
        assert_zero_write_calls(fake.counters())
    end)
end)

describe("ue4ss_adapter narrow function observation", function()
    it("uses a no-op pre callback plus detached post metadata for /Script/ functions", function()
        local port, fake = fake_ue4ss.new()
        local descriptor = function_descriptor()
        local raw_function = install_exact(fake, descriptor)
        local adapter = ue4ss_adapter.new(port)
        local received = {}
        local delivered_paths = {}
        local observation = ue4ss_adapter.observe_function(adapter, descriptor, function(metadata)
            received[#received + 1] = metadata
            delivered_paths[#delivered_paths + 1] = metadata.path
            metadata.path = "/Forged/InObserver"
            return "must-not-override-engine-return"
        end)

        a.equal("function", type(observation))
        a.deep_equal({ state = "ACTIVE", errors = json.array() },
            ue4ss_adapter.observation_status(adapter, observation))
        a.equal(2, fake.register_log()[1].callback_count)
        fake.fire(descriptor.path, "pre", raw_function, "raw-param")
        a.equal(0, #received)
        fake.fire(descriptor.path, "post", raw_function, "raw-param")
        a.equal(1, #received)
        a.deep_equal({ phase = "post", path = "/Forged/InObserver" }, received[1])
        a.equal(nil, fake.fire_late(1, "post", raw_function, "raw-return"))
        a.equal(2, #received)
        a.deep_equal({ descriptor.path, descriptor.path }, delivered_paths)
        a.deep_equal({ phase = "post", path = "/Forged/InObserver" }, received[2])
        assert_zero_write_calls(fake.counters())
    end)

    it("uses post-only registration for non-/Script/ functions and records observer failures privately", function()
        local port, fake = fake_ue4ss.new()
        local descriptor = function_descriptor("/Game/OwnerSupplied/BlueprintFunction")
        local raw_function = install_exact(fake, descriptor)
        local adapter = ue4ss_adapter.new(port)
        local calls = 0
        local observation = ue4ss_adapter.observe_function(adapter, descriptor, function(metadata)
            calls = calls + 1
            a.deep_equal({ phase = "post", path = descriptor.path }, metadata)
            error("observer secret at 0xBADC0DE")
        end)

        a.equal(1, fake.register_log()[1].callback_count)
        local fire_ok = pcall(fake.fire, descriptor.path, "post", raw_function, "raw-param")
        a.equal(true, fire_ok)
        a.equal(1, calls)
        local status = ue4ss_adapter.observation_status(adapter, observation)
        a.equal("FAILED", status.state)
        a.equal(1, #status.errors)
        a.equal("CGCE-UE4SS-OBSERVER-CALLBACK", status.errors[1].code)
        local encoded = json.encode(status)
        a.equal(nil, encoded:find("BADC0DE", 1, true))
        a.equal(nil, encoded:find("secret", 1, true))

        fake.fire(descriptor.path, "post", raw_function)
        a.equal(1, calls)

        local return_calls = 0
        local multiple_returns = ue4ss_adapter.observe_function(adapter, descriptor, function()
            return_calls = return_calls + 1
            return nil, "discarded value at 0xC0FFEE", raw_function, { discarded = true }
        end)
        fake.fire(descriptor.path, "post", raw_function)
        fake.fire(descriptor.path, "post", raw_function)
        local multiple_status = ue4ss_adapter.observation_status(adapter, multiple_returns)
        a.equal("ACTIVE", multiple_status.state)
        a.equal("[]", json.encode(multiple_status.errors))
        a.equal(2, return_calls)

        local close_ok = ue4ss_adapter.close(adapter)
        a.equal(true, close_ok)
        a.equal("CLOSED", ue4ss_adapter.observation_status(adapter, observation).state)
        a.equal("CLOSED", ue4ss_adapter.observation_status(adapter, multiple_returns).state)
        assert_zero_write_calls(fake.counters())
    end)

    it("fences late and reentrant callbacks and closes individual observations idempotently", function()
        local port, fake = fake_ue4ss.new()
        local descriptor = function_descriptor()
        local raw_function = install_exact(fake, descriptor)
        local adapter = ue4ss_adapter.new(port)
        local calls = 0
        local observation
        observation = ue4ss_adapter.observe_function(adapter, descriptor, function()
            calls = calls + 1
            local ok, errors = ue4ss_adapter.close_observation(adapter, observation)
            a.equal(true, ok)
            a.equal("[]", json.encode(errors))
        end)

        fake.fire(descriptor.path, "post", raw_function)
        a.equal(1, calls)
        a.equal("CLOSED", ue4ss_adapter.observation_status(adapter, observation).state)
        fake.fire_late(1, "post", raw_function)
        a.equal(1, calls)

        local ok, errors = ue4ss_adapter.close_observation(adapter, observation)
        a.equal(true, ok)
        a.equal("[]", json.encode(errors))
        a.equal(1, #fake.unregister_log())
        a.equal(false, pcall(function() rawset(observation, "active", true) end))

        expect_problem("CGCE-UE4SS-OBSERVER-HANDLE", "observer", function()
            ue4ss_adapter.observation_status(adapter, function() end)
        end)
        assert_zero_write_calls(fake.counters())
    end)

    it("invalidates before reverse cleanup, preserves both hook IDs, and continues after failures", function()
        local port, fake = fake_ue4ss.new()
        local descriptors = {
            function_descriptor("/Script/OwnerSupplied.First:Ready"),
            function_descriptor("/Script/OwnerSupplied.Second:Ready"),
            function_descriptor("/Game/OwnerSupplied/ThirdReady"),
        }
        local raw_functions = {}
        for index, descriptor in ipairs(descriptors) do
            raw_functions[index] = install_exact(fake, descriptor)
        end
        local adapter = ue4ss_adapter.new(port)
        local callbacks = 0
        local observations = {}
        for index, descriptor in ipairs(descriptors) do
            observations[index] = ue4ss_adapter.observe_function(adapter, descriptor, function()
                callbacks = callbacks + 1
            end)
        end
        fake.fail_unregister(descriptors[2].path)

        local ok, errors = ue4ss_adapter.close(adapter)
        a.equal(false, ok)
        a.equal(1, #errors)
        a.equal("CGCE-UE4SS-OBSERVER-UNREGISTER", errors[1].code)
        local encoded = json.encode(errors)
        a.equal(nil, encoded:find("DEADBEEF", 1, true))
        a.equal(nil, encoded:find("secret", 1, true))

        local registered = fake.register_log()
        local unregistered = fake.unregister_log()
        a.equal(3, #unregistered)
        for index = 1, 3 do
            local expected = registered[4 - index]
            local actual = unregistered[index]
            a.equal(expected.path, actual.path)
            a.equal(expected.pre_id, actual.pre_id)
            a.equal(expected.post_id, actual.post_id)
        end
        for _, observation in ipairs(observations) do
            a.equal("CLOSED", ue4ss_adapter.observation_status(adapter, observation).state)
        end

        for index = 1, 3 do
            fake.fire_late(index, "post", raw_functions[index])
        end
        a.equal(0, callbacks)
        local second_ok, second_errors = ue4ss_adapter.close(adapter)
        a.equal(false, second_ok)
        a.equal(json.encode(errors), json.encode(second_errors))
        a.equal(3, #fake.unregister_log())
        assert_zero_write_calls(fake.counters())
    end)

    it("preserves individual unregister failures across every idempotent close", function()
        local port, fake = fake_ue4ss.new()
        local descriptor = function_descriptor()
        local raw_function = install_exact(fake, descriptor)
        local adapter = ue4ss_adapter.new(port)
        local calls = 0
        local observation = ue4ss_adapter.observe_function(adapter, descriptor, function()
            calls = calls + 1
        end)
        fake.fail_unregister(descriptor.path)

        local first_ok, first_errors = ue4ss_adapter.close_observation(adapter, observation)
        a.equal(false, first_ok)
        a.equal("CGCE-UE4SS-OBSERVER-UNREGISTER", first_errors[1].code)
        local second_ok, second_errors = ue4ss_adapter.close_observation(adapter, observation)
        a.equal(false, second_ok)
        a.equal(json.encode(first_errors), json.encode(second_errors))
        a.equal(1, #fake.unregister_log())

        local adapter_ok, adapter_errors = ue4ss_adapter.close(adapter)
        a.equal(false, adapter_ok)
        a.equal(json.encode(first_errors), json.encode(adapter_errors))
        local repeated_ok, repeated_errors = ue4ss_adapter.close(adapter)
        a.equal(false, repeated_ok)
        a.equal(json.encode(adapter_errors), json.encode(repeated_errors))
        a.equal(1, #fake.unregister_log())

        fake.fire_late(1, "post", raw_function)
        a.equal(0, calls)
        assert_zero_write_calls(fake.counters())
    end)

    it("poisons uncertain registrations and cleans up full IDs after register secondary errors", function()
        local thrown_port, thrown_fake = fake_ue4ss.new()
        local descriptor = function_descriptor()
        local thrown_raw = install_exact(thrown_fake, descriptor)
        local original_thrown_register = thrown_port.register_hook
        local thrown_calls = 0
        thrown_port.register_hook = function(...)
            original_thrown_register(...)
            error("register throw secret at 0xAA55")
        end
        local thrown_adapter = ue4ss_adapter.new(thrown_port)
        local thrown_error = expect_problem("CGCE-UE4SS-OBSERVER-REGISTER", "descriptor.path", function()
            ue4ss_adapter.observe_function(thrown_adapter, descriptor, function()
                thrown_calls = thrown_calls + 1
            end)
        end)
        a.equal(nil, json.encode(thrown_error):find("AA55", 1, true))
        thrown_fake.fire_late(1, "post", thrown_raw)
        a.equal(0, thrown_calls)
        local thrown_before = thrown_fake.counters().static_find_object
        expect_problem("CGCE-UE4SS-POISONED", "adapter", function()
            ue4ss_adapter.resolve_exact(thrown_adapter, descriptor)
        end)
        expect_problem("CGCE-UE4SS-POISONED", "adapter", function()
            ue4ss_adapter.observe_function(thrown_adapter, descriptor, function() end)
        end)
        a.equal(thrown_before, thrown_fake.counters().static_find_object)
        local thrown_close_ok, thrown_close_errors = ue4ss_adapter.close(thrown_adapter)
        a.equal(false, thrown_close_ok)
        a.equal("CGCE-UE4SS-OBSERVER-CLEANUP-UNCERTAIN", thrown_close_errors[1].code)
        local thrown_close_json = json.encode(thrown_close_errors)
        a.equal(nil, thrown_close_json:find("AA55", 1, true))
        a.equal(nil, thrown_close_json:find("secret", 1, true))
        local thrown_repeat_ok, thrown_repeat_errors = ue4ss_adapter.close(thrown_adapter)
        a.equal(false, thrown_repeat_ok)
        a.equal(thrown_close_json, json.encode(thrown_repeat_errors))

        local partial_port, partial_fake = fake_ue4ss.new()
        local partial_raw = install_exact(partial_fake, descriptor)
        local original_partial_register = partial_port.register_hook
        local partial_calls = 0
        partial_port.register_hook = function(...)
            local pre_id = original_partial_register(...)
            return pre_id, nil
        end
        local partial_adapter = ue4ss_adapter.new(partial_port)
        expect_problem("CGCE-UE4SS-OBSERVER-REGISTER", "descriptor.path", function()
            ue4ss_adapter.observe_function(partial_adapter, descriptor, function()
                partial_calls = partial_calls + 1
            end)
        end)
        a.equal(0, #partial_fake.unregister_log())
        partial_fake.fire_late(1, "post", partial_raw)
        a.equal(0, partial_calls)
        expect_problem("CGCE-UE4SS-POISONED", "adapter", function()
            ue4ss_adapter.resolve_exact(partial_adapter, descriptor)
        end)
        local partial_close_ok, partial_close_errors = ue4ss_adapter.close(partial_adapter)
        a.equal(false, partial_close_ok)
        a.equal("CGCE-UE4SS-OBSERVER-CLEANUP-UNCERTAIN", partial_close_errors[1].code)

        local error_port, error_fake = fake_ue4ss.new()
        install_exact(error_fake, descriptor)
        local original_register = error_port.register_hook
        local error_calls = 0
        error_port.register_hook = function(...)
            local pre_id, post_id = original_register(...)
            return pre_id, post_id, "secondary secret at 0xF00D"
        end
        local error_adapter = ue4ss_adapter.new(error_port)
        local err = expect_problem("CGCE-UE4SS-OBSERVER-REGISTER", "descriptor.path", function()
            ue4ss_adapter.observe_function(error_adapter, descriptor, function()
                error_calls = error_calls + 1
            end)
        end)
        local encoded = json.encode(err)
        a.equal(nil, encoded:find("F00D", 1, true))
        a.equal(nil, encoded:find("secret", 1, true))
        a.equal(1, #error_fake.unregister_log())
        error_fake.fire_late(1, "post")
        a.equal(0, error_calls)
        a.equal("function", type(ue4ss_adapter.resolve_exact(error_adapter, descriptor)))
        local error_close_ok, error_close_errors = ue4ss_adapter.close(error_adapter)
        a.equal(true, error_close_ok)
        a.equal("[]", json.encode(error_close_errors))

        local failed_port, failed_fake = fake_ue4ss.new()
        install_exact(failed_fake, descriptor)
        local failed_register = failed_port.register_hook
        failed_port.register_hook = function(...)
            local pre_id, post_id = failed_register(...)
            return pre_id, post_id, "secondary registration failure"
        end
        failed_fake.fail_unregister(descriptor.path)
        local failed_adapter = ue4ss_adapter.new(failed_port)
        expect_problem("CGCE-UE4SS-OBSERVER-REGISTER", "descriptor.path", function()
            ue4ss_adapter.observe_function(failed_adapter, descriptor, function() end)
        end)
        expect_problem("CGCE-UE4SS-POISONED", "adapter", function()
            ue4ss_adapter.resolve_exact(failed_adapter, descriptor)
        end)
        local failed_close_ok, failed_close_errors = ue4ss_adapter.close(failed_adapter)
        a.equal(false, failed_close_ok)
        a.equal("CGCE-UE4SS-OBSERVER-UNREGISTER", failed_close_errors[1].code)
        local failed_repeat_ok, failed_repeat_errors = ue4ss_adapter.close(failed_adapter)
        a.equal(false, failed_repeat_ok)
        a.equal(json.encode(failed_close_errors), json.encode(failed_repeat_errors))
        a.equal(1, #failed_fake.unregister_log())
        assert_zero_write_calls(thrown_fake.counters())
        assert_zero_write_calls(partial_fake.counters())
        assert_zero_write_calls(error_fake.counters())
        assert_zero_write_calls(failed_fake.counters())
    end)
end)
