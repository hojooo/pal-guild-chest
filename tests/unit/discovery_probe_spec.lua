local a = require("tests.support.assertions")
local binding_manifest = require("CrossplayGuildChestExpander.Scripts.binding_manifest")
local certification = require("CrossplayGuildChestExpander.Scripts.certification")
local discovery_probe = require("CrossplayGuildChestExpander.Scripts.discovery_probe")
local json = require("CrossplayGuildChestExpander.Scripts.json")
local sha256 = require("CrossplayGuildChestExpander.Scripts.sha256")
local state_machine = require("CrossplayGuildChestExpander.Scripts.state_machine")

local function class_candidate(path)
    return {
        kind = "class",
        path = path or "/OwnerSupplied/ExactClass",
        type_signature = "Class<OwnerSuppliedExactClass>",
    }
end

local function property_candidate()
    return {
        kind = "property",
        owner_path = "/OwnerSupplied/ExactOwner",
        member_name = "ExactMember",
        path = "/OwnerSupplied/ExactOwner:ExactMember",
        type_signature = "Property<OpaqueWorldId>",
    }
end

local function request()
    return {
        probe_version = "1.0",
        kind = "discovery_probe_request",
        authoritative = false,
        mutation_capability = false,
        candidates = {
            guild_manager_class = { class_candidate() },
            world_id_property = { property_candidate() },
        },
    }
end

local function encode_with_checksum(value)
    value.checksum = nil
    value.checksum = sha256.hex(json.encode(value))
    return json.encode(value)
end

local function expect_probe_error(code, field, value)
    local ok, err = pcall(discovery_probe.parse, encode_with_checksum(value))
    a.equal(false, ok)
    a.equal("table", type(err))
    a.equal(code, err.code)
    a.equal(field, err.field)
    a.equal("string", type(err.detail))
end

describe("discovery_probe.parse", function()
    it("accepts partial owner-supplied exact candidates as an opaque non-authoritative request", function()
        local handle = discovery_probe.parse(encode_with_checksum(request()))
        local detached = discovery_probe.to_table(handle)

        a.equal("function", type(handle))
        a.equal("discovery_probe_request", detached.kind)
        a.equal(false, detached.authoritative)
        a.equal(false, detached.mutation_capability)
        a.equal(false, discovery_probe.authoritative(handle))
        a.equal(false, discovery_probe.mutation_capability(handle))
        a.equal(detached.checksum, discovery_probe.checksum(handle))
        a.equal(nil, detached.candidates.guild_name_property)

        detached.candidates.world_id_property[1].path = "/Forged/AfterParse"
        a.equal(
            "/OwnerSupplied/ExactOwner:ExactMember",
            discovery_probe.to_table(handle).candidates.world_id_property[1].path
        )

        local rawset_ok = pcall(function()
            rawset(handle, "authoritative", true)
        end)
        a.equal(false, rawset_ok)
    end)

    it("rejects unknown keys, unknown symbols, and mismatched descriptor kinds deterministically", function()
        local unknown_top = request()
        unknown_top.MinRevision = 1
        expect_probe_error("CGCE-PROBE-UNKNOWN-KEY", "MinRevision", unknown_top)

        local unknown_symbols = request()
        unknown_symbols.candidates.z_guess = { class_candidate() }
        unknown_symbols.candidates.a_guess = { class_candidate() }
        expect_probe_error("CGCE-PROBE-UNKNOWN-SYMBOL", "candidates.a_guess", unknown_symbols)

        local wrong_kind = request()
        wrong_kind.candidates.world_id_property[1].kind = "function"
        expect_probe_error(
            "CGCE-PROBE-DESCRIPTOR-KIND",
            "candidates.world_id_property[1].kind",
            wrong_kind
        )
    end)

    it("rejects wildcard, fuzzy, relative, control-bearing, and malformed candidate values", function()
        local scenarios = {
            { field = "path", value = "/OwnerSupplied/*" },
            { field = "path", value = "/OwnerSupplied/Fuzzy...Class" },
            { field = "path", value = "Relative/Class" },
            { field = "path", value = "/OwnerSupplied/Injected\nClass" },
            { field = "type_signature", value = "Class<?>" },
            { field = "type_signature", value = "Class<*>" },
            { field = "type_signature", value = "Class<[A-Z]>" },
        }
        for _, scenario in ipairs(scenarios) do
            local value = request()
            value.candidates.guild_manager_class[1][scenario.field] = scenario.value
            expect_probe_error(
                "CGCE-PROBE-DESCRIPTOR-TYPE",
                "candidates.guild_manager_class[1]." .. scenario.field,
                value
            )
        end

        local member = request()
        member.candidates.world_id_property[1].member_name = "Owner.Member"
        expect_probe_error(
            "CGCE-PROBE-DESCRIPTOR-TYPE",
            "candidates.world_id_property[1].member_name",
            member
        )
    end)

    it("treats a typed pointer marker as exact signature syntax rather than a wildcard", function()
        local value = request()
        value.candidates.guild_manager_class[1].type_signature = "Class<UObject*>"
        local handle = discovery_probe.parse(encode_with_checksum(value))
        a.equal(
            "Class<UObject*>",
            discovery_probe.to_table(handle).candidates.guild_manager_class[1].type_signature
        )
    end)

    it("requires dense candidate arrays, exact descriptor keys, and unique candidates", function()
        local non_array = request()
        non_array.candidates.guild_manager_class = { candidate = class_candidate() }
        expect_probe_error("CGCE-PROBE-CANDIDATES", "candidates.guild_manager_class", non_array)

        local extra = request()
        extra.candidates.world_id_property[1].inferred = true
        expect_probe_error(
            "CGCE-PROBE-DESCRIPTOR-KEY",
            "candidates.world_id_property[1].inferred",
            extra
        )

        local duplicate = request()
        duplicate.candidates.guild_manager_class[2] = class_candidate()
        expect_probe_error(
            "CGCE-PROBE-DUPLICATE",
            "candidates.guild_manager_class[2]",
            duplicate
        )
    end)

    it("requires the explicit non-authority flags and canonical self-checksum", function()
        local authoritative = request()
        authoritative.authoritative = true
        expect_probe_error("CGCE-PROBE-AUTHORITY", "authoritative", authoritative)

        local mutating = request()
        mutating.mutation_capability = true
        expect_probe_error("CGCE-PROBE-AUTHORITY", "mutation_capability", mutating)

        local text = encode_with_checksum(request())
        local tampered = json.decode(text)
        tampered.candidates.guild_manager_class[1].path = "/OwnerSupplied/OtherExactClass"
        local ok, err = pcall(discovery_probe.parse, json.encode(tampered))
        a.equal(false, ok)
        a.equal("CGCE-PROBE-CHECKSUM", err.code)
        a.equal("checksum", err.field)
    end)

    it("captures JSON, checksum, and accessor dispatch dependencies privately", function()
        local original_parse = discovery_probe.parse
        local original_to_table = discovery_probe.to_table
        local original_checksum = discovery_probe.checksum
        local original_authoritative = discovery_probe.authoritative
        local original_mutation_capability = discovery_probe.mutation_capability
        local original_encode = json.encode
        local original_decode = json.decode
        local original_sha256 = sha256.hex
        local first = original_parse(encode_with_checksum(request()))
        local second_text = encode_with_checksum(request())

        json.encode = function() return "{}" end
        json.decode = function()
            return { authoritative = true, mutation_capability = true }
        end
        sha256.hex = function() return string.rep("f", 64) end
        discovery_probe.parse = function() return function() end end
        discovery_probe.to_table = function()
            return { authoritative = true, mutation_capability = true }
        end
        discovery_probe.checksum = function() return string.rep("f", 64) end
        discovery_probe.authoritative = function() return true end
        discovery_probe.mutation_capability = function() return true end

        local test_ok, test_error = xpcall(function()
            local second = original_parse(second_text)
            local first_value = original_to_table(first)
            local second_value = original_to_table(second)
            a.equal(false, first_value.authoritative)
            a.equal(false, first_value.mutation_capability)
            a.equal(false, second_value.authoritative)
            a.equal(false, second_value.mutation_capability)
            a.equal(first_value.checksum, original_checksum(first))
            a.equal(second_value.checksum, original_checksum(second))
            a.equal(false, original_authoritative(first))
            a.equal(false, original_mutation_capability(first))
        end, debug.traceback)

        discovery_probe.parse = original_parse
        discovery_probe.to_table = original_to_table
        discovery_probe.checksum = original_checksum
        discovery_probe.authoritative = original_authoritative
        discovery_probe.mutation_capability = original_mutation_capability
        json.encode = original_encode
        json.decode = original_decode
        sha256.hex = original_sha256
        if not test_ok then
            error(test_error)
        end
    end)

    it("cannot be promoted into binding, certification, or mutation authority", function()
        local handle = discovery_probe.parse(encode_with_checksum(request()))
        local calls = { read = 0, inspect = 0, invoke = 0 }
        local ok, errors = binding_manifest.verify_types(discovery_probe.to_table(handle), {
            read_revision = function()
                calls.read = calls.read + 1
                return 123456
            end,
            inspect_descriptor = function()
                calls.inspect = calls.inspect + 1
            end,
            invoke = function()
                calls.invoke = calls.invoke + 1
            end,
        })
        a.equal(false, ok)
        a.equal("CGCE-MAN-AUTHORITY", errors[1].code)
        a.deep_equal({ read = 0, inspect = 0, invoke = 0 }, calls)

        local cert_ok, cert_err = pcall(
            certification.verify,
            handle,
            discovery_probe.checksum(handle),
            123456,
            "windows-dedicated-ps5-macos-required"
        )
        a.equal(false, cert_ok)
        a.equal("CGCE-CERT-TYPE", cert_err.code)

        local detached_cert_ok = pcall(
            certification.verify,
            discovery_probe.to_table(handle),
            discovery_probe.checksum(handle),
            123456,
            "windows-dedicated-ps5-macos-required"
        )
        a.equal(false, detached_cert_ok)

        local machine = state_machine.new({
            mutation_capability = discovery_probe.mutation_capability(handle),
        })
        local _, mutation_error = state_machine.transition(machine, "apply")
        a.equal("CGCE-STATE-MUTATION-BUILD-UNAVAILABLE", mutation_error.code)
    end)
end)
