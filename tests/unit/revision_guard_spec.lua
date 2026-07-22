local a = require("tests.support.assertions")
local binding_manifest = require("CrossplayGuildChestExpander.Scripts.binding_manifest")
local json = require("CrossplayGuildChestExpander.Scripts.json")
local revision_guard = require("CrossplayGuildChestExpander.Scripts.revision_guard")
local sha256 = require("CrossplayGuildChestExpander.Scripts.sha256")

local logical_kinds = {
    world_ready_function = "function",
    selected_world_class = "class",
    world_id_property = "property",
    guild_manager_class = "class",
    guild_list_property = "property",
    guild_id_property = "property",
    guild_name_property = "property",
    guild_chest_container_id_property = "property",
    guild_chest_class = "class",
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

local function descriptor(logical_name)
    local kind = logical_kinds[logical_name]
    if kind == "property" then
        local owner = "/Exact/Owner/" .. logical_name
        local member = "Member_" .. logical_name
        return {
            kind = kind,
            owner_path = owner,
            member_name = member,
            path = owner .. ":" .. member,
            type_signature = "Property<" .. logical_name .. ">",
        }
    end
    return {
        kind = kind,
        path = "/Exact/" .. logical_name,
        type_signature = kind .. "(" .. logical_name .. ")",
    }
end

local function manifest(kind)
    local symbols = {}
    if kind == "runtime" then
        for logical_name in pairs(logical_kinds) do
            symbols[logical_name] = descriptor(logical_name)
        end
    end
    local value = {
        manifest_version = "1.0",
        kind = kind,
        game_revision = 123456,
        symbols = symbols,
        tested_platform_matrix = kind == "runtime"
            and { "SteamWindows", "PS5", "Mac" }
            or { "unverified-metadata-only" },
    }
    if kind == "runtime" then
        value.source_audit_checksum = string.rep("a", 64)
    end
    value.checksum = sha256.hex(json.encode(value))
    return value, json.encode(value)
end

local function exact_context(manifest_source, overrides)
    local calls = { read = 0, load = 0, inspect = 0, invoke = 0 }
    local context = {}

    context.read_revision = function()
        calls.read = calls.read + 1
        return 123456
    end
    context.load_manifest = function(revision)
        calls.load = calls.load + 1
        a.equal(123456, revision)
        return manifest_source
    end
    context.inspect_descriptor = function(_, expected)
        calls.inspect = calls.inspect + 1
        local actual = {}
        for key, value in pairs(expected) do
            actual[key] = value
        end
        return actual
    end

    for key, value in pairs(overrides or {}) do
        context[key] = value
    end
    return context, calls
end

local function expect_context_error(field, context)
    local ok, err = pcall(revision_guard.check, context)
    a.equal(false, ok)
    a.equal("table", type(err))
    a.equal("CGCE-REV-CONTEXT", err.code)
    a.equal(field, err.field)
    a.equal("string", type(err.detail))
end

local function expect_binding_error(code, field, callback)
    local ok, err = pcall(callback)
    a.equal(false, ok)
    a.equal("table", type(err))
    a.equal(code, err.code)
    a.equal(field, err.field)
    a.equal("string", type(err.detail))
    a.equal(nil, err.detail:find("0x", 1, true))
    return err
end

describe("revision_guard.check", function()
    it("reads live revision exactly once and supports only an exact verified runtime manifest", function()
        local runtime, text = manifest("runtime")
        local context, calls = exact_context(text)
        local result = revision_guard.check(context)

        a.equal("SUPPORTED", result.status)
        a.equal(123456, result.game_revision)
        a.equal("runtime", result.manifest_kind)
        a.equal(runtime.checksum, result.manifest_checksum)
        a.equal(false, result.mutation_capability)
        a.equal("[]", json.encode(result.errors))
        a.equal(1, calls.read)
        a.equal(1, calls.load)
        a.equal(27, calls.inspect)
        a.equal(0, calls.invoke)
    end)

    it("returns an opaque verified binding session only for a supported runtime manifest", function()
        local runtime, text = manifest("runtime")
        local context, calls = exact_context(text)
        local result, session = revision_guard.check(context)

        a.equal("SUPPORTED", result.status)
        a.equal("function", type(session))
        a.equal(nil, getmetatable(session))

        local metadata = revision_guard.binding_metadata(session)
        a.deep_equal({
            game_revision = result.game_revision,
            manifest_checksum = result.manifest_checksum,
            source_audit_checksum = runtime.source_audit_checksum,
            manifest_kind = result.manifest_kind,
        }, metadata)

        metadata.game_revision = 1
        metadata.manifest_checksum = string.rep("f", 64)
        a.deep_equal({
            game_revision = 123456,
            manifest_checksum = runtime.checksum,
            source_audit_checksum = runtime.source_audit_checksum,
            manifest_kind = "runtime",
        }, revision_guard.binding_metadata(session))
        a.equal(1, calls.read)
        a.equal(1, calls.load)
        a.equal(27, calls.inspect)
        a.equal(0, calls.invoke)
    end)

    it("returns no binding session for blocked or unsupported outcomes", function()
        local unsupported_context = exact_context(nil)
        local unsupported, unsupported_session = revision_guard.check(unsupported_context)
        a.equal("UNSUPPORTED", unsupported.status)
        a.equal(nil, unsupported_session)

        local blocked_context = exact_context(nil, {
            read_revision = function()
                return nil
            end,
        })
        local blocked, blocked_session = revision_guard.check(blocked_context)
        a.equal("BLOCKED", blocked.status)
        a.equal(nil, blocked_session)

        unsupported.status = "SUPPORTED"
        unsupported.manifest_kind = "runtime"
        unsupported.manifest_checksum = string.rep("a", 64)
        expect_binding_error("CGCE-REV-SESSION", "session", function()
            revision_guard.binding_metadata(unsupported)
        end)
    end)

    it("invalidates prior sessions across supported, blocked, and unsupported rechecks", function()
        local runtime, runtime_text = manifest("runtime")

        local first_result, first_session = revision_guard.check(exact_context(runtime_text))
        a.equal("SUPPORTED", first_result.status)
        a.equal(runtime.checksum, revision_guard.binding_metadata(first_session).manifest_checksum)

        local blocked, blocked_session = revision_guard.check(exact_context(nil, {
            read_revision = function()
                return nil
            end,
        }))
        a.equal("BLOCKED", blocked.status)
        a.equal(nil, blocked_session)
        expect_binding_error("CGCE-REV-SESSION", "session", function()
            revision_guard.binding_metadata(first_session)
        end)
        expect_binding_error("CGCE-REV-SESSION", "session", function()
            revision_guard.descriptor(first_session, "world_id_property")
        end)

        local second_result, second_session = revision_guard.check(exact_context(runtime_text))
        a.equal("SUPPORTED", second_result.status)
        a.equal(runtime.checksum, revision_guard.binding_metadata(second_session).manifest_checksum)
        local unsupported, unsupported_session = revision_guard.check(exact_context(nil))
        a.equal("UNSUPPORTED", unsupported.status)
        a.equal(nil, unsupported_session)
        expect_binding_error("CGCE-REV-SESSION", "session", function()
            revision_guard.binding_metadata(second_session)
        end)
        expect_binding_error("CGCE-REV-SESSION", "session", function()
            revision_guard.descriptor(second_session, "world_id_property")
        end)

        local third_result, third_session = revision_guard.check(exact_context(runtime_text))
        a.equal("SUPPORTED", third_result.status)
        local fourth_result, fourth_session = revision_guard.check(exact_context(runtime_text))
        a.equal("SUPPORTED", fourth_result.status)
        expect_binding_error("CGCE-REV-SESSION", "session", function()
            revision_guard.binding_metadata(third_session)
        end)
        expect_binding_error("CGCE-REV-SESSION", "session", function()
            revision_guard.descriptor(third_session, "world_id_property")
        end)
        a.equal(runtime.checksum, revision_guard.binding_metadata(fourth_session).manifest_checksum)
        a.deep_equal(
            descriptor("world_id_property"),
            revision_guard.descriptor(fourth_session, "world_id_property")
        )

        expect_binding_error("CGCE-REV-SESSION", "session", function()
            revision_guard.binding_metadata(first_session)
        end)
    end)

    it("invalidates the current session before validating a new check context", function()
        local _, runtime_text = manifest("runtime")
        local _, session = revision_guard.check(exact_context(runtime_text))
        a.equal("runtime", revision_guard.binding_metadata(session).manifest_kind)

        expect_context_error("context", nil)
        expect_binding_error("CGCE-REV-SESSION", "session", function()
            revision_guard.binding_metadata(session)
        end)
    end)

    it("fails closed when a reentrant check supersedes the current validation epoch", function()
        local runtime, runtime_text = manifest("runtime")
        local outer_context, outer_calls = exact_context(runtime_text)
        local nested_result
        local nested_session
        local nested_once = false
        outer_context.inspect_descriptor = function(_, expected)
            outer_calls.inspect = outer_calls.inspect + 1
            if not nested_once then
                nested_once = true
                local nested_context = exact_context(runtime_text)
                nested_result, nested_session = revision_guard.check(nested_context)
            end
            local actual = {}
            for key, value in pairs(expected) do
                actual[key] = value
            end
            return actual
        end

        local outer_result, outer_session = revision_guard.check(outer_context)

        a.equal("BLOCKED", outer_result.status)
        a.equal("runtime", outer_result.manifest_kind)
        a.equal(runtime.checksum, outer_result.manifest_checksum)
        a.equal("CGCE-REV-CHECK-SUPERSEDED", outer_result.errors[1].code)
        a.equal("session", outer_result.errors[1].field)
        a.equal(nil, outer_session)
        a.equal(27, outer_calls.inspect)
        a.equal("SUPPORTED", nested_result.status)
        a.equal(runtime.checksum, revision_guard.binding_metadata(nested_session).manifest_checksum)
    end)

    it("serves fresh descriptors from the privately verified manifest snapshot", function()
        local _, text = manifest("runtime")
        local context, calls = exact_context(text)
        local inspected_class
        context.inspect_descriptor = function(logical_name, expected)
            calls.inspect = calls.inspect + 1
            local actual = {}
            for key, value in pairs(expected) do
                actual[key] = value
            end
            if logical_name == "guild_chest_class" then
                inspected_class = expected
            end
            return actual
        end

        local result, session = revision_guard.check(context)
        a.equal("SUPPORTED", result.status)
        inspected_class.path = "/Mutated/InspectorCopy"
        inspected_class.type_signature = "Mutated"

        local class = revision_guard.descriptor(session, "guild_chest_class")
        a.deep_equal(descriptor("guild_chest_class"), class)
        class.path = "/Mutated/CallerCopy"
        class.type_signature = "Mutated"
        a.deep_equal(
            descriptor("guild_chest_class"),
            revision_guard.descriptor(session, "guild_chest_class")
        )

        local property = revision_guard.descriptor(session, "world_id_property")
        a.deep_equal(descriptor("world_id_property"), property)
        property.owner_path = "/Mutated/Owner"
        property.member_name = "MutatedMember"
        a.deep_equal(
            descriptor("world_id_property"),
            revision_guard.descriptor(session, "world_id_property")
        )
        a.equal(27, calls.inspect)
        a.equal(0, calls.invoke)
    end)

    it("rejects forged sessions and unknown logical names without rendering supplied values", function()
        local _, text = manifest("runtime")
        local context = exact_context(text)
        local _, session = revision_guard.check(context)

        local hostile = setmetatable({}, {
            __tostring = function()
                error("must not render hostile value")
            end,
        })
        for _, forged in ipairs({ {}, function() end, "forged", false, hostile }) do
            expect_binding_error("CGCE-REV-SESSION", "session", function()
                revision_guard.binding_metadata(forged)
            end)
        end
        expect_binding_error("CGCE-REV-SESSION", "session", function()
            revision_guard.descriptor(nil, "world_id_property")
        end)

        local unknown = expect_binding_error("CGCE-REV-LOGICAL-NAME", "logical_name", function()
            revision_guard.descriptor(session, "secret-unknown-logical-name")
        end)
        a.equal(nil, unknown.detail:find("secret", 1, true))
        expect_binding_error("CGCE-REV-LOGICAL-NAME", "logical_name", function()
            revision_guard.descriptor(session, hostile)
        end)
    end)

    it("keeps session authority private from mutable outcomes and public module slots", function()
        local runtime, text = manifest("runtime")
        local context = exact_context(text)
        local original_metadata = revision_guard.binding_metadata
        local original_descriptor = revision_guard.descriptor
        revision_guard.binding_metadata = function()
            return {
                game_revision = 1,
                manifest_checksum = string.rep("f", 64),
            }
        end
        revision_guard.descriptor = function()
            return descriptor("world_ready_function")
        end

        local result, session = revision_guard.check(context)

        revision_guard.binding_metadata = original_metadata
        revision_guard.descriptor = original_descriptor
        result.status = "BLOCKED"
        result.game_revision = 1
        result.manifest_kind = "discovery"
        result.manifest_checksum = string.rep("f", 64)

        a.deep_equal({
            game_revision = 123456,
            manifest_checksum = runtime.checksum,
            source_audit_checksum = runtime.source_audit_checksum,
            manifest_kind = "runtime",
        }, original_metadata(session))
        a.deep_equal(
            descriptor("world_ready_function"),
            original_descriptor(session, "world_ready_function")
        )
    end)

    it("classifies a missing exact manifest as unsupported after a valid live read", function()
        local context, calls = exact_context(nil)
        local result = revision_guard.check(context)

        a.equal("UNSUPPORTED", result.status)
        a.equal(123456, result.game_revision)
        a.equal(nil, result.manifest_kind)
        a.equal(nil, result.manifest_checksum)
        a.equal(false, result.mutation_capability)
        a.equal("CGCE-REV-MANIFEST-NOT-FOUND", result.errors[1].code)
        a.equal(1, calls.read)
        a.equal(1, calls.load)
        a.equal(0, calls.inspect)
    end)

    it("keeps an exact empty-symbol discovery manifest unsupported and incapable", function()
        local discovery, text = manifest("discovery")
        local context, calls = exact_context(text)
        local result = revision_guard.check(context)

        a.equal("UNSUPPORTED", result.status)
        a.equal("discovery", result.manifest_kind)
        a.equal(discovery.checksum, result.manifest_checksum)
        a.equal(false, result.mutation_capability)
        a.equal("CGCE-REV-RUNTIME-MANIFEST-UNAVAILABLE", result.errors[1].code)
        a.equal(1, calls.read)
        a.equal(0, calls.inspect)
    end)

    it("blocks unavailable, exceptional, non-integer, and non-positive live revisions", function()
        local readers = {
            function() return nil end,
            function() return 0 end,
            function() return 1.5 end,
            function() error("secret live reader failure") end,
        }
        for _, reader in ipairs(readers) do
            local context, calls = exact_context(nil, { read_revision = reader })
            local result = revision_guard.check(context)
            a.equal("BLOCKED", result.status)
            a.equal(nil, result.game_revision)
            a.equal(false, result.mutation_capability)
            a.equal("CGCE-REV-LIVE-REVISION-UNAVAILABLE", result.errors[1].code)
            a.equal(nil, result.errors[1].detail:match("secret"))
            a.equal(0, calls.load)
            a.equal(0, calls.inspect)
        end
    end)

    it("blocks duplicate, malformed, checksum-invalid, and MinRevision-bearing manifests", function()
        local _, runtime_text = manifest("runtime")
        local duplicate_context = exact_context({ runtime_text, runtime_text })
        local duplicate = revision_guard.check(duplicate_context)
        a.equal("BLOCKED", duplicate.status)
        a.equal("CGCE-REV-MANIFEST-DUPLICATE", duplicate.errors[1].code)

        for _, empty_source in ipairs({ {}, json.array() }) do
            local empty_context = exact_context(empty_source)
            local empty_result = revision_guard.check(empty_context)
            a.equal("BLOCKED", empty_result.status)
            a.equal("CGCE-REV-MANIFEST-LOAD", empty_result.errors[1].code)
        end

        local malformed_context = exact_context("not JSON")
        local malformed = revision_guard.check(malformed_context)
        a.equal("BLOCKED", malformed.status)
        a.equal("CGCE-MAN-JSON", malformed.errors[1].code)

        local tampered = json.decode(runtime_text)
        tampered.game_revision = tampered.game_revision + 1
        local checksum_context = exact_context(json.encode(tampered))
        local checksum_invalid = revision_guard.check(checksum_context)
        a.equal("BLOCKED", checksum_invalid.status)
        a.equal("CGCE-MAN-CHECKSUM", checksum_invalid.errors[1].code)

        local min_revision = json.decode(runtime_text)
        min_revision.checksum = nil
        min_revision.MinRevision = 1
        min_revision.checksum = sha256.hex(json.encode(min_revision))
        local min_context = exact_context(json.encode(min_revision))
        local min_result = revision_guard.check(min_context)
        a.equal("BLOCKED", min_result.status)
        a.equal("CGCE-MAN-UNKNOWN-KEY", min_result.errors[1].code)
        a.equal("MinRevision", min_result.errors[1].field)
    end)

    it("blocks exact manifest revision and reflected type mismatch without invoking candidates", function()
        local _, runtime_text = manifest("runtime")
        local wrong_revision = json.decode(runtime_text)
        wrong_revision.checksum = nil
        wrong_revision.game_revision = 123457
        wrong_revision.checksum = sha256.hex(json.encode(wrong_revision))
        local revision_context, revision_calls = exact_context(json.encode(wrong_revision))
        local revision_result = revision_guard.check(revision_context)
        a.equal("BLOCKED", revision_result.status)
        a.equal("CGCE-MAN-REVISION", revision_result.errors[1].code)
        a.equal(0, revision_calls.inspect)

        local type_context, type_calls = exact_context(runtime_text)
        type_context.inspect_descriptor = function(logical_name, expected)
            type_calls.inspect = type_calls.inspect + 1
            local actual = {}
            for key, value in pairs(expected) do
                actual[key] = value
            end
            if logical_name == "guild_chest_class" then
                actual.path = "/Exact/WrongClass"
            end
            return actual
        end
        local type_result = revision_guard.check(type_context)
        a.equal("BLOCKED", type_result.status)
        a.equal("CGCE-MAN-TYPE-MISMATCH", type_result.errors[1].code)
        a.equal(27, type_calls.inspect)
        a.equal(0, type_calls.invoke)
    end)

    it("sanitizes load and inspect failures and never exposes exception text", function()
        local load_context = exact_context(nil, {
            load_manifest = function()
                error("secret manifest location")
            end,
        })
        local load_result = revision_guard.check(load_context)
        a.equal("BLOCKED", load_result.status)
        a.equal("CGCE-REV-MANIFEST-LOAD", load_result.errors[1].code)
        a.equal(nil, load_result.errors[1].detail:match("secret"))

        local _, runtime_text = manifest("runtime")
        local inspect_context = exact_context(runtime_text, {
            inspect_descriptor = function()
                error("secret reflected address")
            end,
        })
        local inspect_result = revision_guard.check(inspect_context)
        a.equal("BLOCKED", inspect_result.status)
        a.equal("CGCE-MAN-TYPE-MISMATCH", inspect_result.errors[1].code)
        a.equal(nil, inspect_result.errors[1].detail:match("secret"))
    end)

    it("treats secondary read, load, and inspect errors as sanitized failures", function()
        local _, runtime_text = manifest("runtime")
        local read_calls = 0
        local read_context, read_port_calls = exact_context(runtime_text, {
            read_revision = function()
                read_calls = read_calls + 1
                return 123456, "secret revision warning"
            end,
        })
        local read_result = revision_guard.check(read_context)
        a.equal("BLOCKED", read_result.status)
        a.equal("CGCE-REV-LIVE-REVISION-UNAVAILABLE", read_result.errors[1].code)
        a.equal(nil, read_result.errors[1].detail:match("secret"))
        a.equal(1, read_calls)
        a.equal(0, read_port_calls.load)

        local load_context = exact_context(runtime_text, {
            load_manifest = function()
                return runtime_text, "secret duplicate lookup warning"
            end,
        })
        local load_result = revision_guard.check(load_context)
        a.equal("BLOCKED", load_result.status)
        a.equal("CGCE-REV-MANIFEST-LOAD", load_result.errors[1].code)
        a.equal(nil, load_result.errors[1].detail:match("secret"))

        local inspect_context = exact_context(runtime_text, {
            inspect_descriptor = function(_, expected)
                local actual = {}
                for key, value in pairs(expected) do
                    actual[key] = value
                end
                return actual, "secret reflection warning"
            end,
        })
        local inspect_result = revision_guard.check(inspect_context)
        a.equal("BLOCKED", inspect_result.status)
        a.equal("CGCE-MAN-TYPE-MISMATCH", inspect_result.errors[1].code)
        a.equal(nil, inspect_result.errors[1].detail:match("secret"))
    end)

    it("requires an exact plain context and copies its ports before callbacks", function()
        local _, runtime_text = manifest("runtime")
        local with_unknown = exact_context(runtime_text)
        with_unknown.MinRevision = 1
        expect_context_error("MinRevision", with_unknown)

        local with_metatable = exact_context(runtime_text)
        setmetatable(with_metatable, {})
        expect_context_error("context", with_metatable)

        local missing_reader = exact_context(runtime_text)
        missing_reader.read_revision = nil
        expect_context_error("read_revision", missing_reader)

        local context, calls = exact_context(runtime_text)
        context.load_manifest = function()
            calls.load = calls.load + 1
            context.inspect_descriptor = function()
                error("must not replace captured inspector")
            end
            context.read_revision = function()
                error("must not read revision twice")
            end
            return runtime_text
        end
        local result = revision_guard.check(context)
        a.equal("SUPPORTED", result.status)
        a.equal(1, calls.read)
        a.equal(27, calls.inspect)
    end)

    it("captures binding validation functions so public module slot reassignment cannot grant authority", function()
        local _, runtime_text = manifest("runtime")
        local context = exact_context(runtime_text)
        local original_parse = binding_manifest.parse
        local original_verify = binding_manifest.verify_types
        binding_manifest.parse = function()
            return { kind = "runtime", checksum = string.rep("f", 64) }
        end
        binding_manifest.verify_types = function()
            return true, json.array()
        end

        local result = revision_guard.check(context)

        binding_manifest.parse = original_parse
        binding_manifest.verify_types = original_verify
        a.equal("SUPPORTED", result.status)
        a.equal(false, result.manifest_checksum == string.rep("f", 64))
    end)
end)
