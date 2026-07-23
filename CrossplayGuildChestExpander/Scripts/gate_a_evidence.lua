local binding_manifest_module = require("CrossplayGuildChestExpander.Scripts.binding_manifest")
local binding_symbols_module = require("CrossplayGuildChestExpander.Scripts.binding_symbols")
local discovery_evidence_module = require("CrossplayGuildChestExpander.Scripts.discovery_evidence")
local discovery_probe_module = require("CrossplayGuildChestExpander.Scripts.discovery_probe")
local json_module = require("CrossplayGuildChestExpander.Scripts.json")
local path_guard_module = require("CrossplayGuildChestExpander.Scripts.path_guard")
local report_module = require("CrossplayGuildChestExpander.Scripts.report")
local sha256_module = require("CrossplayGuildChestExpander.Scripts.sha256")

local binding_manifest_parse = binding_manifest_module.parse
local binding_symbols_list = binding_symbols_module.list
local discovery_evidence_checksum = discovery_evidence_module.checksum
local discovery_evidence_manifest_readiness = discovery_evidence_module.manifest_readiness
local discovery_evidence_parse = discovery_evidence_module.parse
local discovery_evidence_to_table = discovery_evidence_module.to_table
local discovery_probe_checksum = discovery_probe_module.checksum
local discovery_probe_parse = discovery_probe_module.parse
local discovery_probe_to_table = discovery_probe_module.to_table
local json_array = json_module.array
local json_decode = json_module.decode
local json_encode = json_module.encode
local path_resolve = path_guard_module.resolve
local report_validate = report_module.validate
local sha256_hex = sha256_module.hex

local gate_a_evidence = {}

local REVIEW_VERSION = "1.0"
local ACCEPTANCE_VERSION = "1.0"
local SUPPORTED_UE4SS_VERSION = "3.0.1"
local DEPLOYMENT_PROFILE = "windows-dedicated-ps5-macos-required"
local SCOPE = "prd32_items_1_16_plus_fatal"

local input_order = {
    "repository_root",
    "source_relative_path",
    "filesystem_read",
}

local expected_order = {
    "game_revision",
    "world_id",
    "deployment_profile",
    "ue4ss_version",
    "reviewer",
    "reviewed_at",
    "review_request_checksum",
    "reviewer_authorization_checksum",
}

local review_order = {
    "evidence_version",
    "kind",
    "scope",
    "mutation_capability",
    "release_eligible",
    "game_revision",
    "world_id",
    "deployment_profile",
    "ue4ss_version",
    "reviewer",
    "reviewed_at",
    "artifacts",
    "review_attestation",
    "checksum",
}

local artifact_roles = {
    "probe_request",
    "discovery_observation",
    "operational_report",
    "runtime_manifest",
    "revision_source",
    "projection_contract",
    "projector_implementation",
    "capture_source",
    "durability_codec",
    "metadata_codec",
    "metadata_ordered_input_contract",
    "fatal_behavior_proof",
    "fatal_harness",
    "fatal_execution_transcript",
}

local private_artifact_filenames = {
    probe_request = "probe-request.json",
    discovery_observation = "discovery-observation.json",
    operational_report = "operational-report.json",
    revision_source = "revision-source.log",
    fatal_behavior_proof = "fatal-behavior-proof.json",
    fatal_harness = "fatal-harness.lua",
    fatal_execution_transcript = "fatal-execution-transcript.json",
}

local implementation_roles = {
    projection_contract = true,
    projector_implementation = true,
    capture_source = true,
    durability_codec = true,
    metadata_codec = true,
    metadata_ordered_input_contract = true,
}

local attestation_order = {
    "revision_authority_verified",
    "all_symbols_reviewed",
    "snapshot_runtime_mapping_verified",
    "fatal_behavior_independently_reviewed",
    "ownership_exclusion_verified",
}

local fatal_order = {
    "proof_version",
    "kind",
    "world_id",
    "game_revision",
    "ue4ss_version",
    "mode",
    "selected_candidate",
    "harness_implementation_checksum",
    "invariant_failure_observed",
    "discovery_candidate_invoked",
    "isolated_harness_candidate_invoked",
    "post_failure_save_write_observed",
    "later_normal_save_prevented",
    "later_autosave_prevented",
    "immediate_stop_without_save",
    "execution_transcript_checksum",
    "checksum",
}

local runtime_identity_order = {
    "evidence_version",
    "kind",
    "world_id",
    "game_revision",
    "ue4ss_version",
    "source_kind",
    "exact_source_identity",
    "source_signature",
    "checksum",
}

local transcript_order = {
    "transcript_version",
    "kind",
    "world_id",
    "game_revision",
    "ue4ss_version",
    "mode",
    "harness_implementation_checksum",
    "candidate_path",
    "candidate_signature",
    "events",
    "checksum",
}

local transcript_event_order = {
    "sequence",
    "event",
    "save_write_count",
}

local fatal_candidate_order = {
    "logical_symbol",
    "candidate_index",
    "kind",
    "path",
    "type_signature",
}

local receipt_order = {
    "acceptance_version",
    "kind",
    "scope",
    "status",
    "mutation_capability",
    "release_eligible",
    "behavior_authorized",
    "game_revision",
    "world_id",
    "deployment_profile",
    "ue4ss_version",
    "reviewer",
    "reviewed_at",
    "review_request_checksum",
    "reviewer_authorization_checksum",
    "probe_request_checksum",
    "discovery_observation_checksum",
    "operational_report_checksum",
    "audit_checksum",
    "binding_manifest_checksum",
    "revision_source_checksum",
    "projection_contract_checksum",
    "projector_implementation_checksum",
    "capture_source_checksum",
    "durability_codec_checksum",
    "metadata_codec_checksum",
    "metadata_ordered_input_contract_checksum",
    "fatal_mode",
    "fatal_behavior_proof_checksum",
    "fatal_harness_checksum",
    "fatal_execution_transcript_checksum",
    "verified_items",
    "checksum",
}

local verified_item_order = {
    "number",
    "name",
    "status",
    "evidence_checksum",
}

local prd_items = {
    { number = 1, name = "current_revision_authority", source = "revision" },
    { number = 2, name = "guild_manager_class", symbol = "guild_manager_class" },
    { number = 3, name = "guild_list_path", symbol = "guild_list_property" },
    { number = 4, name = "guild_id_property", symbol = "guild_id_property" },
    {
        number = 5,
        name = "guild_chest_container_id_property",
        symbol = "guild_chest_container_id_property",
    },
    { number = 6, name = "container_manager_class", symbol = "container_manager_class" },
    { number = 7, name = "container_lookup_function", symbol = "find_container_function" },
    { number = 8, name = "slot_array_property", symbol = "slot_array_property" },
    { number = 9, name = "empty_slot_type_identity", symbol = "empty_slot_type" },
    { number = 10, name = "resize_or_append_candidate_identity", symbol = "resize_function" },
    { number = 11, name = "dirty_function_identity", symbol = "mark_dirty_function" },
    { number = 12, name = "replication_request_identity", symbol = "replicate_function" },
    { number = 13, name = "world_ready_hook", symbol = "world_ready_function" },
    { number = 14, name = "new_guild_hook", symbol = "new_guild_function" },
    { number = 15, name = "container_in_use_method", symbol = "container_in_use_function" },
    { number = 16, name = "canonical_54_slot_runtime_mapping", source = "snapshot" },
}

local receipt_records = setmetatable({}, { __mode = "k" })

local function problem(code, field, detail)
    return { code = code, field = field, detail = detail }
end

local function fail(code, field, detail)
    error(problem(code, field, detail), 0)
end

local function allowed_map(order)
    local allowed = {}
    for _, field in ipairs(order) do
        allowed[field] = true
    end
    return allowed
end

local input_fields = allowed_map(input_order)
local expected_fields = allowed_map(expected_order)
local review_fields = allowed_map(review_order)
local artifact_fields = allowed_map(artifact_roles)
local artifact_link_fields = { relative_path = true, checksum = true }
local attestation_fields = allowed_map(attestation_order)
local fatal_fields = allowed_map(fatal_order)
local fatal_candidate_fields = allowed_map(fatal_candidate_order)
local runtime_identity_fields = allowed_map(runtime_identity_order)
local transcript_fields = allowed_map(transcript_order)
local transcript_event_fields = allowed_map(transcript_event_order)
local receipt_fields = allowed_map(receipt_order)
local verified_item_fields = allowed_map(verified_item_order)
local filesystem_order = {
    "capabilities",
    "canonicalize",
    "inspect_no_follow",
    "propose_temp_sibling",
    "read_all_no_follow",
}
local filesystem_fields = allowed_map(filesystem_order)

local function is_plain_object(value)
    return type(value) == "table"
        and getmetatable(value) == nil
end

local function validate_object(value, allowed, order, field, code)
    if not is_plain_object(value) then
        fail(code, field, field .. " must be a plain object")
    end
    local unknown = {}
    local invalid_key = false
    for key in next, value do
        if type(key) ~= "string" then
            invalid_key = true
        elseif not allowed[key] then
            unknown[#unknown + 1] = key
        end
    end
    table.sort(unknown)
    if invalid_key then
        fail(code, field, field .. " keys must be strings")
    end
    if unknown[1] ~= nil then
        fail(code, field .. "." .. unknown[1], "unknown field")
    end
    for _, name in ipairs(order) do
        if rawget(value, name) == nil then
            fail(code, field .. "." .. name, "required field is missing")
        end
    end
end

local function dense_array_length(value, field, code)
    if type(value) ~= "table" or getmetatable(value) ~= nil then
        fail(code, field, field .. " must be a dense array")
    end
    if next(value) == nil then
        if json_encode(value) ~= "[]" then
            fail(code, field, field .. " must be a dense array")
        end
        return 0
    end
    local count = 0
    local largest = 0
    for key in next, value do
        if type(key) ~= "number" or math.type(key) ~= "integer" or key < 1 then
            fail(code, field, field .. " must be a dense array")
        end
        count = count + 1
        if key > largest then
            largest = key
        end
    end
    if count ~= largest then
        fail(code, field, field .. " must be a dense array")
    end
    return count
end

local function is_sha256(value)
    return type(value) == "string"
        and #value == 64
        and value:match("^[0-9a-f]+$") ~= nil
end

local function is_positive_integer(value)
    return type(value) == "number"
        and math.type(value) == "integer"
        and value > 0
end

local function validate_text(value, field, maximum)
    if type(value) ~= "string"
        or #value == 0
        or #value > maximum
        or value:match("^%s") ~= nil
        or value:match("%s$") ~= nil
        or value:find("[%z\1-\31\127]") ~= nil
        or not pcall(json_encode, value) then
        fail("CGCE-GATEA-IDENTITY", field, field .. " must be bounded control-free text")
    end
    return value
end

local function leap_year(year)
    return year % 400 == 0 or (year % 4 == 0 and year % 100 ~= 0)
end

local function valid_timestamp(value)
    if type(value) ~= "string" then
        return false
    end
    local year, month, day, hour, minute, second = value:match(
        "^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)Z$"
    )
    year, month, day = tonumber(year), tonumber(month), tonumber(day)
    hour, minute, second = tonumber(hour), tonumber(minute), tonumber(second)
    if year == nil
        or year < 2000
        or month < 1
        or month > 12
        or hour > 23
        or minute > 59
        or second > 59 then
        return false
    end
    local days = { 31, leap_year(year) and 29 or 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
    return day >= 1 and day <= days[month]
end

local function parse_json_object(text, code, field)
    if type(text) ~= "string" then
        fail(code, field, field .. " must be JSON text")
    end
    local ok, value = pcall(json_decode, text)
    if not ok or not is_plain_object(value) then
        fail(code, field, field .. " must be a valid JSON object")
    end
    return value
end

local function verify_self_checksum(value, text, code, field)
    if not is_sha256(value.checksum) then
        fail(code, field .. ".checksum", "checksum must be lowercase SHA-256")
    end
    local unsigned = {}
    for key, item in next, value do
        if key ~= "checksum" then
            unsigned[key] = item
        end
    end
    if sha256_hex(json_encode(unsigned)) ~= value.checksum then
        fail(code, field .. ".checksum", "self-checksum mismatch")
    end
    if json_encode(value) ~= text then
        fail(code, field, field .. " must use canonical JSON bytes")
    end
end

local function exact_relative_path(value)
    if type(value) ~= "string"
        or #value == 0
        or value:find("[%z\1-\31\127]") ~= nil
        or value:sub(1, 1) == "/"
        or value:sub(1, 1) == "\\"
        or value:find("\\", 1, true) ~= nil
        or value:find("//", 1, true) ~= nil
        or value:find(":", 1, true) ~= nil
        or value:sub(-1) == "/" then
        return false
    end
    for segment in value:gmatch("[^/]+") do
        if segment == "." or segment == ".." or segment == "" then
            return false
        end
    end
    return true
end

local function private_root(revision)
    return "private-artifacts/discovery/" .. tostring(revision) .. "/"
end

local function validate_review_path(value, revision)
    if not exact_relative_path(value)
        or value ~= private_root(revision) .. "gate-a-evidence.json" then
        fail(
            "CGCE-GATEA-PATH",
            "source_relative_path",
            "Gate A review requests must use the exact ignored private path"
        )
    end
end

local function validate_artifact_path(role, value, revision)
    local field = "artifacts." .. role .. ".relative_path"
    if not exact_relative_path(value) then
        fail("CGCE-GATEA-PATH", field, "artifact path must be exact and repository-relative")
    end
    local private_filename = private_artifact_filenames[role]
    if private_filename ~= nil then
        if value ~= private_root(revision) .. private_filename then
            fail("CGCE-GATEA-PATH", field, "raw operational evidence must stay private")
        end
        return
    end
    if role == "runtime_manifest" then
        local expected = "CrossplayGuildChestExpander/Scripts/bindings/"
            .. tostring(revision) .. ".json"
        if value ~= expected then
            fail("CGCE-GATEA-PATH", field, "runtime manifest path does not match revision")
        end
        return
    end
    if implementation_roles[role]
        and value:sub(1, #"CrossplayGuildChestExpander/Scripts/")
            == "CrossplayGuildChestExpander/Scripts/" then
        return
    end
    fail("CGCE-GATEA-PATH", field, "linked implementation path is outside the allow-list")
end

local function validate_inputs(inputs)
    validate_object(inputs, input_fields, input_order, "inputs", "CGCE-GATEA-SCHEMA")
    if type(inputs.repository_root) ~= "string" or #inputs.repository_root == 0 then
        fail("CGCE-GATEA-SCHEMA", "inputs.repository_root", "repository root must be non-empty text")
    end
    if type(inputs.source_relative_path) ~= "string" or #inputs.source_relative_path == 0 then
        fail("CGCE-GATEA-SCHEMA", "inputs.source_relative_path", "review path must be non-empty text")
    end
    validate_object(
        inputs.filesystem_read,
        filesystem_fields,
        filesystem_order,
        "inputs.filesystem_read",
        "CGCE-GATEA-SCHEMA"
    )
    local captured = {}
    for _, name in ipairs(filesystem_order) do
        local port = rawget(inputs.filesystem_read, name)
        if type(port) ~= "function" then
            fail(
                "CGCE-GATEA-SCHEMA",
                "inputs.filesystem_read." .. name,
                "required no-follow read port is unavailable"
            )
        end
        captured[name] = port
    end
    return {
        repository_root = inputs.repository_root,
        source_relative_path = inputs.source_relative_path,
        filesystem_read = captured,
    }
end

local function validate_expected(expected)
    validate_object(expected, expected_fields, expected_order, "expected", "CGCE-GATEA-SCHEMA")
    if not is_positive_integer(expected.game_revision) then
        fail("CGCE-GATEA-IDENTITY", "game_revision", "game revision must be a positive integer")
    end
    validate_text(expected.world_id, "world_id", 512)
    validate_text(expected.deployment_profile, "deployment_profile", 128)
    validate_text(expected.ue4ss_version, "ue4ss_version", 32)
    validate_text(expected.reviewer, "reviewer", 200)
    if expected.deployment_profile ~= DEPLOYMENT_PROFILE then
        fail("CGCE-GATEA-IDENTITY", "deployment_profile", "deployment profile is unsupported")
    end
    if expected.ue4ss_version ~= SUPPORTED_UE4SS_VERSION then
        fail("CGCE-GATEA-IDENTITY", "ue4ss_version", "UE4SS version is not the reviewed contract")
    end
    if not valid_timestamp(expected.reviewed_at) then
        fail("CGCE-GATEA-IDENTITY", "reviewed_at", "review timestamp must be strict UTC RFC3339")
    end
    if not is_sha256(expected.review_request_checksum) then
        fail(
            "CGCE-GATEA-IDENTITY",
            "review_request_checksum",
            "trusted review checksum pin must be lowercase SHA-256"
        )
    end
    if not is_sha256(expected.reviewer_authorization_checksum) then
        fail(
            "CGCE-GATEA-IDENTITY",
            "reviewer_authorization_checksum",
            "external reviewer authorization pin must be lowercase SHA-256"
        )
    end
    return {
        game_revision = expected.game_revision,
        world_id = expected.world_id,
        deployment_profile = expected.deployment_profile,
        ue4ss_version = expected.ue4ss_version,
        reviewer = expected.reviewer,
        reviewed_at = expected.reviewed_at,
        review_request_checksum = expected.review_request_checksum,
        reviewer_authorization_checksum = expected.reviewer_authorization_checksum,
    }
end

local function read_no_follow(fs, root, relative_path, field)
    local resolved_ok, resolved = pcall(path_resolve, fs, root, relative_path)
    if not resolved_ok then
        fail("CGCE-GATEA-PATH", field, "no-follow artifact path resolution failed")
    end
    local read_ok, bytes, returned_error = pcall(fs.read_all_no_follow, resolved.target)
    if not read_ok or returned_error ~= nil or type(bytes) ~= "string" or #bytes == 0 then
        fail("CGCE-GATEA-LINK", field, "artifact could not be read through the no-follow port")
    end
    return bytes, resolved.target
end

local function parse_review(text, inputs, expected)
    local value = parse_json_object(text, "CGCE-GATEA-JSON", "review_request")
    validate_object(value, review_fields, review_order, "review_request", "CGCE-GATEA-SCHEMA")
    verify_self_checksum(value, text, "CGCE-GATEA-CHECKSUM", "review_request")
    if value.checksum ~= expected.review_request_checksum then
        fail(
            "CGCE-GATEA-IDENTITY",
            "review_request_checksum",
            "review request does not match the externally trusted checksum pin"
        )
    end

    if value.evidence_version ~= REVIEW_VERSION
        or value.kind ~= "gate_a_review_request"
        or value.scope ~= SCOPE
        or value.mutation_capability ~= false
        or value.release_eligible ~= false then
        fail("CGCE-GATEA-SCHEMA", "review_request", "unsupported Gate A review contract")
    end
    if value.game_revision ~= expected.game_revision then
        fail("CGCE-GATEA-IDENTITY", "game_revision", "review revision does not match expected")
    end
    for _, field in ipairs({
        "world_id",
        "deployment_profile",
        "ue4ss_version",
        "reviewer",
        "reviewed_at",
    }) do
        if value[field] ~= expected[field] then
            fail("CGCE-GATEA-IDENTITY", field, "review identity does not match expected")
        end
    end
    validate_text(value.world_id, "world_id", 512)
    validate_text(value.deployment_profile, "deployment_profile", 128)
    validate_text(value.ue4ss_version, "ue4ss_version", 32)
    validate_text(value.reviewer, "reviewer", 200)
    if not valid_timestamp(value.reviewed_at) then
        fail("CGCE-GATEA-IDENTITY", "reviewed_at", "review timestamp must be strict UTC RFC3339")
    end

    validate_review_path(inputs.source_relative_path, expected.game_revision)
    validate_object(
        value.artifacts,
        artifact_fields,
        artifact_roles,
        "artifacts",
        "CGCE-GATEA-SCHEMA"
    )
    local seen_paths = {}
    for _, role in ipairs(artifact_roles) do
        local link = value.artifacts[role]
        validate_object(
            link,
            artifact_link_fields,
            { "relative_path", "checksum" },
            "artifacts." .. role,
            "CGCE-GATEA-SCHEMA"
        )
        validate_artifact_path(role, link.relative_path, expected.game_revision)
        if seen_paths[link.relative_path] then
            fail("CGCE-GATEA-PATH", "artifacts." .. role .. ".relative_path", "artifact paths must be unique")
        end
        seen_paths[link.relative_path] = true
        if not is_sha256(link.checksum) then
            fail(
                "CGCE-GATEA-CHECKSUM",
                "artifacts." .. role .. ".checksum",
                "artifact checksum must be lowercase SHA-256"
            )
        end
    end

    validate_object(
        value.review_attestation,
        attestation_fields,
        attestation_order,
        "review_attestation",
        "CGCE-GATEA-SCHEMA"
    )
    for _, field in ipairs(attestation_order) do
        if value.review_attestation[field] ~= true then
            fail(
                "CGCE-GATEA-SCHEMA",
                "review_attestation." .. field,
                "every independent review attestation must be true"
            )
        end
    end
    return value
end

local function load_actual_links(review, fs, root)
    local actuals = {}
    local seen_targets = {}
    for _, role in ipairs(artifact_roles) do
        local field = "artifacts." .. role
        local bytes, target = read_no_follow(
            fs,
            root,
            review.artifacts[role].relative_path,
            field
        )
        local target_key = target:gsub("/", "\\"):lower()
        if seen_targets[target_key] ~= nil then
            fail(
                "CGCE-GATEA-PATH",
                field .. ".relative_path",
                "artifact roles must resolve to distinct canonical targets"
            )
        end
        seen_targets[target_key] = role
        if review.artifacts[role].checksum ~= sha256_hex(bytes) then
            fail(
                "CGCE-GATEA-LINK",
                "artifacts." .. role .. ".checksum",
                "linked artifact bytes do not match the reviewed checksum"
            )
        end
        actuals[role] = bytes
    end
    return actuals
end

local function guarded_parse(code, field, parser, ...)
    local ok, value = pcall(parser, ...)
    if not ok then
        fail(code, field, "linked artifact failed its canonical validator")
    end
    return value
end

local function parse_sources(actuals, expected)
    local probe_handle = guarded_parse(
        "CGCE-GATEA-OBSERVATION",
        "probe_request",
        discovery_probe_parse,
        actuals.probe_request
    )
    local probe_value = discovery_probe_to_table(probe_handle)
    if actuals.probe_request ~= json_encode(probe_value) then
        fail("CGCE-GATEA-OBSERVATION", "probe_request", "probe request must be canonical JSON")
    end

    local observation_handle = guarded_parse(
        "CGCE-GATEA-OBSERVATION",
        "discovery_observation",
        discovery_evidence_parse,
        actuals.discovery_observation,
        probe_handle,
        expected.game_revision
    )
    local observation = discovery_evidence_to_table(observation_handle)
    if actuals.discovery_observation ~= json_encode(observation) then
        fail(
            "CGCE-GATEA-OBSERVATION",
            "discovery_observation",
            "discovery observation must be canonical JSON"
        )
    end
    local readiness = discovery_evidence_manifest_readiness(observation_handle)
    if readiness.ready ~= true or #readiness.blockers ~= 0 then
        fail(
            "CGCE-GATEA-OBSERVATION",
            "discovery_observation",
            "all symbol candidates must have one full match and full mismatches"
        )
    end

    local manifest = guarded_parse(
        "CGCE-GATEA-MANIFEST",
        "runtime_manifest",
        binding_manifest_parse,
        actuals.runtime_manifest
    )
    if actuals.runtime_manifest ~= json_encode(manifest) then
        fail("CGCE-GATEA-MANIFEST", "runtime_manifest", "runtime manifest must be canonical JSON")
    end

    local report_value = parse_json_object(
        actuals.operational_report,
        "CGCE-GATEA-REPORT",
        "operational_report"
    )
    local validated_report = guarded_parse(
        "CGCE-GATEA-REPORT",
        "operational_report",
        report_validate,
        report_value
    )
    if actuals.operational_report ~= json_encode(validated_report) then
        fail("CGCE-GATEA-REPORT", "operational_report", "operational report must be canonical JSON")
    end
    return {
        probe_handle = probe_handle,
        probe = probe_value,
        observation_handle = observation_handle,
        observation = observation,
        manifest = manifest,
        report = validated_report,
    }
end

local function validate_source_identity(sources, expected)
    local manifest = sources.manifest
    local report_value = sources.report
    if manifest.kind ~= "runtime" then
        fail("CGCE-GATEA-MANIFEST", "runtime_manifest.kind", "Gate A requires a runtime manifest")
    end
    if manifest.game_revision ~= expected.game_revision
        or sources.observation.game_revision ~= expected.game_revision
        or report_value.game_revision ~= expected.game_revision then
        fail("CGCE-GATEA-IDENTITY", "game_revision", "artifact revisions do not converge")
    end
    if report_value.world_id ~= expected.world_id then
        fail("CGCE-GATEA-IDENTITY", "world_id", "report world does not match review")
    end
    if report_value.deployment_profile ~= expected.deployment_profile then
        fail("CGCE-GATEA-IDENTITY", "deployment_profile", "report profile does not match review")
    end
    if report_value.mode ~= "audit" or report_value.state ~= "AUDIT_COMPLETE" then
        fail("CGCE-GATEA-REPORT", "operational_report.state", "Gate A requires a complete audit report")
    end
    if report_value.release_eligible ~= false then
        fail("CGCE-GATEA-REPORT", "operational_report.release_eligible", "Gate A report cannot be release eligible")
    end
    if manifest.source_audit_checksum ~= report_value.audit_checksum then
        fail(
            "CGCE-GATEA-MANIFEST",
            "runtime_manifest.source_audit_checksum",
            "runtime manifest does not bind the exact audit"
        )
    end
    if manifest.checksum ~= report_value.binding_manifest_checksum then
        fail(
            "CGCE-GATEA-MANIFEST",
            "runtime_manifest.checksum",
            "operational report does not bind the exact runtime manifest"
        )
    end
end

local function exact_equal(left, right)
    return json_encode(left) == json_encode(right)
end

local function validate_symbols(sources)
    local matches = {}
    for _, record in ipairs(sources.observation.symbols) do
        if record.status == "MATCHED" then
            matches[record.logical_symbol] = record
        end
    end
    for _, symbol in ipairs(binding_symbols_list()) do
        local record = matches[symbol.name]
        if record == nil then
            fail(
                "CGCE-GATEA-OBSERVATION",
                "discovery_observation.symbols." .. symbol.name,
                "logical symbol has no unique match"
            )
        end
        local candidates = sources.probe.candidates[symbol.name]
        local selected = candidates and candidates[record.candidate_index]
        if selected == nil
            or record.invoked ~= false
            or record.signature_coverage ~= "FULL"
            or record.exact_query ~= selected.path
            or record.observed_full_name ~= selected.path
            or record.canonical_signature ~= selected.type_signature then
            fail(
                "CGCE-GATEA-OBSERVATION",
                "discovery_observation.symbols." .. symbol.name,
                "matched observation does not exactly match its probe candidate"
            )
        end
        if not exact_equal(selected, sources.manifest.symbols[symbol.name]) then
            fail(
                "CGCE-GATEA-MANIFEST",
                "runtime_manifest.symbols." .. symbol.name,
                "runtime descriptor does not exactly match reviewed discovery"
            )
        end
    end
    return matches
end

local snapshot_link_fields = {
    projection_contract = "projection_contract_checksum",
    projector_implementation = "projector_implementation_checksum",
    capture_source = "capture_source_checksum",
    durability_codec = "durability_codec_checksum",
    metadata_codec = "metadata_codec_checksum",
    metadata_ordered_input_contract = "metadata_ordered_input_contract_checksum",
}

local function validate_snapshot(review, sources)
    local evidence = sources.observation.before_snapshot_54
    for role, field in pairs(snapshot_link_fields) do
        if evidence[field] ~= review.artifacts[role].checksum then
            fail(
                "CGCE-GATEA-LINK",
                "artifacts." .. role .. ".checksum",
                "snapshot evidence does not bind the exact implementation bytes"
            )
        end
    end

    local exact_matches = 0
    for _, guild in ipairs(sources.report.audit.guilds) do
        if type(guild.snapshot) == "table" and exact_equal(guild.snapshot, evidence.snapshot) then
            exact_matches = exact_matches + 1
        end
    end
    if exact_matches ~= 1 then
        fail(
            "CGCE-GATEA-SNAPSHOT",
            "operational_report.audit.guilds",
            "the reviewed 54-slot snapshot must occur exactly once in the same audit"
        )
    end
end

local function parse_runtime_identity(text, expected, observation)
    local value = parse_json_object(
        text,
        "CGCE-GATEA-IDENTITY",
        "runtime_identity_evidence"
    )
    validate_object(
        value,
        runtime_identity_fields,
        runtime_identity_order,
        "runtime_identity_evidence",
        "CGCE-GATEA-IDENTITY"
    )
    verify_self_checksum(
        value,
        text,
        "CGCE-GATEA-IDENTITY",
        "runtime_identity_evidence"
    )
    local revision = observation.revision_evidence
    if value.evidence_version ~= "1.0"
        or value.kind ~= "runtime_identity_evidence"
        or value.world_id ~= expected.world_id
        or value.game_revision ~= expected.game_revision
        or value.ue4ss_version ~= expected.ue4ss_version
        or value.source_kind ~= revision.source_kind
        or value.exact_source_identity ~= revision.exact_source_identity
        or value.source_signature ~= revision.source_signature then
        fail(
            "CGCE-GATEA-IDENTITY",
            "runtime_identity_evidence",
            "runtime identity bytes do not match the reviewed run and revision source"
        )
    end
    return value
end

local transcript_events = {
    SAFE_STOP = {
        "INVARIANT_FAILURE_DETECTED",
        "CANDIDATE_INVOKED_IN_ISOLATED_HARNESS",
        "NORMAL_SAVE_ATTEMPT_BLOCKED",
        "AUTOSAVE_ATTEMPT_BLOCKED",
        "SAFE_STOP_REQUESTED",
        "PROCESS_EXITED_WITHOUT_SAVE",
    },
    NO_SAVE = {
        "INVARIANT_FAILURE_DETECTED",
        "CANDIDATE_INVOKED_IN_ISOLATED_HARNESS",
        "NORMAL_SAVE_ATTEMPT_BLOCKED",
        "AUTOSAVE_ATTEMPT_BLOCKED",
        "NO_SAVE_GUARD_REMAINS_ACTIVE",
    },
}

local function parse_fatal_transcript(text)
    local value = parse_json_object(
        text,
        "CGCE-GATEA-FATAL",
        "fatal_execution_transcript"
    )
    validate_object(
        value,
        transcript_fields,
        transcript_order,
        "fatal_execution_transcript",
        "CGCE-GATEA-FATAL"
    )
    verify_self_checksum(
        value,
        text,
        "CGCE-GATEA-FATAL",
        "fatal_execution_transcript"
    )
    local expected_events = transcript_events[value.mode]
    if value.transcript_version ~= "1.0"
        or value.kind ~= "fatal_execution_transcript"
        or expected_events == nil
        or dense_array_length(
            value.events,
            "fatal_execution_transcript.events",
            "CGCE-GATEA-FATAL"
        ) ~= #expected_events then
        fail(
            "CGCE-GATEA-FATAL",
            "fatal_execution_transcript",
            "unsupported fatal execution transcript"
        )
    end
    for index, expected_event in ipairs(expected_events) do
        local event = value.events[index]
        validate_object(
            event,
            transcript_event_fields,
            transcript_event_order,
            "fatal_execution_transcript.events[" .. index .. "]",
            "CGCE-GATEA-FATAL"
        )
        if event.sequence ~= index
            or event.event ~= expected_event
            or event.save_write_count ~= 0 then
            fail(
                "CGCE-GATEA-FATAL",
                "fatal_execution_transcript.events[" .. index .. "]",
                "fatal transcript event order or no-save count is invalid"
            )
        end
    end
    return value
end

local function parse_fatal(text)
    local value = parse_json_object(text, "CGCE-GATEA-FATAL", "fatal_behavior_proof")
    validate_object(
        value,
        fatal_fields,
        fatal_order,
        "fatal_behavior_proof",
        "CGCE-GATEA-FATAL"
    )
    verify_self_checksum(value, text, "CGCE-GATEA-FATAL", "fatal_behavior_proof")
    validate_object(
        value.selected_candidate,
        fatal_candidate_fields,
        fatal_candidate_order,
        "fatal_behavior_proof.selected_candidate",
        "CGCE-GATEA-FATAL"
    )
    return value
end

local function validate_fatal(review, sources, actuals, expected, matches)
    local proof = parse_fatal(actuals.fatal_behavior_proof)
    local transcript = parse_fatal_transcript(actuals.fatal_execution_transcript)
    local observed = sources.observation.fatal_safety
    local selected_record = matches.fatal_safe_stop_function
    local selected = sources.probe.candidates.fatal_safe_stop_function[
        selected_record.candidate_index
    ]

    if proof.proof_version ~= "1.0" or proof.kind ~= "fatal_behavior_proof" then
        fail("CGCE-GATEA-FATAL", "fatal_behavior_proof.kind", "unsupported fatal proof contract")
    end
    if proof.world_id ~= expected.world_id
        or proof.game_revision ~= expected.game_revision
        or proof.ue4ss_version ~= expected.ue4ss_version then
        fail("CGCE-GATEA-FATAL", "fatal_behavior_proof", "fatal proof identity does not converge")
    end
    if transcript.world_id ~= expected.world_id
        or transcript.game_revision ~= expected.game_revision
        or transcript.ue4ss_version ~= expected.ue4ss_version
        or transcript.mode ~= proof.mode
        or transcript.harness_implementation_checksum
            ~= review.artifacts.fatal_harness.checksum
        or transcript.candidate_path ~= selected.path
        or transcript.candidate_signature ~= selected.type_signature
        or proof.execution_transcript_checksum
            ~= review.artifacts.fatal_execution_transcript.checksum then
        fail(
            "CGCE-GATEA-FATAL",
            "fatal_execution_transcript",
            "fatal execution transcript does not converge with the reviewed proof"
        )
    end
    if proof.mode ~= "NO_SAVE" and proof.mode ~= "SAFE_STOP" then
        fail("CGCE-GATEA-FATAL", "fatal_behavior_proof.mode", "fatal mode is unsupported")
    end
    if observed.mode ~= proof.mode
        or observed.matched_candidate_index ~= selected_record.candidate_index
        or observed.behavior_proof_artifact_checksum
            ~= review.artifacts.fatal_behavior_proof.checksum
        or observed.harness_implementation_checksum ~= review.artifacts.fatal_harness.checksum
        or proof.harness_implementation_checksum ~= review.artifacts.fatal_harness.checksum then
        fail("CGCE-GATEA-FATAL", "fatal_behavior_proof", "fatal proof links do not converge")
    end
    local candidate = proof.selected_candidate
    if candidate.logical_symbol ~= "fatal_safe_stop_function"
        or candidate.candidate_index ~= selected_record.candidate_index
        or candidate.kind ~= selected.kind
        or candidate.path ~= selected.path
        or candidate.type_signature ~= selected.type_signature then
        fail(
            "CGCE-GATEA-FATAL",
            "fatal_behavior_proof.selected_candidate",
            "fatal proof does not bind the reviewed candidate"
        )
    end
    if proof.invariant_failure_observed ~= true
        or proof.discovery_candidate_invoked ~= false
        or proof.isolated_harness_candidate_invoked ~= true
        or proof.post_failure_save_write_observed ~= false
        or proof.later_normal_save_prevented ~= true
        or proof.later_autosave_prevented ~= true then
        fail(
            "CGCE-GATEA-FATAL",
            "fatal_behavior_proof",
            "fatal behavior does not prove save suppression"
        )
    end
    if proof.mode == "SAFE_STOP" and proof.immediate_stop_without_save ~= true then
        fail(
            "CGCE-GATEA-FATAL",
            "fatal_behavior_proof.immediate_stop_without_save",
            "SAFE_STOP must prove an immediate stop without save"
        )
    end
    if proof.mode == "NO_SAVE" and proof.immediate_stop_without_save ~= false then
        fail(
            "CGCE-GATEA-FATAL",
            "fatal_behavior_proof.immediate_stop_without_save",
            "NO_SAVE must not be represented as a safe-stop result"
        )
    end
    return proof, transcript
end

local function verified_items(review, sources, matches)
    local result = json_array()
    for _, item in ipairs(prd_items) do
        local evidence
        if item.source == "revision" then
            evidence = {
                game_revision = sources.observation.game_revision,
                revision_evidence = sources.observation.revision_evidence,
                source_artifact_checksum = review.artifacts.revision_source.checksum,
            }
        elseif item.source == "snapshot" then
            evidence = {
                snapshot = sources.observation.before_snapshot_54.snapshot,
                projection_contract_checksum = review.artifacts.projection_contract.checksum,
                projector_implementation_checksum = review.artifacts.projector_implementation.checksum,
                capture_source_checksum = review.artifacts.capture_source.checksum,
                durability_codec_checksum = review.artifacts.durability_codec.checksum,
                metadata_codec_checksum = review.artifacts.metadata_codec.checksum,
                metadata_ordered_input_contract_checksum = review.artifacts
                    .metadata_ordered_input_contract.checksum,
            }
        else
            local record = matches[item.symbol]
            evidence = {
                matched_observation = record,
                selected_candidate = sources.probe.candidates[item.symbol][record.candidate_index],
                runtime_descriptor = sources.manifest.symbols[item.symbol],
            }
        end
        local status = "IDENTITY_REVIEWED"
        if item.source == "revision" then
            status = "RUNTIME_AUTHORITY_REVIEWED"
        elseif item.source == "snapshot" then
            status = "RUNTIME_MAPPING_REVIEWED"
        end
        result[#result + 1] = {
            number = item.number,
            name = item.name,
            status = status,
            evidence_checksum = sha256_hex(json_encode({
                number = item.number,
                name = item.name,
                evidence = evidence,
            })),
        }
    end
    return result
end

local function finalize_receipt(unsigned)
    unsigned.checksum = sha256_hex(json_encode(unsigned))
    local encoded = json_encode(unsigned)
    local handle = function() end
    receipt_records[handle] = encoded
    return handle
end

local function require_receipt(handle)
    local encoded = receipt_records[handle]
    if encoded == nil then
        fail("CGCE-GATEA-RECEIPT", "handle", "Gate A acceptance handle is invalid")
    end
    return encoded
end

local function build_acceptance(inputs, expected)
    local trusted_inputs = validate_inputs(inputs)
    local trusted_expected = validate_expected(expected)
    validate_review_path(trusted_inputs.source_relative_path, trusted_expected.game_revision)
    local review_text = read_no_follow(
        trusted_inputs.filesystem_read,
        trusted_inputs.repository_root,
        trusted_inputs.source_relative_path,
        "source_relative_path"
    )
    local review = parse_review(review_text, trusted_inputs, trusted_expected)
    local actuals = load_actual_links(
        review,
        trusted_inputs.filesystem_read,
        trusted_inputs.repository_root
    )
    local sources = parse_sources(actuals, trusted_expected)
    validate_source_identity(sources, trusted_expected)

    if sources.observation.revision_evidence.source_artifact_checksum
        ~= review.artifacts.revision_source.checksum then
        fail(
            "CGCE-GATEA-LINK",
            "artifacts.revision_source.checksum",
            "revision observation does not bind the actual source bytes"
        )
    end
    parse_runtime_identity(actuals.revision_source, trusted_expected, sources.observation)
    local matches = validate_symbols(sources)
    validate_snapshot(review, sources)
    local proof = validate_fatal(review, sources, actuals, trusted_expected, matches)
    local items = verified_items(review, sources, matches)

    return {
        acceptance_version = ACCEPTANCE_VERSION,
        kind = "gate_a_acceptance",
        scope = SCOPE,
        status = "ACCEPTED_READ_ONLY_EVIDENCE",
        mutation_capability = false,
        release_eligible = false,
        behavior_authorized = false,
        game_revision = trusted_expected.game_revision,
        world_id = trusted_expected.world_id,
        deployment_profile = trusted_expected.deployment_profile,
        ue4ss_version = trusted_expected.ue4ss_version,
        reviewer = trusted_expected.reviewer,
        reviewed_at = trusted_expected.reviewed_at,
        review_request_checksum = review.checksum,
        reviewer_authorization_checksum = trusted_expected.reviewer_authorization_checksum,
        probe_request_checksum = discovery_probe_checksum(sources.probe_handle),
        discovery_observation_checksum = discovery_evidence_checksum(sources.observation_handle),
        operational_report_checksum = sources.report.checksum,
        audit_checksum = sources.report.audit_checksum,
        binding_manifest_checksum = sources.manifest.checksum,
        revision_source_checksum = review.artifacts.revision_source.checksum,
        projection_contract_checksum = review.artifacts.projection_contract.checksum,
        projector_implementation_checksum = review.artifacts.projector_implementation.checksum,
        capture_source_checksum = review.artifacts.capture_source.checksum,
        durability_codec_checksum = review.artifacts.durability_codec.checksum,
        metadata_codec_checksum = review.artifacts.metadata_codec.checksum,
        metadata_ordered_input_contract_checksum = review.artifacts
            .metadata_ordered_input_contract.checksum,
        fatal_mode = proof.mode,
        fatal_behavior_proof_checksum = review.artifacts.fatal_behavior_proof.checksum,
        fatal_harness_checksum = review.artifacts.fatal_harness.checksum,
        fatal_execution_transcript_checksum = review.artifacts
            .fatal_execution_transcript.checksum,
        verified_items = items,
    }
end

local function validate_receipt_shape(value, text)
    validate_object(value, receipt_fields, receipt_order, "receipt", "CGCE-GATEA-RECEIPT")
    verify_self_checksum(value, text, "CGCE-GATEA-RECEIPT", "receipt")
    if value.acceptance_version ~= ACCEPTANCE_VERSION
        or value.kind ~= "gate_a_acceptance"
        or value.scope ~= SCOPE
        or value.status ~= "ACCEPTED_READ_ONLY_EVIDENCE"
        or value.mutation_capability ~= false
        or value.release_eligible ~= false
        or value.behavior_authorized ~= false then
        fail("CGCE-GATEA-RECEIPT", "receipt", "unsupported Gate A acceptance receipt")
    end
    if dense_array_length(value.verified_items, "receipt.verified_items", "CGCE-GATEA-RECEIPT")
        ~= #prd_items then
        fail("CGCE-GATEA-RECEIPT", "receipt.verified_items", "receipt must bind all 16 items")
    end
    for index, item in ipairs(value.verified_items) do
        validate_object(
            item,
            verified_item_fields,
            verified_item_order,
            "receipt.verified_items[" .. index .. "]",
            "CGCE-GATEA-RECEIPT"
        )
        if item.number ~= index
            or item.name ~= prd_items[index].name
            or item.status ~= (prd_items[index].source == "revision"
                and "RUNTIME_AUTHORITY_REVIEWED"
                or (prd_items[index].source == "snapshot"
                    and "RUNTIME_MAPPING_REVIEWED"
                    or "IDENTITY_REVIEWED"))
            or not is_sha256(item.evidence_checksum) then
            fail("CGCE-GATEA-RECEIPT", "receipt.verified_items[" .. index .. "]", "invalid verified item")
        end
    end
end

function gate_a_evidence.accept(inputs, expected)
    return finalize_receipt(build_acceptance(inputs, expected))
end

function gate_a_evidence.verify(receipt_text, inputs, expected)
    local supplied = parse_json_object(receipt_text, "CGCE-GATEA-RECEIPT", "receipt")
    validate_receipt_shape(supplied, receipt_text)
    local recomputed = gate_a_evidence.accept(inputs, expected)
    if receipt_text ~= require_receipt(recomputed) then
        fail(
            "CGCE-GATEA-RECEIPT",
            "receipt",
            "acceptance receipt does not match the actual reviewed artifacts"
        )
    end
    return recomputed
end

function gate_a_evidence.to_table(handle)
    return json_decode(require_receipt(handle))
end

function gate_a_evidence.canonical_json(handle)
    return require_receipt(handle)
end

function gate_a_evidence.checksum(handle)
    return json_decode(require_receipt(handle)).checksum
end

function gate_a_evidence.mutation_capability(handle)
    require_receipt(handle)
    return false
end

function gate_a_evidence.release_eligible(handle)
    require_receipt(handle)
    return false
end

function gate_a_evidence.behavior_authorized(handle)
    require_receipt(handle)
    return false
end

return gate_a_evidence
