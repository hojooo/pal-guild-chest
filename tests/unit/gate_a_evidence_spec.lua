local a = require("tests.support.assertions")
local audit = require("CrossplayGuildChestExpander.Scripts.audit")
local binding_symbols = require("CrossplayGuildChestExpander.Scripts.binding_symbols")
local fake_adapter = require("tests.support.fake_adapter")
local fake_filesystem = require("tests.support.fake_filesystem")
local gate_a_evidence = require("CrossplayGuildChestExpander.Scripts.gate_a_evidence")
local json = require("CrossplayGuildChestExpander.Scripts.json")
local report = require("CrossplayGuildChestExpander.Scripts.report")
local sha256 = require("CrossplayGuildChestExpander.Scripts.sha256")
local snapshot = require("CrossplayGuildChestExpander.Scripts.snapshot")

local REVISION = 123456
local WORLD_ID = "private/world/gate-a"
local PROFILE = "windows-dedicated-ps5-macos-required"
local UE4SS_VERSION = "3.0.1"
local REVIEWER = "Independent Reviewer"
local REVIEWED_AT = "2026-07-22T12:34:56Z"
local PRIVATE_ROOT = "private-artifacts/discovery/123456/"
local REPOSITORY_ROOT = "C:\\CGCE-GateA"
local REVIEW_AUTHORIZATION_CHECKSUM = string.rep("e", 64)

local catalog = binding_symbols.list()
local kinds = {}
for _, symbol in ipairs(catalog) do
    kinds[symbol.name] = symbol.kind
end

local function encode_with_checksum(value)
    value.checksum = nil
    value.checksum = sha256.hex(json.encode(value))
    return json.encode(value)
end

local function deep_copy(value)
    return json.decode(json.encode(value))
end

local function read(path)
    local file = assert(io.open(path, "rb"))
    local bytes = file:read("*a")
    file:close()
    return bytes
end

local function descriptor(logical_symbol, candidate_index)
    local kind = assert(kinds[logical_symbol])
    local suffix = logical_symbol .. "/" .. candidate_index
    if kind == "property" then
        local owner_path = "/GateA/Owner/" .. suffix
        local member_name = "Member_" .. logical_symbol .. "_" .. candidate_index
        return {
            kind = kind,
            owner_path = owner_path,
            member_name = member_name,
            path = owner_path .. ":" .. member_name,
            type_signature = "Property<" .. logical_symbol .. "," .. candidate_index .. ">",
        }
    end
    return {
        kind = kind,
        path = "/GateA/" .. suffix,
        type_signature = "Exact<" .. logical_symbol .. "," .. candidate_index .. ">",
    }
end

local function matched_record(logical_symbol, candidate_index)
    local candidate = descriptor(logical_symbol, candidate_index)
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
    local candidate = descriptor(logical_symbol, candidate_index)
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

local function captured_audit()
    local slots = {}
    slots[1] = fake_adapter.slot(fake_adapter.item({
        static_id = "Synthetic/GateAItem",
        dynamic_guid = "private-guid-gate-a",
        quantity = 2,
        durability = "12.500000",
        instance_metadata_hash = string.rep("a", 64),
    }))
    for index = 2, 54 do
        slots[index] = fake_adapter.slot(nil)
    end
    local container = fake_adapter.container({
        container_id = "private/container/gate-a",
        owner_guild_id = "private/guild/gate-a",
        slots = slots,
    })
    return audit.capture({
        world_id = WORLD_ID,
        game_revision = REVISION,
        deployment_profile = PROFILE,
        target_slots = 54,
        include_guild_ids = {},
        exclude_guild_ids = {},
        list_guilds = function()
            return { {
                guild_id = "private/guild/gate-a",
                guild_name = "Gate A",
                chest_container_id = "private/container/gate-a",
            } }
        end,
        resolve_guild_chest = function()
            return {
                container_id = container.container_id,
                owner_guild_id = container.owner_guild_id,
                is_guild_chest = true,
                container = container,
            }
        end,
        snapshot_container = function(value)
            return snapshot.capture(fake_adapter.new(), value)
        end,
    })
end

local function platform_projection()
    return {
        preflight_ok = true,
        state = "CONNECTIVITY_PREFLIGHT_OK",
        certification = "UNPROVEN",
        diagnostic_only = true,
        evidence = {
            public_lobby = true,
            game_port = 8211,
            public_port = 8211,
            ini_public_port = 8211,
            required_platforms = { Steam = true, PS5 = true, Mac = true },
            xbox = false,
            client_mod_allowed = false,
            log_format = "Json",
        },
    }
end

local function artifact(relative_path, bytes)
    return {
        relative_path = relative_path,
        checksum = sha256.hex(bytes),
    }
end

local function read_only_filesystem(files, reparse_relative_path)
    local entries = { [REPOSITORY_ROOT] = "directory" }
    for relative_path, bytes in pairs(files) do
        local components = {}
        for component in relative_path:gmatch("[^/]+") do
            components[#components + 1] = component
        end
        local current = REPOSITORY_ROOT
        for index, component in ipairs(components) do
            current = current .. "\\" .. component
            if index == #components then
                entries[current] = {
                    kind = "file",
                    content = bytes,
                    reparse_point = relative_path == reparse_relative_path,
                }
            else
                entries[current] = "directory"
            end
        end
    end
    local fs = fake_filesystem.new({ entries = entries })
    return {
        capabilities = fs.capabilities,
        canonicalize = fs.canonicalize,
        inspect_no_follow = fs.inspect_no_follow,
        propose_temp_sibling = fs.propose_temp_sibling,
        read_all_no_follow = fs.read_all_no_follow,
    }
end

local function build_fixture(options)
    options = options or {}
    local audit_handle = captured_audit()
    local audit_table = audit.to_table(audit_handle)
    local before_snapshot = deep_copy(audit_table.guilds[1].snapshot)

    local linked = {
        projection_contract_bytes = read(
            "CrossplayGuildChestExpander/Scripts/discovery_evidence.lua"
        ),
        projector_implementation_bytes = read(
            "CrossplayGuildChestExpander/Scripts/snapshot.lua"
        ),
        capture_source_bytes = read("CrossplayGuildChestExpander/Scripts/audit.lua"),
        durability_codec_bytes = read("CrossplayGuildChestExpander/Scripts/fingerprint.lua"),
        metadata_codec_bytes = read("CrossplayGuildChestExpander/Scripts/json.lua"),
        metadata_ordered_input_contract_bytes = read(
            "CrossplayGuildChestExpander/Scripts/sha256.lua"
        ),
        fatal_harness_bytes = "isolated fatal harness v1\n",
    }

    local runtime_identity = {
        evidence_version = "1.0",
        kind = "runtime_identity_evidence",
        world_id = WORLD_ID,
        game_revision = REVISION,
        ue4ss_version = UE4SS_VERSION,
        source_kind = "server_log",
        exact_source_identity = "PalServer/Saved/Logs/PalServer.log",
        source_signature = "CanonicalRevisionRecord<v1>",
    }
    if options.mutate_runtime_identity then
        options.mutate_runtime_identity(runtime_identity)
    end
    linked.revision_source_bytes = encode_with_checksum(runtime_identity)

    local candidates = {}
    for _, symbol in ipairs(catalog) do
        candidates[symbol.name] = {
            descriptor(symbol.name, 1),
            descriptor(symbol.name, 2),
        }
    end
    local probe = {
        probe_version = "1.0",
        kind = "discovery_probe_request",
        authoritative = false,
        mutation_capability = false,
        candidates = candidates,
    }
    if options.mutate_probe then options.mutate_probe(probe) end
    local probe_text = encode_with_checksum(probe)

    local fatal_descriptor = descriptor("fatal_safe_stop_function", 1)
    local transcript_events = json.array()
    for index, event in ipairs({
        "INVARIANT_FAILURE_DETECTED",
        "CANDIDATE_INVOKED_IN_ISOLATED_HARNESS",
        "NORMAL_SAVE_ATTEMPT_BLOCKED",
        "AUTOSAVE_ATTEMPT_BLOCKED",
        "SAFE_STOP_REQUESTED",
        "PROCESS_EXITED_WITHOUT_SAVE",
    }) do
        transcript_events[index] = {
            sequence = index,
            event = event,
            save_write_count = 0,
        }
    end
    local fatal_transcript = {
        transcript_version = "1.0",
        kind = "fatal_execution_transcript",
        world_id = WORLD_ID,
        game_revision = REVISION,
        ue4ss_version = UE4SS_VERSION,
        mode = "SAFE_STOP",
        harness_implementation_checksum = sha256.hex(linked.fatal_harness_bytes),
        candidate_path = fatal_descriptor.path,
        candidate_signature = fatal_descriptor.type_signature,
        events = transcript_events,
    }
    if options.mutate_transcript then options.mutate_transcript(fatal_transcript) end
    local fatal_transcript_text = encode_with_checksum(fatal_transcript)
    local fatal_proof = {
        proof_version = "1.0",
        kind = "fatal_behavior_proof",
        world_id = WORLD_ID,
        game_revision = REVISION,
        ue4ss_version = UE4SS_VERSION,
        mode = "SAFE_STOP",
        selected_candidate = {
            logical_symbol = "fatal_safe_stop_function",
            candidate_index = 1,
            kind = fatal_descriptor.kind,
            path = fatal_descriptor.path,
            type_signature = fatal_descriptor.type_signature,
        },
        harness_implementation_checksum = sha256.hex(linked.fatal_harness_bytes),
        invariant_failure_observed = true,
        discovery_candidate_invoked = false,
        isolated_harness_candidate_invoked = true,
        post_failure_save_write_observed = false,
        later_normal_save_prevented = true,
        later_autosave_prevented = true,
        immediate_stop_without_save = true,
        execution_transcript_checksum = sha256.hex(fatal_transcript_text),
    }
    if options.mutate_fatal then options.mutate_fatal(fatal_proof) end
    local fatal_proof_text = encode_with_checksum(fatal_proof)

    local records = json.array()
    for _, symbol in ipairs(catalog) do
        records[#records + 1] = matched_record(symbol.name, 1)
        records[#records + 1] = mismatch_record(symbol.name, 2)
    end
    local observation = {
        observation_version = "1.0",
        kind = "discovery_observation",
        authoritative = false,
        mutation_capability = false,
        game_revision = REVISION,
        probe_request_checksum = probe.checksum,
        revision_evidence = {
            status = "MATCHED",
            observed_revision = REVISION,
            source_kind = "server_log",
            exact_source_identity = "PalServer/Saved/Logs/PalServer.log",
            source_signature = "CanonicalRevisionRecord<v1>",
            signature_coverage = "FULL",
            provenance_api = "read_revision_evidence",
            source_artifact_checksum = sha256.hex(linked.revision_source_bytes),
            invoked = false,
            authority_verified = false,
        },
        symbols = records,
        before_snapshot_54 = {
            status = "MATCHED",
            provenance_api = "snapshot_capture",
            invoked = false,
            projection_contract_checksum = sha256.hex(linked.projection_contract_bytes),
            projector_implementation_checksum = sha256.hex(
                linked.projector_implementation_bytes
            ),
            capture_source_checksum = sha256.hex(linked.capture_source_bytes),
            durability_codec_checksum = sha256.hex(linked.durability_codec_bytes),
            metadata_codec_checksum = sha256.hex(linked.metadata_codec_bytes),
            metadata_ordered_input_contract_checksum = sha256.hex(
                linked.metadata_ordered_input_contract_bytes
            ),
            snapshot = before_snapshot,
            projection_verified = false,
        },
        fatal_safety = {
            matched_candidate_index = 1,
            mode = fatal_proof.mode,
            behavior_proof_artifact_checksum = sha256.hex(fatal_proof_text),
            harness_implementation_checksum = sha256.hex(linked.fatal_harness_bytes),
            behavior_verified = false,
        },
    }
    if options.mutate_observation then options.mutate_observation(observation) end
    local observation_text = encode_with_checksum(observation)

    local manifest_symbols = {}
    for _, symbol in ipairs(catalog) do
        manifest_symbols[symbol.name] = descriptor(symbol.name, 1)
    end
    local manifest = {
        manifest_version = "1.0",
        kind = "runtime",
        game_revision = REVISION,
        source_audit_checksum = audit_table.checksum,
        symbols = manifest_symbols,
        tested_platform_matrix = { "unverified-metadata-only" },
    }
    if options.mutate_manifest then options.mutate_manifest(manifest) end
    local manifest_text = encode_with_checksum(manifest)

    local operational_report = report.build({
        audit = audit_handle,
        mode = "audit",
        state = "AUDIT_COMPLETE",
        mod_version = "1.1.0-discovery",
        binding_manifest_checksum = manifest.checksum,
        platform_preflight = platform_projection(),
        conflict_summary = {
            coverage = "partial",
            blocking = false,
            forced_noop = false,
        },
        mod_inventory = {},
        findings = { {
            code = "CGCE-CONFLICT-COVERAGE-PARTIAL",
            severity = "WARNING",
            field = "policy.gate_a_accepted",
            detail = "collision coverage remains partial until review",
            forced_noop = false,
        } },
    })
    local report_text = json.encode(operational_report)

    local artifacts = {
        probe_request = artifact(PRIVATE_ROOT .. "probe-request.json", probe_text),
        discovery_observation = artifact(
            PRIVATE_ROOT .. "discovery-observation.json",
            observation_text
        ),
        operational_report = artifact(PRIVATE_ROOT .. "operational-report.json", report_text),
        runtime_manifest = artifact(
            "CrossplayGuildChestExpander/Scripts/bindings/123456.json",
            manifest_text
        ),
        revision_source = artifact(
            PRIVATE_ROOT .. "revision-source.log",
            linked.revision_source_bytes
        ),
        projection_contract = artifact(
            "CrossplayGuildChestExpander/Scripts/discovery_evidence.lua",
            linked.projection_contract_bytes
        ),
        projector_implementation = artifact(
            "CrossplayGuildChestExpander/Scripts/snapshot.lua",
            linked.projector_implementation_bytes
        ),
        capture_source = artifact(
            "CrossplayGuildChestExpander/Scripts/audit.lua",
            linked.capture_source_bytes
        ),
        durability_codec = artifact(
            "CrossplayGuildChestExpander/Scripts/fingerprint.lua",
            linked.durability_codec_bytes
        ),
        metadata_codec = artifact(
            "CrossplayGuildChestExpander/Scripts/json.lua",
            linked.metadata_codec_bytes
        ),
        metadata_ordered_input_contract = artifact(
            "CrossplayGuildChestExpander/Scripts/sha256.lua",
            linked.metadata_ordered_input_contract_bytes
        ),
        fatal_behavior_proof = artifact(
            PRIVATE_ROOT .. "fatal-behavior-proof.json",
            fatal_proof_text
        ),
        fatal_harness = artifact(
            PRIVATE_ROOT .. "fatal-harness.lua",
            linked.fatal_harness_bytes
        ),
        fatal_execution_transcript = artifact(
            PRIVATE_ROOT .. "fatal-execution-transcript.json",
            fatal_transcript_text
        ),
    }
    local review = {
        evidence_version = "1.0",
        kind = "gate_a_review_request",
        scope = "prd32_items_1_16_plus_fatal",
        mutation_capability = false,
        release_eligible = false,
        game_revision = REVISION,
        world_id = WORLD_ID,
        deployment_profile = PROFILE,
        ue4ss_version = UE4SS_VERSION,
        reviewer = REVIEWER,
        reviewed_at = REVIEWED_AT,
        artifacts = artifacts,
        review_attestation = {
            revision_authority_verified = true,
            all_symbols_reviewed = true,
            snapshot_runtime_mapping_verified = true,
            fatal_behavior_independently_reviewed = true,
            ownership_exclusion_verified = true,
        },
    }
    if options.mutate_review then options.mutate_review(review) end
    local review_text = encode_with_checksum(review)
    if options.mutate_review_after_checksum then
        local drifted = json.decode(review_text)
        options.mutate_review_after_checksum(drifted)
        review_text = json.encode(drifted)
    end

    local artifact_bytes = {
        probe_request = probe_text,
        discovery_observation = observation_text,
        operational_report = report_text,
        runtime_manifest = manifest_text,
        revision_source = linked.revision_source_bytes,
        projection_contract = linked.projection_contract_bytes,
        projector_implementation = linked.projector_implementation_bytes,
        capture_source = linked.capture_source_bytes,
        durability_codec = linked.durability_codec_bytes,
        metadata_codec = linked.metadata_codec_bytes,
        metadata_ordered_input_contract = linked.metadata_ordered_input_contract_bytes,
        fatal_behavior_proof = fatal_proof_text,
        fatal_harness = linked.fatal_harness_bytes,
        fatal_execution_transcript = fatal_transcript_text,
    }
    local files = { [PRIVATE_ROOT .. "gate-a-evidence.json"] = review_text }
    for role, bytes in pairs(artifact_bytes) do
        files[artifacts[role].relative_path] = bytes
    end
    if options.mutate_files then options.mutate_files(files, artifacts) end

    local inputs = {
        repository_root = REPOSITORY_ROOT,
        source_relative_path = PRIVATE_ROOT .. "gate-a-evidence.json",
        filesystem_read = read_only_filesystem(
            files,
            options.reparse_artifact_role
                and artifacts[options.reparse_artifact_role].relative_path
                or nil
        ),
    }
    local expected = {
        game_revision = REVISION,
        world_id = WORLD_ID,
        deployment_profile = PROFILE,
        ue4ss_version = UE4SS_VERSION,
        reviewer = REVIEWER,
        reviewed_at = REVIEWED_AT,
        review_request_checksum = review.checksum,
        reviewer_authorization_checksum = REVIEW_AUTHORIZATION_CHECKSUM,
    }
    if options.mutate_inputs then options.mutate_inputs(inputs) end
    if options.mutate_expected then options.mutate_expected(expected) end
    return inputs, expected
end

local function expect_error(code, field, inputs, expected)
    local ok, err = pcall(gate_a_evidence.accept, inputs, expected)
    a.equal(false, ok)
    a.equal("table", type(err))
    a.equal(code, err.code)
    a.equal(field, err.field)
    a.equal("string", type(err.detail))
    return err
end

describe("Gate A private evidence", function()
    it("emits a deterministic opaque non-mutation acceptance receipt", function()
        local inputs, expected = build_fixture()
        local first = gate_a_evidence.accept(inputs, expected)
        local second = gate_a_evidence.accept(inputs, expected)
        local receipt = gate_a_evidence.to_table(first)

        a.equal("function", type(first))
        a.equal("1.0", receipt.acceptance_version)
        a.equal("gate_a_acceptance", receipt.kind)
        a.equal("prd32_items_1_16_plus_fatal", receipt.scope)
        a.equal("ACCEPTED_READ_ONLY_EVIDENCE", receipt.status)
        a.equal(false, receipt.mutation_capability)
        a.equal(false, receipt.release_eligible)
        a.equal(false, receipt.behavior_authorized)
        a.equal(REVISION, receipt.game_revision)
        a.equal(WORLD_ID, receipt.world_id)
        a.equal(PROFILE, receipt.deployment_profile)
        a.equal(UE4SS_VERSION, receipt.ue4ss_version)
        a.equal(REVIEWER, receipt.reviewer)
        a.equal(REVIEWED_AT, receipt.reviewed_at)
        a.equal(REVIEW_AUTHORIZATION_CHECKSUM, receipt.reviewer_authorization_checksum)
        a.equal("SAFE_STOP", receipt.fatal_mode)
        a.equal(16, #receipt.verified_items)
        for index, item in ipairs(receipt.verified_items) do
            a.equal(index, item.number)
            local expected_status = index == 1 and "RUNTIME_AUTHORITY_REVIEWED"
                or (index == 16 and "RUNTIME_MAPPING_REVIEWED" or "IDENTITY_REVIEWED")
            a.equal(expected_status, item.status)
            a.equal(64, #item.evidence_checksum)
        end
        a.equal(receipt.checksum, gate_a_evidence.checksum(first))
        a.equal(gate_a_evidence.canonical_json(first), gate_a_evidence.canonical_json(second))
        a.equal(false, gate_a_evidence.mutation_capability(first))
        a.equal(false, gate_a_evidence.release_eligible(first))
        a.equal(false, gate_a_evidence.behavior_authorized(first))
        a.equal(nil, receipt.target_slots)
        a.equal(nil, receipt.certified_clients)
        a.equal(nil, gate_a_evidence.canonical_json(first):find("private/guild", 1, true))
        a.equal(nil, gate_a_evidence.canonical_json(first):find("private/container", 1, true))

        local verified = gate_a_evidence.verify(
            gate_a_evidence.canonical_json(first),
            inputs,
            expected
        )
        a.equal(gate_a_evidence.checksum(first), gate_a_evidence.checksum(verified))

        local table_ok = pcall(gate_a_evidence.to_table, receipt)
        a.equal(false, table_ok)
    end)

    it("rejects public or traversing raw-evidence paths", function()
        local inputs, expected = build_fixture({
            mutate_inputs = function(value)
                value.source_relative_path = "docs/gate-a-evidence.json"
            end,
        })
        expect_error("CGCE-GATEA-PATH", "source_relative_path", inputs, expected)

        inputs, expected = build_fixture({
            mutate_review = function(value)
                value.artifacts.operational_report.relative_path = "docs/operational-report.json"
            end,
        })
        expect_error(
            "CGCE-GATEA-PATH",
            "artifacts.operational_report.relative_path",
            inputs,
            expected
        )

        inputs, expected = build_fixture({ reparse_artifact_role = "projection_contract" })
        expect_error(
            "CGCE-GATEA-PATH",
            "artifacts.projection_contract",
            inputs,
            expected
        )

        inputs, expected = build_fixture({
            mutate_inputs = function(value)
                value.source_relative_path = "private-artifacts/discovery/123456/../gate-a-evidence.json"
            end,
        })
        expect_error("CGCE-GATEA-PATH", "source_relative_path", inputs, expected)
    end)

    it("rejects artifact roles that resolve to the same Windows target", function()
        local canonical_path = "CrossplayGuildChestExpander/Scripts/snapshot.lua"
        local case_alias = "CrossplayGuildChestExpander/Scripts/SNAPSHOT.LUA"
        local bytes = read(canonical_path)
        local checksum = sha256.hex(bytes)
        local inputs, expected = build_fixture({
            mutate_observation = function(value)
                value.before_snapshot_54.capture_source_checksum = checksum
            end,
            mutate_review = function(value)
                value.artifacts.capture_source.relative_path = case_alias
                value.artifacts.capture_source.checksum = checksum
            end,
            mutate_files = function(files)
                files[canonical_path] = bytes
                files[case_alias] = bytes
            end,
        })

        expect_error(
            "CGCE-GATEA-PATH",
            "artifacts.capture_source.relative_path",
            inputs,
            expected
        )
    end)

    it("rejects partial, unloaded, or invoked discovery evidence", function()
        local inputs, expected = build_fixture({
            mutate_observation = function(value)
                for _, record in ipairs(value.symbols) do
                    if record.logical_symbol == "resize_function"
                        and record.candidate_index == 1 then
                        record.status = "NOT_LOADED"
                        record.observed_full_name = json.null
                        record.canonical_signature = json.null
                        record.signature_coverage = "NONE"
                    end
                end
            end,
        })
        expect_error(
            "CGCE-GATEA-OBSERVATION",
            "discovery_observation",
            inputs,
            expected
        )

        inputs, expected = build_fixture({
            mutate_observation = function(value)
                value.symbols[1].invoked = true
            end,
        })
        expect_error(
            "CGCE-GATEA-OBSERVATION",
            "discovery_observation",
            inputs,
            expected
        )
    end)

    it("rejects manifest descriptor and linked-byte drift", function()
        local inputs, expected = build_fixture({
            mutate_manifest = function(value)
                value.symbols.resize_function.path = "/GateA/DifferentResize"
            end,
        })
        expect_error(
            "CGCE-GATEA-MANIFEST",
            "runtime_manifest.symbols.resize_function",
            inputs,
            expected
        )

        inputs, expected = build_fixture({
            mutate_files = function(files, artifacts)
                local path = artifacts.projection_contract.relative_path
                files[path] = files[path] .. "drift"
            end,
        })
        expect_error(
            "CGCE-GATEA-LINK",
            "artifacts.projection_contract.checksum",
            inputs,
            expected
        )
    end)

    it("rejects unverified fatal behavior and identity mismatch", function()
        local inputs, expected = build_fixture({
            mutate_fatal = function(value)
                value.immediate_stop_without_save = false
            end,
        })
        expect_error(
            "CGCE-GATEA-FATAL",
            "fatal_behavior_proof.immediate_stop_without_save",
            inputs,
            expected
        )

        inputs, expected = build_fixture({
            mutate_expected = function(value)
                value.ue4ss_version = "3.0.2"
            end,
        })
        expect_error(
            "CGCE-GATEA-IDENTITY",
            "ue4ss_version",
            inputs,
            expected
        )

        inputs, expected = build_fixture({
            mutate_runtime_identity = function(value)
                value.ue4ss_version = "3.0.2"
            end,
        })
        expect_error(
            "CGCE-GATEA-IDENTITY",
            "runtime_identity_evidence",
            inputs,
            expected
        )

        inputs, expected = build_fixture({
            mutate_transcript = function(value)
                value.events[4].save_write_count = 1
            end,
        })
        expect_error(
            "CGCE-GATEA-FATAL",
            "fatal_execution_transcript.events[4]",
            inputs,
            expected
        )
    end)

    it("captures trusted scalar inputs before filesystem callbacks", function()
        local inputs, expected = build_fixture()
        local capabilities = inputs.filesystem_read.capabilities
        inputs.filesystem_read.capabilities = function()
            inputs.repository_root = "C:\\Mutated-Root"
            inputs.source_relative_path = "docs/gate-a-evidence.json"
            expected.game_revision = REVISION + 1
            expected.world_id = "mutated/world"
            expected.deployment_profile = "mutated-profile"
            expected.ue4ss_version = "3.0.2"
            expected.reviewer = "Mutated Reviewer"
            expected.reviewed_at = "2026-07-23T12:34:56Z"
            expected.review_request_checksum = string.rep("d", 64)
            expected.reviewer_authorization_checksum = string.rep("f", 64)
            return capabilities()
        end

        local handle = gate_a_evidence.accept(inputs, expected)
        local receipt = gate_a_evidence.to_table(handle)
        a.equal(REVISION, receipt.game_revision)
        a.equal(WORLD_ID, receipt.world_id)
        a.equal(PROFILE, receipt.deployment_profile)
        a.equal(UE4SS_VERSION, receipt.ue4ss_version)
        a.equal(REVIEWER, receipt.reviewer)
        a.equal(REVIEWED_AT, receipt.reviewed_at)
        a.equal(REVIEW_AUTHORIZATION_CHECKSUM, receipt.reviewer_authorization_checksum)
    end)

    it("does not let filesystem callbacks repair a mismatched trusted review pin", function()
        local inputs, expected = build_fixture()
        local review_checksum = expected.review_request_checksum
        local capabilities = inputs.filesystem_read.capabilities
        expected.review_request_checksum = string.rep("d", 64)
        inputs.filesystem_read.capabilities = function()
            expected.review_request_checksum = review_checksum
            return capabilities()
        end

        expect_error(
            "CGCE-GATEA-IDENTITY",
            "review_request_checksum",
            inputs,
            expected
        )
    end)

    it("rejects malformed review checksums and forged receipts", function()
        local inputs, expected = build_fixture({
            mutate_review_after_checksum = function(review)
                review.reviewer = "Changed Reviewer"
            end,
        })
        expect_error(
            "CGCE-GATEA-CHECKSUM",
            "review_request.checksum",
            inputs,
            expected
        )

        inputs, expected = build_fixture({
            mutate_expected = function(value)
                value.review_request_checksum = string.rep("d", 64)
            end,
        })
        expect_error(
            "CGCE-GATEA-IDENTITY",
            "review_request_checksum",
            inputs,
            expected
        )

        inputs, expected = build_fixture()
        local handle = gate_a_evidence.accept(inputs, expected)
        local receipt = gate_a_evidence.to_table(handle)
        receipt.status = "FORGED"
        local ok, err = pcall(
            gate_a_evidence.verify,
            json.encode(receipt),
            inputs,
            expected
        )
        a.equal(false, ok)
        a.equal("CGCE-GATEA-RECEIPT", err.code)
    end)

    it("publishes a strict schema for private review requests", function()
        local file = assert(io.open("docs/gate-a-evidence.schema.json", "rb"))
        local schema = json.decode(file:read("*a"))
        file:close()

        a.equal("https://json-schema.org/draft/2020-12/schema", schema["$schema"])
        a.equal("object", schema.type)
        a.equal(false, schema.additionalProperties)
        a.equal(true, schema.properties.artifacts.additionalProperties == false)
        a.equal(true, schema.properties.review_attestation.additionalProperties == false)
        a.equal(14, #schema.required)
    end)
end)
