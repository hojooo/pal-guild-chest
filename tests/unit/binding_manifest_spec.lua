local a = require("tests.support.assertions")
local binding_manifest = require("CrossplayGuildChestExpander.Scripts.binding_manifest")
local json = require("CrossplayGuildChestExpander.Scripts.json")
local sha256 = require("CrossplayGuildChestExpander.Scripts.sha256")

local logical_kinds = {
    world_ready_function = "function",
    guild_manager_class = "class",
    guild_list_property = "property",
    guild_id_property = "property",
    guild_chest_container_id_property = "property",
    container_manager_class = "class",
    find_container_function = "function",
    container_owner_guild_id_property = "property",
    slot_array_property = "property",
    empty_slot_type = "struct",
    resize_function = "function",
    mark_dirty_function = "function",
    replicate_function = "function",
    new_guild_function = "function",
    container_in_use_function = "function",
    fatal_safe_stop_function = "function",
}

local function descriptor(logical_name)
    return {
        kind = logical_kinds[logical_name],
        path = "/Exact/" .. logical_name,
        type_signature = logical_kinds[logical_name] .. "(" .. logical_name .. ")",
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

    function adapter.inspect_descriptor(logical_name, expected)
        calls.inspected = calls.inspected + 1
        return {
            kind = expected.kind,
            path = expected.path,
            type_signature = expected.type_signature,
        }
    end

    function adapter.invoke()
        calls.invoked = calls.invoked + 1
        error("candidate invocation is forbidden")
    end

    return adapter, calls
end

describe("binding_manifest.parse", function()
    it("accepts a checksummed discovery manifest with empty symbols only", function()
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

    it("accepts a runtime manifest with every exact logical descriptor", function()
        local parsed = binding_manifest.parse(encode_with_checksum(runtime_manifest()))
        a.equal("runtime", parsed.kind)
        a.equal(123456, parsed.game_revision)
        for logical_name, kind in pairs(logical_kinds) do
            a.equal(kind, parsed.symbols[logical_name].kind)
        end
    end)

    it("requires every logical symbol and rejects unknown logical symbols", function()
        local missing = runtime_manifest()
        missing.symbols.fatal_safe_stop_function = nil
        expect_parse_error("CGCE-MAN-MISSING-SYMBOL", "symbols.fatal_safe_stop_function", missing)

        local unknown = runtime_manifest()
        unknown.symbols.fuzzy_candidate = descriptor("world_ready_function")
        expect_parse_error("CGCE-MAN-UNKNOWN-SYMBOL", "symbols.fuzzy_candidate", unknown)
    end)

    it("enforces strict descriptor keys, kinds, and non-empty type signatures", function()
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

    it("compares reflected type signatures without invoking any candidate", function()
        local manifest = binding_manifest.parse(encode_with_checksum(runtime_manifest()))
        local adapter, calls = matching_adapter()
        local original = adapter.inspect_descriptor
        function adapter.inspect_descriptor(logical_name, expected)
            local actual = original(logical_name, expected)
            if logical_name == "resize_function" then
                actual.type_signature = "function(wrong)"
            end
            return actual
        end

        local ok, errors = binding_manifest.verify_types(manifest, adapter)
        a.equal(false, ok)
        a.equal("CGCE-MAN-TYPE-MISMATCH", errors[1].code)
        a.equal("symbols.resize_function", errors[1].field)
        a.equal(16, calls.inspected)
        a.equal(0, calls.invoked)
    end)

    it("passes exact reflected descriptors and treats discovery as incapable", function()
        local runtime = binding_manifest.parse(encode_with_checksum(runtime_manifest()))
        local adapter, calls = matching_adapter()
        local runtime_ok, runtime_errors = binding_manifest.verify_types(runtime, adapter)
        a.equal(true, runtime_ok)
        a.deep_equal({}, runtime_errors)
        a.equal(16, calls.inspected)
        a.equal(0, calls.invoked)

        local discovery = binding_manifest.parse(encode_with_checksum(discovery_manifest()))
        local discovery_ok, discovery_errors = binding_manifest.verify_types(discovery, adapter)
        a.equal(true, discovery_ok)
        a.deep_equal({}, discovery_errors)
        a.equal(16, calls.inspected)
        a.equal(0, calls.invoked)
    end)
end)
