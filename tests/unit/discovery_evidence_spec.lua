local a = require("tests.support.assertions")
local binding_symbols = require("CrossplayGuildChestExpander.Scripts.binding_symbols")
local discovery_evidence = require("CrossplayGuildChestExpander.Scripts.discovery_evidence")
local discovery_probe = require("CrossplayGuildChestExpander.Scripts.discovery_probe")
local fingerprint = require("CrossplayGuildChestExpander.Scripts.fingerprint")
local json = require("CrossplayGuildChestExpander.Scripts.json")
local sha256 = require("CrossplayGuildChestExpander.Scripts.sha256")
local state_machine = require("CrossplayGuildChestExpander.Scripts.state_machine")

local catalog = binding_symbols.list()
local kinds = {}
for _, symbol in ipairs(catalog) do
    kinds[symbol.name] = symbol.kind
end

local function descriptor(logical_symbol, kind, candidate_index)
    local suffix = logical_symbol .. "/" .. candidate_index
    local value = {
        kind = kind,
        path = "/OwnerSupplied/" .. suffix,
        type_signature = "Exact<" .. logical_symbol .. "," .. candidate_index .. ">",
    }
    if kind == "property" then
        value.owner_path = "/OwnerSupplied/Owner_" .. suffix
        value.member_name = "Exact_" .. logical_symbol .. "_" .. candidate_index
        value.path = value.owner_path .. ":" .. value.member_name
    end
    return value
end

local function encode_with_checksum(value)
    value.checksum = nil
    value.checksum = sha256.hex(json.encode(value))
    return json.encode(value)
end

local function request(options)
    options = options or {}
    local candidates = {}
    for _, symbol in ipairs(catalog) do
        if symbol.name ~= options.omit_symbol then
            candidates[symbol.name] = {
                descriptor(symbol.name, symbol.kind, 1),
                descriptor(symbol.name, symbol.kind, 2),
            }
        end
    end
    local value = {
        probe_version = "1.0",
        kind = "discovery_probe_request",
        authoritative = false,
        mutation_capability = false,
        candidates = candidates,
    }
    local text = encode_with_checksum(value)
    return discovery_probe.parse(text), json.decode(text)
end

local function matched_record(logical_symbol, candidate_index)
    local candidate = descriptor(logical_symbol, kinds[logical_symbol], candidate_index)
    return {
        logical_symbol = logical_symbol,
        status = "MATCHED",
        kind = candidate.kind,
        candidate_index = candidate_index,
        exact_query = candidate.path,
        observed_full_name = candidate.path,
        canonical_signature = candidate.type_signature,
        signature_coverage = "FULL",
        provenance_api = candidate.kind == "property"
            and "resolve_property"
            or "static_find_object",
        invoked = false,
    }
end

local function mismatch_record(logical_symbol, candidate_index)
    local candidate = descriptor(logical_symbol, kinds[logical_symbol], candidate_index)
    return {
        logical_symbol = logical_symbol,
        status = "MISMATCH",
        kind = candidate.kind,
        candidate_index = candidate_index,
        exact_query = candidate.path,
        observed_full_name = "/ObservedMismatch/" .. logical_symbol .. "/" .. candidate_index,
        canonical_signature = "ObservedMismatch<" .. logical_symbol .. "," .. candidate_index .. ">",
        signature_coverage = "FULL",
        provenance_api = candidate.kind == "property"
            and "resolve_property"
            or "static_find_object",
        invoked = false,
    }
end

local function unavailable_record(logical_symbol, candidate_index, status)
    local candidate = descriptor(logical_symbol, kinds[logical_symbol], candidate_index)
    return {
        logical_symbol = logical_symbol,
        status = status,
        kind = candidate.kind,
        candidate_index = candidate_index,
        exact_query = candidate.path,
        observed_full_name = json.null,
        canonical_signature = json.null,
        signature_coverage = status == "PARTIAL" and "PARTIAL" or "NONE",
        provenance_api = candidate.kind == "property"
            and "resolve_property"
            or "static_find_object",
        invoked = false,
    }
end

local function representative_snapshot()
    local slots = json.array()
    slots[1] = {
        index = 1,
        empty = false,
        static_id = "Synthetic/Item",
        dynamic_guid = "synthetic-guid",
        quantity = 2,
        durability = "12.500000",
        instance_metadata_hash = string.rep("b", 64),
    }
    for index = 2, 54 do
        slots[index] = { index = index, empty = true }
    end
    local occupied = json.array({ slots[1] })
    return {
        version = "1.0",
        container_id = "private/container/evidence",
        owner_guild_id = "private/guild/evidence",
        slot_count = 54,
        occupied_slot_count = 1,
        total_item_quantity = 2,
        slots = slots,
        item_fingerprint = sha256.hex(json.encode({
            schema = "cgce.item-fingerprint.v1",
            items = occupied,
        })),
    }
end

local function observation(request_value, revision, options)
    options = options or {}
    local records = json.array()
    for _, symbol in ipairs(catalog) do
        if request_value.candidates[symbol.name] ~= nil then
            records[#records + 1] = matched_record(symbol.name, 1)
            records[#records + 1] = mismatch_record(symbol.name, 2)
        end
    end
    return {
        observation_version = "1.0",
        kind = "discovery_observation",
        authoritative = false,
        mutation_capability = false,
        game_revision = revision,
        probe_request_checksum = request_value.checksum,
        revision_evidence = {
            status = "MATCHED",
            observed_revision = revision,
            source_kind = "server_log",
            exact_source_identity = "/SyntheticEvidence/ServerLogRevision",
            source_signature = "CanonicalRevisionRecord<v1>",
            signature_coverage = "FULL",
            provenance_api = "read_revision_evidence",
            source_artifact_checksum = string.rep("1", 64),
            invoked = false,
            authority_verified = false,
        },
        symbols = records,
        before_snapshot_54 = {
            status = "MATCHED",
            provenance_api = "snapshot_capture",
            invoked = false,
            projection_contract_checksum = string.rep("2", 64),
            projector_implementation_checksum = string.rep("3", 64),
            capture_source_checksum = string.rep("4", 64),
            durability_codec_checksum = string.rep("5", 64),
            metadata_codec_checksum = string.rep("6", 64),
            metadata_ordered_input_contract_checksum = string.rep("7", 64),
            snapshot = representative_snapshot(),
            projection_verified = false,
        },
        fatal_safety = {
            matched_candidate_index = 1,
            mode = "SAFE_STOP",
            behavior_proof_artifact_checksum = string.rep("8", 64),
            harness_implementation_checksum = string.rep("9", 64),
            behavior_verified = false,
        },
    }
end

local function find_record(value, logical_symbol, candidate_index)
    for index, record in ipairs(value.symbols) do
        if record.logical_symbol == logical_symbol
            and record.candidate_index == candidate_index then
            return record, index
        end
    end
    error("record not found")
end

local function make_matched(record)
    local candidate = descriptor(record.logical_symbol, record.kind, record.candidate_index)
    record.status = "MATCHED"
    record.observed_full_name = candidate.path
    record.canonical_signature = candidate.type_signature
    record.signature_coverage = "FULL"
end

local function make_mismatch(record)
    local replacement = mismatch_record(record.logical_symbol, record.candidate_index)
    for key, item in pairs(replacement) do
        record[key] = item
    end
end

local function expect_error(code, field, text, request_handle, revision)
    local ok, err = pcall(discovery_evidence.parse, text, request_handle, revision)
    a.equal(false, ok)
    a.equal("table", type(err))
    a.equal(code, err.code)
    a.equal(field, err.field)
    a.equal("string", type(err.detail))
    a.equal(nil, err.detail:find("0x", 1, true))
    return err
end

describe("discovery_evidence manifest-authoring readiness", function()
    it("requires all 32 symbols and all candidate observations without granting authority", function()
        local request_handle, request_value = request()
        local handle = discovery_evidence.parse(
            encode_with_checksum(observation(request_value, 123456)),
            request_handle,
            123456
        )
        local detached = discovery_evidence.to_table(handle)

        a.equal(64, #detached.symbols)
        a.equal(false, detached.authoritative)
        a.equal(false, detached.mutation_capability)
        a.equal(false, detached.fatal_safety.behavior_verified)
        a.equal(false, detached.revision_evidence.authority_verified)
        a.equal(false, detached.before_snapshot_54.projection_verified)
        a.deep_equal({ ready = true, blockers = json.array() },
            discovery_evidence.manifest_readiness(handle))
        a.equal(false, discovery_evidence.authoritative(handle))
        a.equal(false, discovery_evidence.mutation_capability(handle))
        a.equal(detached.checksum, discovery_evidence.checksum(handle))
        a.equal(nil, discovery_evidence.eligibility)
        a.equal(nil, discovery_evidence.accept)
        a.equal(nil, discovery_evidence.gate_a_acceptance)

        local exports = {}
        for key in pairs(discovery_evidence) do
            exports[#exports + 1] = key
        end
        table.sort(exports)
        a.deep_equal({
            "authoritative",
            "checksum",
            "manifest_readiness",
            "mutation_capability",
            "parse",
            "to_table",
        }, exports)

        detached.symbols[1].status = "ERROR"
        local readiness = discovery_evidence.manifest_readiness(handle)
        readiness.ready = false
        a.equal("MATCHED", discovery_evidence.to_table(handle).symbols[1].status)
        a.equal(true, discovery_evidence.manifest_readiness(handle).ready)

        local machine = state_machine.new({ mutation_capability = false })
        local _, err = state_machine.transition(machine, "apply")
        a.equal("CGCE-STATE-MUTATION-BUILD-UNAVAILABLE", err.code)
    end)

    it("reports missing pairs, zero/two matches, and unavailable candidates deterministically", function()
        local request_handle, request_value = request()
        local value = observation(request_value, 123456)

        local _, missing_index = find_record(value, "world_ready_function", 2)
        table.remove(value.symbols, missing_index)

        make_mismatch(find_record(value, "selected_world_class", 1))
        make_matched(find_record(value, "guild_manager_class", 2))

        local unavailable, unavailable_index = find_record(value, "guild_class", 2)
        value.symbols[unavailable_index] = unavailable_record(
            unavailable.logical_symbol,
            unavailable.candidate_index,
            "NOT_LOADED"
        )

        local handle = discovery_evidence.parse(
            encode_with_checksum(value),
            request_handle,
            123456
        )
        a.deep_equal({
            ready = false,
            blockers = {
                {
                    code = "CGCE-DISC-MISSING-OBSERVATION",
                    field = "symbols.world_ready_function[2]",
                    detail = "probe candidate observation is missing",
                },
                {
                    code = "CGCE-DISC-MATCH-COUNT",
                    field = "symbols.selected_world_class",
                    detail = "logical symbol has 0 MATCHED candidates; exactly one is required",
                },
                {
                    code = "CGCE-DISC-MATCH-COUNT",
                    field = "symbols.guild_manager_class",
                    detail = "logical symbol has 2 MATCHED candidates; exactly one is required",
                },
                {
                    code = "CGCE-DISC-OBSERVATION-STATUS",
                    field = "symbols.guild_class[2].status",
                    detail = "probe candidate status is NOT_LOADED",
                },
            },
        }, discovery_evidence.manifest_readiness(handle))
    end)

    it("blocks PARTIAL and ERROR candidate observations deterministically", function()
        local request_handle, request_value = request()
        local value = observation(request_value, 123456)
        local partial, partial_index = find_record(value, "item_static_id_property", 2)
        local failed, failed_index = find_record(value, "item_dynamic_guid_property", 2)
        value.symbols[partial_index] = unavailable_record(
            partial.logical_symbol,
            partial.candidate_index,
            "PARTIAL"
        )
        value.symbols[failed_index] = unavailable_record(
            failed.logical_symbol,
            failed.candidate_index,
            "ERROR"
        )

        local handle = discovery_evidence.parse(
            encode_with_checksum(value),
            request_handle,
            123456
        )
        a.deep_equal({
            ready = false,
            blockers = {
                {
                    code = "CGCE-DISC-OBSERVATION-STATUS",
                    field = "symbols.item_static_id_property[2].status",
                    detail = "probe candidate status is PARTIAL",
                },
                {
                    code = "CGCE-DISC-OBSERVATION-STATUS",
                    field = "symbols.item_dynamic_guid_property[2].status",
                    detail = "probe candidate status is ERROR",
                },
            },
        }, discovery_evidence.manifest_readiness(handle))
    end)

    it("blocks manifest authoring when any shared-catalog symbol lacks candidates", function()
        local request_handle, request_value = request({ omit_symbol = "item_quantity_property" })
        local handle = discovery_evidence.parse(
            encode_with_checksum(observation(request_value, 123456)),
            request_handle,
            123456
        )
        a.deep_equal({
            ready = false,
            blockers = {
                {
                    code = "CGCE-DISC-MISSING-CANDIDATE",
                    field = "symbols.item_quantity_property",
                    detail = "required logical symbol has no probe candidates",
                },
            },
        }, discovery_evidence.manifest_readiness(handle))
    end)

    it("rejects duplicate or unbound candidate pairs", function()
        local request_handle, request_value = request()
        local duplicate = observation(request_value, 123456)
        duplicate.symbols[#duplicate.symbols + 1] = matched_record("guild_class", 1)
        expect_error(
            "CGCE-DISC-DUPLICATE",
            "symbols[65].candidate_index",
            encode_with_checksum(duplicate),
            request_handle,
            123456
        )

        local unbound = observation(request_value, 123456)
        local record = find_record(unbound, "guild_class", 2)
        record.candidate_index = 3
        record.exact_query = "/OwnerSupplied/guild_class/3"
        expect_error(
            "CGCE-DISC-CANDIDATE",
            "symbols[16].candidate_index",
            encode_with_checksum(unbound),
            request_handle,
            123456
        )
    end)

    it("binds exact non-invoked revision evidence without claiming runtime authority", function()
        local request_handle, request_value = request()

        local mismatch = observation(request_value, 123456)
        mismatch.revision_evidence.observed_revision = 123457
        expect_error(
            "CGCE-DISC-REVISION-EVIDENCE",
            "revision_evidence.observed_revision",
            encode_with_checksum(mismatch),
            request_handle,
            123456
        )

        local invoked = observation(request_value, 123456)
        invoked.revision_evidence.invoked = true
        expect_error(
            "CGCE-DISC-INVOKED",
            "revision_evidence.invoked",
            encode_with_checksum(invoked),
            request_handle,
            123456
        )

        local claimed = observation(request_value, 123456)
        claimed.revision_evidence.authority_verified = true
        expect_error(
            "CGCE-DISC-REVISION-EVIDENCE",
            "revision_evidence.authority_verified",
            encode_with_checksum(claimed),
            request_handle,
            123456
        )

        local fuzzy = observation(request_value, 123456)
        fuzzy.revision_evidence.exact_source_identity = "/SyntheticEvidence/*"
        expect_error(
            "CGCE-DISC-REVISION-EVIDENCE",
            "revision_evidence.exact_source_identity",
            encode_with_checksum(fuzzy),
            request_handle,
            123456
        )

        local unavailable = observation(request_value, 123456)
        unavailable.revision_evidence.status = "NOT_LOADED"
        unavailable.revision_evidence.observed_revision = json.null
        unavailable.revision_evidence.signature_coverage = "NONE"
        local handle = discovery_evidence.parse(
            encode_with_checksum(unavailable),
            request_handle,
            123456
        )
        a.deep_equal({
            ready = false,
            blockers = {
                {
                    code = "CGCE-DISC-REVISION-STATUS",
                    field = "revision_evidence.status",
                    detail = "revision evidence status is NOT_LOADED",
                },
            },
        }, discovery_evidence.manifest_readiness(handle))
    end)

    it("requires strict snapshot artifact links and representative occupied/empty slots", function()
        local request_handle, request_value = request()

        local missing = observation(request_value, 123456)
        missing.before_snapshot_54.durability_codec_checksum = nil
        expect_error(
            "CGCE-DISC-SNAPSHOT",
            "before_snapshot_54.durability_codec_checksum",
            encode_with_checksum(missing),
            request_handle,
            123456
        )

        local bad_link = observation(request_value, 123456)
        bad_link.before_snapshot_54.projector_implementation_checksum = string.rep("A", 64)
        expect_error(
            "CGCE-DISC-SNAPSHOT",
            "before_snapshot_54.projector_implementation_checksum",
            encode_with_checksum(bad_link),
            request_handle,
            123456
        )

        local no_occupied = observation(request_value, 123456)
        no_occupied.before_snapshot_54.snapshot.slots[1] = { index = 1, empty = true }
        no_occupied.before_snapshot_54.snapshot.occupied_slot_count = 0
        no_occupied.before_snapshot_54.snapshot.total_item_quantity = 0
        no_occupied.before_snapshot_54.snapshot.item_fingerprint = sha256.hex(json.encode({
            schema = "cgce.item-fingerprint.v1",
            items = json.array(),
        }))
        expect_error(
            "CGCE-DISC-SNAPSHOT",
            "before_snapshot_54.snapshot.slots",
            encode_with_checksum(no_occupied),
            request_handle,
            123456
        )

        local claimed = observation(request_value, 123456)
        claimed.before_snapshot_54.projection_verified = true
        expect_error(
            "CGCE-DISC-SNAPSHOT",
            "before_snapshot_54.projection_verified",
            encode_with_checksum(claimed),
            request_handle,
            123456
        )

        local blocked = observation(request_value, 123456)
        blocked.before_snapshot_54.status = "NOT_LOADED"
        blocked.before_snapshot_54.snapshot = json.null
        blocked.before_snapshot_54.projection_contract_checksum = json.null
        blocked.before_snapshot_54.projector_implementation_checksum = json.null
        blocked.before_snapshot_54.capture_source_checksum = json.null
        blocked.before_snapshot_54.durability_codec_checksum = json.null
        blocked.before_snapshot_54.metadata_codec_checksum = json.null
        blocked.before_snapshot_54.metadata_ordered_input_contract_checksum = json.null
        local blocked_handle = discovery_evidence.parse(
            encode_with_checksum(blocked),
            request_handle,
            123456
        )
        a.deep_equal({
            ready = false,
            blockers = {
                {
                    code = "CGCE-DISC-SNAPSHOT-STATUS",
                    field = "before_snapshot_54.status",
                    detail = "canonical 54-slot before snapshot status is NOT_LOADED",
                },
            },
        }, discovery_evidence.manifest_readiness(blocked_handle))
    end)

    it("accepts snapshot.capture-compatible JSON-safe opaque strings", function()
        local request_handle, request_value = request()
        local value = observation(request_value, 123456)
        local snapshot = value.before_snapshot_54.snapshot
        snapshot.container_id = "private\ncontainer"
        snapshot.owner_guild_id = "private\tguild"
        snapshot.slots[1].static_id = "Synthetic\nItem"
        snapshot.slots[1].dynamic_guid = "synthetic\tguid"
        snapshot.slots[1].durability = "12.5\ncanonical"
        snapshot.item_fingerprint = fingerprint.compute({ snapshot.slots[1] })

        local handle = discovery_evidence.parse(
            encode_with_checksum(value),
            request_handle,
            123456
        )
        a.equal(true, discovery_evidence.manifest_readiness(handle).ready)
        a.equal("private\ncontainer",
            discovery_evidence.to_table(handle).before_snapshot_54.snapshot.container_id)
    end)

    it("binds fatal metadata to the selected fatal candidate without claiming proof", function()
        local request_handle, request_value = request()

        local wrong_index = observation(request_value, 123456)
        wrong_index.fatal_safety.matched_candidate_index = 2
        local handle = discovery_evidence.parse(
            encode_with_checksum(wrong_index),
            request_handle,
            123456
        )
        a.deep_equal({
            ready = false,
            blockers = {
                {
                    code = "CGCE-DISC-FATAL-CANDIDATE",
                    field = "fatal_safety.matched_candidate_index",
                    detail = "fatal metadata does not reference the unique MATCHED candidate",
                },
            },
        }, discovery_evidence.manifest_readiness(handle))

        local claimed = observation(request_value, 123456)
        claimed.fatal_safety.behavior_verified = true
        expect_error(
            "CGCE-DISC-FATAL",
            "fatal_safety.behavior_verified",
            encode_with_checksum(claimed),
            request_handle,
            123456
        )

        local bad_checksum = observation(request_value, 123456)
        bad_checksum.fatal_safety.behavior_proof_artifact_checksum = "not-a-checksum"
        expect_error(
            "CGCE-DISC-FATAL",
            "fatal_safety.behavior_proof_artifact_checksum",
            encode_with_checksum(bad_checksum),
            request_handle,
            123456
        )

        local absent = observation(request_value, 123456)
        absent.fatal_safety.matched_candidate_index = json.null
        absent.fatal_safety.mode = json.null
        absent.fatal_safety.behavior_proof_artifact_checksum = json.null
        absent.fatal_safety.harness_implementation_checksum = json.null
        local absent_handle = discovery_evidence.parse(
            encode_with_checksum(absent),
            request_handle,
            123456
        )
        a.deep_equal({
            ready = false,
            blockers = {
                {
                    code = "CGCE-DISC-FATAL-CANDIDATE",
                    field = "fatal_safety.matched_candidate_index",
                    detail = "fatal metadata does not reference the unique MATCHED candidate",
                },
                {
                    code = "CGCE-DISC-FATAL-METADATA",
                    field = "fatal_safety.mode",
                    detail = "fatal safety mode link is missing",
                },
                {
                    code = "CGCE-DISC-FATAL-METADATA",
                    field = "fatal_safety.behavior_proof_artifact_checksum",
                    detail = "fatal behavior-proof artifact link is missing",
                },
                {
                    code = "CGCE-DISC-FATAL-METADATA",
                    field = "fatal_safety.harness_implementation_checksum",
                    detail = "fatal harness implementation link is missing",
                },
            },
        }, discovery_evidence.manifest_readiness(absent_handle))

        local unavailable = observation(request_value, 123456)
        make_mismatch(find_record(unavailable, "fatal_safe_stop_function", 1))
        unavailable.fatal_safety.matched_candidate_index = json.null
        unavailable.fatal_safety.mode = json.null
        unavailable.fatal_safety.behavior_proof_artifact_checksum = json.null
        unavailable.fatal_safety.harness_implementation_checksum = json.null
        local unavailable_handle = discovery_evidence.parse(
            encode_with_checksum(unavailable),
            request_handle,
            123456
        )
        local readiness = discovery_evidence.manifest_readiness(unavailable_handle)
        a.equal(false, readiness.ready)
        a.deep_equal({
            code = "CGCE-DISC-MATCH-COUNT",
            field = "symbols.fatal_safe_stop_function",
            detail = "logical symbol has 0 MATCHED candidates; exactly one is required",
        }, readiness.blockers[#readiness.blockers])
    end)

    it("rejects malformed roots and nested keys with sanitized deterministic errors", function()
        local request_handle, request_value = request()
        local valid_text = encode_with_checksum(observation(request_value, 123456))
        expect_error(
            "CGCE-DISC-REQUEST",
            "request_handle",
            valid_text,
            function() end,
            123456
        )
        for _, text in ipairs({ "null", "[]", "1", '"scalar"' }) do
            expect_error("CGCE-DISC-TYPE", nil, text, request_handle, 123456)
        end

        local invalid = expect_error(
            "CGCE-DISC-JSON",
            nil,
            '{"secret-marker":',
            request_handle,
            123456
        )
        a.equal(nil, invalid.detail:find("secret-marker", 1, true))

        local top_unknown = observation(request_value, 123456)
        top_unknown.secret_marker = "must-not-leak"
        expect_error(
            "CGCE-DISC-UNKNOWN-KEY",
            "secret_marker",
            encode_with_checksum(top_unknown),
            request_handle,
            123456
        )

        local top_missing = observation(request_value, 123456)
        top_missing.authoritative = nil
        expect_error(
            "CGCE-DISC-MISSING-KEY",
            "authoritative",
            encode_with_checksum(top_missing),
            request_handle,
            123456
        )

        local nested = observation(request_value, 123456)
        nested.revision_evidence.authoritative = true
        expect_error(
            "CGCE-DISC-REVISION-EVIDENCE",
            "revision_evidence.authoritative",
            encode_with_checksum(nested),
            request_handle,
            123456
        )

        local record_extra = observation(request_value, 123456)
        record_extra.symbols[1].raw_handle = "secret"
        expect_error(
            "CGCE-DISC-RECORD",
            "symbols[1].raw_handle",
            encode_with_checksum(record_extra),
            request_handle,
            123456
        )

        for _, accessor in ipairs({
            discovery_evidence.to_table,
            discovery_evidence.manifest_readiness,
            discovery_evidence.checksum,
            discovery_evidence.authoritative,
            discovery_evidence.mutation_capability,
        }) do
            local ok, err = pcall(accessor, function() end)
            a.equal(false, ok)
            a.equal("CGCE-DISC-HANDLE", err.code)
            a.equal("handle", err.field)
            a.equal(nil, err.detail:find("0x", 1, true))
        end
    end)

    it("captures catalog, probe, JSON, checksum, and accessor dependencies privately", function()
        local request_handle, request_value = request()
        local text = encode_with_checksum(observation(request_value, 123456))
        local blocked = observation(request_value, 123456)
        blocked.before_snapshot_54.status = "NOT_LOADED"
        blocked.before_snapshot_54.snapshot = json.null
        for _, field in ipairs({
            "projection_contract_checksum",
            "projector_implementation_checksum",
            "capture_source_checksum",
            "durability_codec_checksum",
            "metadata_codec_checksum",
            "metadata_ordered_input_contract_checksum",
        }) do
            blocked.before_snapshot_54[field] = json.null
        end
        local blocked_text = encode_with_checksum(blocked)
        local originals = {
            parse = discovery_evidence.parse,
            to_table = discovery_evidence.to_table,
            readiness = discovery_evidence.manifest_readiness,
            checksum = discovery_evidence.checksum,
            authoritative = discovery_evidence.authoritative,
            mutation = discovery_evidence.mutation_capability,
            symbols_list = binding_symbols.list,
            probe_to_table = discovery_probe.to_table,
            probe_checksum = discovery_probe.checksum,
            encode = json.encode,
            decode = json.decode,
            array = json.array,
            sha = sha256.hex,
            fingerprint = fingerprint.compute,
        }

        binding_symbols.list = function() return {} end
        discovery_probe.to_table = function() return {} end
        discovery_probe.checksum = function() return string.rep("f", 64) end
        fingerprint.compute = function() return string.rep("f", 64) end
        discovery_evidence.parse = function() return function() end end
        discovery_evidence.to_table = function() return { authoritative = true } end
        discovery_evidence.manifest_readiness = function() return { ready = false } end
        discovery_evidence.checksum = function() return string.rep("f", 64) end
        discovery_evidence.authoritative = function() return true end
        discovery_evidence.mutation_capability = function() return true end

        local test_ok, test_error = xpcall(function()
            local handle = originals.parse(text, request_handle, 123456)
            a.equal(false, originals.to_table(handle).authoritative)
            a.equal(true, originals.readiness(handle).ready)
            a.equal(64, #originals.to_table(handle).symbols)
            a.equal(64, #originals.checksum(handle))
            a.equal(false, originals.authoritative(handle))
            a.equal(false, originals.mutation(handle))

            fingerprint.compute = originals.fingerprint
            json.encode = function() return "{}" end
            json.decode = function() return {} end
            json.array = function() return {} end
            sha256.hex = function() return string.rep("f", 64) end

            local blocked_handle = originals.parse(blocked_text, request_handle, 123456)
            a.equal(false, originals.readiness(blocked_handle).ready)
            a.equal(64, #originals.to_table(blocked_handle).symbols)
            a.equal(64, #originals.checksum(blocked_handle))
        end, function(err)
            if type(err) == "table" then
                return table.concat({ err.code or "", err.field or "", err.detail or "" }, " | ")
            end
            return debug.traceback(err)
        end)

        binding_symbols.list = originals.symbols_list
        discovery_probe.to_table = originals.probe_to_table
        discovery_probe.checksum = originals.probe_checksum
        json.encode = originals.encode
        json.decode = originals.decode
        json.array = originals.array
        sha256.hex = originals.sha
        fingerprint.compute = originals.fingerprint
        discovery_evidence.parse = originals.parse
        discovery_evidence.to_table = originals.to_table
        discovery_evidence.manifest_readiness = originals.readiness
        discovery_evidence.checksum = originals.checksum
        discovery_evidence.authoritative = originals.authoritative
        discovery_evidence.mutation_capability = originals.mutation
        if not test_ok then
            error(test_error)
        end
    end)
end)
