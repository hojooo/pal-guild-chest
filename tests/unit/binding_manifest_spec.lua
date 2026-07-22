local a = require("tests.support.assertions")
local binding_manifest = require("CrossplayGuildChestExpander.Scripts.binding_manifest")
local constants = require("CrossplayGuildChestExpander.Scripts.constants")
local json = require("CrossplayGuildChestExpander.Scripts.json")
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

local function logical_count()
    local count = 0
    for _ in pairs(logical_kinds) do
        count = count + 1
    end
    return count
end

local function descriptor(logical_name)
    local kind = assert(logical_kinds[logical_name])
    if kind == "property" then
        local owner_path = "/Exact/Owner/" .. logical_name
        local member_name = "Member_" .. logical_name
        return {
            kind = kind,
            owner_path = owner_path,
            member_name = member_name,
            path = owner_path .. ":" .. member_name,
            type_signature = "Property<" .. logical_name .. ">",
        }
    end
    return {
        kind = kind,
        path = "/Exact/" .. logical_name,
        type_signature = kind .. "(" .. logical_name .. ")",
    }
end

local function runtime_manifest()
    local symbols = {}
    for logical_name in pairs(logical_kinds) do
        symbols[logical_name] = descriptor(logical_name)
    end
    return {
        manifest_version = "1.0",
        kind = "runtime",
        game_revision = 123456,
        source_audit_checksum = string.rep("a", 64),
        symbols = symbols,
        tested_platform_matrix = { "SteamWindows", "PS5", "Mac" },
    }
end

local function discovery_manifest()
    return {
        manifest_version = "1.0",
        kind = "discovery",
        game_revision = 123456,
        symbols = {},
        tested_platform_matrix = { "unverified-metadata-only" },
    }
end

local function encode_with_checksum(value)
    value.checksum = nil
    value.checksum = sha256.hex(json.encode(value))
    return json.encode(value)
end

local function expect_parse_error(code, field, value)
    local ok, err = pcall(binding_manifest.parse, encode_with_checksum(value))
    a.equal(false, ok)
    a.equal("table", type(err))
    a.equal(code, err.code)
    a.equal(field, err.field)
    a.equal("string", type(err.detail))
end

local function matching_adapter(revision)
    local calls = { inspected = 0, invoked = 0 }
    local adapter = {}

    function adapter.read_revision()
        return revision or 123456
    end

    function adapter.inspect_descriptor(_, expected)
        calls.inspected = calls.inspected + 1
        local actual = {}
        for key, value in pairs(expected) do
            actual[key] = value
        end
        return actual
    end

    function adapter.invoke()
        calls.invoked = calls.invoked + 1
        error("candidate invocation is forbidden")
    end

    return adapter, calls
end

describe("binding_manifest.parse", function()
    it("keeps an empty-symbol discovery manifest incapable", function()
        local parsed = binding_manifest.parse(encode_with_checksum(discovery_manifest()))
        a.equal("discovery", parsed.kind)
        a.deep_equal({}, parsed.symbols)
        a.deep_equal({ "unverified-metadata-only" }, parsed.tested_platform_matrix)
        a.equal(nil, parsed.certified_target_slots)
        a.equal(nil, parsed.mutation_capability)
    end)

    it("rejects discovery symbols and runtime-only fields", function()
        local with_symbol = discovery_manifest()
        with_symbol.symbols.world_ready_function = descriptor("world_ready_function")
        expect_parse_error("CGCE-MAN-DISCOVERY-SYMBOLS", "symbols", with_symbol)

        local with_audit = discovery_manifest()
        with_audit.source_audit_checksum = string.rep("a", 64)
        expect_parse_error("CGCE-MAN-UNKNOWN-KEY", "source_audit_checksum", with_audit)

        local array_symbols = discovery_manifest()
        array_symbols.symbols = json.decode("[]")
        expect_parse_error("CGCE-MAN-TYPE", "symbols", array_symbols)
    end)

    it("requires every world, guild, chest, and snapshot projection descriptor", function()
        local parsed = binding_manifest.parse(encode_with_checksum(runtime_manifest()))
        a.equal("runtime", parsed.kind)
        a.equal(123456, parsed.game_revision)
        for logical_name, kind in pairs(logical_kinds) do
            a.equal(kind, parsed.symbols[logical_name].kind)
        end

        for _, logical_name in ipairs({
            "world_id_property",
            "guild_name_property",
            "guild_chest_class",
            "container_id_property",
            "slot_occupancy_discriminator_property",
            "item_static_id_property",
            "item_dynamic_guid_property",
            "item_quantity_property",
            "item_durability_property",
            "item_metadata_hash_inputs_property",
        }) do
            local missing = runtime_manifest()
            missing.symbols[logical_name] = nil
            expect_parse_error("CGCE-MAN-MISSING-SYMBOL", "symbols." .. logical_name, missing)
        end
    end)

    it("requires property owner, member, observed full path, and signature", function()
        for _, field in ipairs({ "owner_path", "member_name", "path", "type_signature" }) do
            local missing = runtime_manifest()
            missing.symbols.world_id_property[field] = nil
            expect_parse_error(
                "CGCE-MAN-DESCRIPTOR-TYPE",
                "symbols.world_id_property." .. field,
                missing
            )
        end

        local owner_on_class = runtime_manifest()
        owner_on_class.symbols.guild_chest_class.owner_path = "/Exact/Unexpected"
        expect_parse_error(
            "CGCE-MAN-DESCRIPTOR-KEY",
            "symbols.guild_chest_class.owner_path",
            owner_on_class
        )
    end)

    it("rejects relative, fuzzy, wildcard, control-bearing, and malformed identities", function()
        local scenarios = {
            { symbol = "guild_chest_class", field = "path", value = "Relative/Class" },
            { symbol = "guild_chest_class", field = "path", value = "/Exact/*" },
            { symbol = "guild_chest_class", field = "path", value = "/Exact/Fuzzy...Class" },
            { symbol = "world_id_property", field = "owner_path", value = "/Exact/Owner\nInjected" },
            { symbol = "world_id_property", field = "member_name", value = "Owner.Member" },
            { symbol = "world_id_property", field = "type_signature", value = "Property<?>" },
            { symbol = "guild_chest_class", field = "type_signature", value = "Class<*>" },
            { symbol = "guild_chest_class", field = "type_signature", value = "Class<[A-Z]>" },
        }
        for _, scenario in ipairs(scenarios) do
            local value = runtime_manifest()
            value.symbols[scenario.symbol][scenario.field] = scenario.value
            expect_parse_error(
                "CGCE-MAN-DESCRIPTOR-TYPE",
                "symbols." .. scenario.symbol .. "." .. scenario.field,
                value
            )
        end
    end)

    it("treats a typed pointer marker as signature syntax rather than a wildcard", function()
        local value = runtime_manifest()
        value.symbols.guild_chest_class.type_signature = "Class<UObject*>"
        local parsed = binding_manifest.parse(encode_with_checksum(value))
        a.equal("Class<UObject*>", parsed.symbols.guild_chest_class.type_signature)
    end)

    it("requires every logical symbol and rejects unknown logical symbols deterministically", function()
        local missing = runtime_manifest()
        missing.symbols.fatal_safe_stop_function = nil
        expect_parse_error("CGCE-MAN-MISSING-SYMBOL", "symbols.fatal_safe_stop_function", missing)

        local unknown = runtime_manifest()
        unknown.symbols.z_fuzzy_candidate = descriptor("world_ready_function")
        unknown.symbols.a_fuzzy_candidate = descriptor("world_ready_function")
        expect_parse_error("CGCE-MAN-UNKNOWN-SYMBOL", "symbols.a_fuzzy_candidate", unknown)

        local invocation_based_canonicalizer = runtime_manifest()
        invocation_based_canonicalizer.symbols.item_durability_canonicalization_function =
            descriptor("world_ready_function")
        expect_parse_error(
            "CGCE-MAN-UNKNOWN-SYMBOL",
            "symbols.item_durability_canonicalization_function",
            invocation_based_canonicalizer
        )
    end)

    it("enforces strict descriptor keys, kinds, and non-empty signatures", function()
        local extra = runtime_manifest()
        extra.symbols.resize_function.candidate = "never invoke"
        expect_parse_error("CGCE-MAN-DESCRIPTOR-KEY", "symbols.resize_function.candidate", extra)

        local wrong_kind = runtime_manifest()
        wrong_kind.symbols.guild_manager_class.kind = "function"
        expect_parse_error("CGCE-MAN-DESCRIPTOR-KIND", "symbols.guild_manager_class.kind", wrong_kind)

        local empty_signature = runtime_manifest()
        empty_signature.symbols.slot_array_property.type_signature = ""
        expect_parse_error("CGCE-MAN-DESCRIPTOR-TYPE", "symbols.slot_array_property.type_signature", empty_signature)
    end)

    it("allows only exact top-level keys and never accepts MinRevision", function()
        local value = runtime_manifest()
        value.MinRevision = 100000
        expect_parse_error("CGCE-MAN-UNKNOWN-KEY", "MinRevision", value)
    end)

    it("requires a valid self-checksum over canonical JSON without checksum", function()
        local text = encode_with_checksum(runtime_manifest())
        local decoded = json.decode(text)
        decoded.game_revision = decoded.game_revision + 1

        local ok, err = pcall(binding_manifest.parse, json.encode(decoded))
        a.equal(false, ok)
        a.equal("CGCE-MAN-CHECKSUM", err.code)
        a.equal("checksum", err.field)
    end)
end)

describe("binding_manifest.verify_types", function()
    it("requires an authority-bearing parsed binding manifest", function()
        local forged = runtime_manifest()
        forged.checksum = sha256.hex(json.encode(forged))
        local adapter, calls = matching_adapter()
        local ok, errors = binding_manifest.verify_types(forged, adapter)

        a.equal(false, ok)
        a.equal("CGCE-MAN-AUTHORITY", errors[1].code)
        a.equal("manifest", errors[1].field)
        a.equal("[", json.encode(errors):sub(1, 1))
        a.equal(0, calls.inspected)
        a.equal(0, calls.invoked)
    end)

    it("requires exact live revision equality before inspecting descriptors", function()
        local manifest = binding_manifest.parse(encode_with_checksum(runtime_manifest()))
        local adapter, calls = matching_adapter(123457)
        local ok, errors = binding_manifest.verify_types(manifest, adapter)

        a.equal(false, ok)
        a.equal("CGCE-MAN-REVISION", errors[1].code)
        a.equal("game_revision", errors[1].field)
        a.equal(0, calls.inspected)
        a.equal(0, calls.invoked)
    end)

    it("compares every reflected property identity field without invoking candidates", function()
        local manifest = binding_manifest.parse(encode_with_checksum(runtime_manifest()))
        local adapter, calls = matching_adapter()
        local original = adapter.inspect_descriptor
        function adapter.inspect_descriptor(logical_name, expected)
            local actual = original(logical_name, expected)
            if logical_name == "world_id_property" then
                actual.owner_path = "/Exact/WrongOwner"
            end
            return actual
        end

        local ok, errors = binding_manifest.verify_types(manifest, adapter)
        a.equal(false, ok)
        a.equal("CGCE-MAN-TYPE-MISMATCH", errors[1].code)
        a.equal("symbols.world_id_property", errors[1].field)
        a.equal(logical_count(), calls.inspected)
        a.equal(0, calls.invoked)
    end)

    it("does not let an inspector mutate expected descriptors into a match", function()
        local manifest = binding_manifest.parse(encode_with_checksum(runtime_manifest()))
        local adapter, calls = matching_adapter()
        function adapter.inspect_descriptor(logical_name, expected)
            calls.inspected = calls.inspected + 1
            if logical_name == "item_quantity_property" then
                expected.path = "/Exact/Forged"
                return expected
            end
            local actual = {}
            for key, value in pairs(expected) do
                actual[key] = value
            end
            return actual
        end

        local ok, errors = binding_manifest.verify_types(manifest, adapter)
        a.equal(false, ok)
        a.equal("CGCE-MAN-TYPE-MISMATCH", errors[1].code)
        a.equal("symbols.item_quantity_property", errors[1].field)
        a.equal(0, calls.invoked)
    end)

    it("verifies only the private parse-time snapshot after caller mutation", function()
        local manifest = binding_manifest.parse(encode_with_checksum(runtime_manifest()))
        manifest.kind = "discovery"
        manifest.game_revision = 1
        manifest.checksum = string.rep("f", 64)
        manifest.symbols.world_id_property.path = "/Exact/ForgedAfterParse"

        local adapter, calls = matching_adapter()
        local ok, errors = binding_manifest.verify_types(manifest, adapter)

        a.equal(true, ok)
        a.equal("[]", json.encode(errors))
        a.equal(logical_count(), calls.inspected)
        a.equal(0, calls.invoked)
    end)

    it("captures checksum, JSON, version, and binding dispatch dependencies privately", function()
        local original_parse = binding_manifest.parse
        local original_verify = binding_manifest.verify_types
        local original_encode = json.encode
        local original_decode = json.decode
        local original_sha256 = sha256.hex
        local original_version = constants.versions.manifest
        local first = original_parse(encode_with_checksum(runtime_manifest()))
        local second_text = encode_with_checksum(runtime_manifest())
        local forged = original_decode(second_text)

        json.encode = function() return "{}" end
        json.decode = function() return { kind = "discovery", symbols = {} } end
        sha256.hex = function() return string.rep("f", 64) end
        constants.versions.manifest = "forged"
        binding_manifest.parse = function() return forged end
        binding_manifest.verify_types = function() return true, json.array() end

        local test_ok, test_error = xpcall(function()
            local second = original_parse(second_text)
            local adapter, calls = matching_adapter()
            local first_ok = original_verify(first, adapter)
            local second_ok = original_verify(second, adapter)
            local forged_ok, forged_errors = original_verify(forged, adapter)

            a.equal(true, first_ok)
            a.equal(true, second_ok)
            a.equal(false, forged_ok)
            a.equal("CGCE-MAN-AUTHORITY", forged_errors[1].code)
            a.equal(logical_count() * 2, calls.inspected)
            a.equal(0, calls.invoked)
        end, debug.traceback)

        binding_manifest.parse = original_parse
        binding_manifest.verify_types = original_verify
        json.encode = original_encode
        json.decode = original_decode
        sha256.hex = original_sha256
        constants.versions.manifest = original_version
        if not test_ok then
            error(test_error)
        end
    end)

    it("treats secondary port errors as failures without exposing their text", function()
        local manifest = binding_manifest.parse(encode_with_checksum(runtime_manifest()))
        local revision_ok, revision_errors = binding_manifest.verify_types(manifest, {
            read_revision = function()
                return 123456, "secret revision error"
            end,
            inspect_descriptor = function()
                error("must not inspect after revision reader error")
            end,
        })
        a.equal(false, revision_ok)
        a.equal("CGCE-MAN-REVISION", revision_errors[1].code)
        a.equal(nil, revision_errors[1].detail:match("secret"))

        local adapter, calls = matching_adapter()
        local original = adapter.inspect_descriptor
        function adapter.inspect_descriptor(logical_name, expected)
            local actual = original(logical_name, expected)
            if logical_name == "guild_chest_class" then
                return actual, "secret reflection error"
            end
            return actual
        end
        local inspect_ok, inspect_errors = binding_manifest.verify_types(manifest, adapter)
        a.equal(false, inspect_ok)
        a.equal("CGCE-MAN-TYPE-MISMATCH", inspect_errors[1].code)
        a.equal("symbols.guild_chest_class", inspect_errors[1].field)
        a.equal(nil, inspect_errors[1].detail:match("secret"))
        a.equal(0, calls.invoked)
    end)

    it("passes exact reflected descriptors and keeps discovery incapable", function()
        local runtime = binding_manifest.parse(encode_with_checksum(runtime_manifest()))
        local adapter, calls = matching_adapter()
        local runtime_ok, runtime_errors = binding_manifest.verify_types(runtime, adapter)
        a.equal(true, runtime_ok)
        a.equal("[]", json.encode(runtime_errors))
        a.equal(logical_count(), calls.inspected)
        a.equal(0, calls.invoked)

        local discovery = binding_manifest.parse(encode_with_checksum(discovery_manifest()))
        local discovery_ok, discovery_errors = binding_manifest.verify_types(discovery, adapter)
        a.equal(true, discovery_ok)
        a.equal("[]", json.encode(discovery_errors))
        a.equal(logical_count(), calls.inspected)
        a.equal(0, calls.invoked)
    end)
end)
