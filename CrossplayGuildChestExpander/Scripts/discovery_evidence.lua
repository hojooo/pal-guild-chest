local binding_symbols = require("CrossplayGuildChestExpander.Scripts.binding_symbols")
local discovery_probe = require("CrossplayGuildChestExpander.Scripts.discovery_probe")
local fingerprint = require("CrossplayGuildChestExpander.Scripts.fingerprint")
local json = require("CrossplayGuildChestExpander.Scripts.json")
local sha256 = require("CrossplayGuildChestExpander.Scripts.sha256")

local discovery_evidence = {}

local OBSERVATION_VERSION = "1.0"

local binding_symbols_list = binding_symbols.list
local fingerprint_compute = fingerprint.compute
local json_array = json.array
local json_decode = json.decode
local json_encode = json.encode
local json_null = json.null
local probe_checksum = discovery_probe.checksum
local probe_to_table = discovery_probe.to_table
local sha256_hex = sha256.hex

local symbol_catalog = binding_symbols_list()
local symbol_kinds = {}
for _, symbol in ipairs(symbol_catalog) do
    symbol_kinds[symbol.name] = symbol.kind
end

local statuses = {
    MATCHED = true,
    NOT_LOADED = true,
    MISMATCH = true,
    PARTIAL = true,
    ERROR = true,
}

local signature_coverages = {
    FULL = true,
    PARTIAL = true,
    NONE = true,
}

local revision_source_kinds = {
    runtime_property = true,
    runtime_function = true,
    server_log = true,
}

local top_fields = {
    observation_version = true,
    kind = true,
    authoritative = true,
    mutation_capability = true,
    game_revision = true,
    probe_request_checksum = true,
    revision_evidence = true,
    symbols = true,
    before_snapshot_54 = true,
    fatal_safety = true,
    checksum = true,
}

local top_field_order = {
    "observation_version",
    "kind",
    "authoritative",
    "mutation_capability",
    "game_revision",
    "probe_request_checksum",
    "revision_evidence",
    "symbols",
    "before_snapshot_54",
    "fatal_safety",
    "checksum",
}

local revision_fields = {
    status = true,
    observed_revision = true,
    source_kind = true,
    exact_source_identity = true,
    source_signature = true,
    signature_coverage = true,
    provenance_api = true,
    source_artifact_checksum = true,
    invoked = true,
    authority_verified = true,
}

local revision_field_order = {
    "status",
    "observed_revision",
    "source_kind",
    "exact_source_identity",
    "source_signature",
    "signature_coverage",
    "provenance_api",
    "source_artifact_checksum",
    "invoked",
    "authority_verified",
}

local record_fields = {
    logical_symbol = true,
    status = true,
    kind = true,
    candidate_index = true,
    exact_query = true,
    observed_full_name = true,
    canonical_signature = true,
    signature_coverage = true,
    provenance_api = true,
    invoked = true,
}

local record_field_order = {
    "logical_symbol",
    "status",
    "kind",
    "candidate_index",
    "exact_query",
    "observed_full_name",
    "canonical_signature",
    "signature_coverage",
    "provenance_api",
    "invoked",
}

local snapshot_evidence_fields = {
    status = true,
    provenance_api = true,
    invoked = true,
    projection_contract_checksum = true,
    projector_implementation_checksum = true,
    capture_source_checksum = true,
    durability_codec_checksum = true,
    metadata_codec_checksum = true,
    metadata_ordered_input_contract_checksum = true,
    snapshot = true,
    projection_verified = true,
}

local snapshot_evidence_field_order = {
    "status",
    "provenance_api",
    "invoked",
    "projection_contract_checksum",
    "projector_implementation_checksum",
    "capture_source_checksum",
    "durability_codec_checksum",
    "metadata_codec_checksum",
    "metadata_ordered_input_contract_checksum",
    "snapshot",
    "projection_verified",
}

local snapshot_checksum_fields = {
    "projection_contract_checksum",
    "projector_implementation_checksum",
    "capture_source_checksum",
    "durability_codec_checksum",
    "metadata_codec_checksum",
    "metadata_ordered_input_contract_checksum",
}

local snapshot_fields = {
    version = true,
    container_id = true,
    owner_guild_id = true,
    slot_count = true,
    occupied_slot_count = true,
    total_item_quantity = true,
    slots = true,
    item_fingerprint = true,
}

local snapshot_field_order = {
    "version",
    "container_id",
    "owner_guild_id",
    "slot_count",
    "occupied_slot_count",
    "total_item_quantity",
    "slots",
    "item_fingerprint",
}

local empty_slot_fields = {
    index = true,
    empty = true,
}

local occupied_slot_fields = {
    index = true,
    empty = true,
    static_id = true,
    dynamic_guid = true,
    quantity = true,
    durability = true,
    instance_metadata_hash = true,
}

local fatal_fields = {
    matched_candidate_index = true,
    mode = true,
    behavior_proof_artifact_checksum = true,
    harness_implementation_checksum = true,
    behavior_verified = true,
}

local fatal_field_order = {
    "matched_candidate_index",
    "mode",
    "behavior_proof_artifact_checksum",
    "harness_implementation_checksum",
    "behavior_verified",
}

local parsed_observations = setmetatable({}, { __mode = "k" })

local function problem(code, field, detail)
    return { code = code, field = field, detail = detail }
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

local function validate_object_keys(value, allowed, ordered, prefix, code)
    if type(value) ~= "table"
        or value == json_null
        or getmetatable(value) ~= nil
        or json_encode(value):sub(1, 1) ~= "{" then
        fail(code, prefix, prefix .. " must be a plain object")
    end
    local unknown = sorted_unknown_key(value, allowed)
    if unknown == false then
        fail(code, prefix, prefix .. " keys must be strings")
    end
    if unknown ~= nil then
        fail(code, prefix .. "." .. unknown, "unknown " .. prefix .. " key")
    end
    for _, field in ipairs(ordered) do
        if rawget(value, field) == nil then
            fail(code, prefix .. "." .. field, "required " .. prefix .. " key is missing")
        end
    end
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

local function is_json_string(value, allow_empty)
    if type(value) ~= "string" or (not allow_empty and #value == 0) then
        return false
    end
    local ok, encoded = pcall(json_encode, value)
    return ok and type(encoded) == "string" and encoded:sub(1, 1) == '"'
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

local function is_exact_source_identity(value)
    return is_control_free(value)
        and #value > 0
        and value:match("^%s") == nil
        and value:match("%s$") == nil
        and value:find("*", 1, true) == nil
        and value:find("?", 1, true) == nil
        and value:find("[", 1, true) == nil
        and value:find("]", 1, true) == nil
        and value:find("...", 1, true) == nil
        and value:match("^[A-Za-z0-9_./:\\-]+$") ~= nil
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

local function is_exact_provenance(value)
    return is_control_free(value)
        and value:match("^[A-Za-z_][A-Za-z0-9_.:]*$") ~= nil
        and value:find("...", 1, true) == nil
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

local function is_nonnegative_integer(value)
    return type(value) == "number"
        and math.type(value) == "integer"
        and value >= 0
end

local function dense_array_length(value, field, allow_empty)
    if type(value) ~= "table" or value == json_null or getmetatable(value) ~= nil then
        fail("CGCE-DISC-ARRAY", field, field .. " must be a dense array")
    end
    if next(value) == nil then
        if json_encode(value) ~= "[]" or not allow_empty then
            fail("CGCE-DISC-ARRAY", field, field .. " must be a dense array")
        end
        return 0
    end
    local count = 0
    local largest = 0
    for key in next, value do
        if type(key) ~= "number" or math.type(key) ~= "integer" or key < 1 then
            fail("CGCE-DISC-ARRAY", field, field .. " must be a dense array")
        end
        count = count + 1
        if key > largest then
            largest = key
        end
    end
    if largest ~= count then
        fail("CGCE-DISC-ARRAY", field, field .. " must be a dense array")
    end
    return count
end

local function parse_json(text)
    local ok, value = pcall(json_decode, text)
    if not ok then
        fail("CGCE-DISC-JSON", nil, "discovery observation is not valid JSON")
    end
    if type(value) ~= "table"
        or value == json_null
        or json_encode(value):sub(1, 1) ~= "{" then
        fail("CGCE-DISC-TYPE", nil, "discovery observation root must be an object")
    end
    return value
end

local function validate_top_level(value, expected_revision, expected_request_checksum)
    local unknown = sorted_unknown_key(value, top_fields)
    if unknown == false then
        fail("CGCE-DISC-UNKNOWN-KEY", nil, "discovery observation keys must be strings")
    end
    if unknown ~= nil then
        fail("CGCE-DISC-UNKNOWN-KEY", unknown, "unknown discovery observation key")
    end
    for _, field in ipairs(top_field_order) do
        if rawget(value, field) == nil then
            fail("CGCE-DISC-MISSING-KEY", field, "required discovery observation key is missing")
        end
    end
    if value.observation_version ~= OBSERVATION_VERSION then
        fail("CGCE-DISC-VERSION", "observation_version", "unsupported discovery observation version")
    end
    if value.kind ~= "discovery_observation" then
        fail("CGCE-DISC-KIND", "kind", "kind must be discovery_observation")
    end
    if value.authoritative ~= false then
        fail("CGCE-DISC-AUTHORITY", "authoritative", "discovery observations are non-authoritative")
    end
    if value.mutation_capability ~= false then
        fail("CGCE-DISC-AUTHORITY", "mutation_capability", "discovery observations cannot mutate")
    end
    if not is_positive_integer(expected_revision) then
        fail("CGCE-DISC-REVISION", "expected_revision", "expected game revision must be a positive integer")
    end
    if value.game_revision ~= expected_revision then
        fail("CGCE-DISC-REVISION", "game_revision", "observation game revision does not match")
    end
    if not is_sha256(value.probe_request_checksum)
        or value.probe_request_checksum ~= expected_request_checksum then
        fail("CGCE-DISC-REQUEST", "probe_request_checksum", "probe request checksum does not match")
    end
end

local function verify_checksum(value)
    if not is_sha256(value.checksum) then
        fail("CGCE-DISC-CHECKSUM", "checksum", "checksum must be lowercase SHA-256")
    end
    local unsigned = {}
    for key, item in next, value do
        if key ~= "checksum" then
            unsigned[key] = item
        end
    end
    if sha256_hex(json_encode(unsigned)) ~= value.checksum then
        fail("CGCE-DISC-CHECKSUM", "checksum", "discovery observation self-checksum mismatch")
    end
end

local function validate_revision_evidence(value, expected_revision)
    local prefix = "revision_evidence"
    validate_object_keys(
        value,
        revision_fields,
        revision_field_order,
        prefix,
        "CGCE-DISC-REVISION-EVIDENCE"
    )
    if not statuses[value.status] then
        fail("CGCE-DISC-REVISION-EVIDENCE", prefix .. ".status", "revision status is unsupported")
    end
    if not revision_source_kinds[value.source_kind] then
        fail("CGCE-DISC-REVISION-EVIDENCE", prefix .. ".source_kind", "revision source kind is unsupported")
    end
    local exact_identity = value.source_kind == "server_log"
        and is_exact_source_identity(value.exact_source_identity)
        or is_exact_path(value.exact_source_identity)
    if not exact_identity then
        fail(
            "CGCE-DISC-REVISION-EVIDENCE",
            prefix .. ".exact_source_identity",
            "revision source identity must be exact and non-fuzzy"
        )
    end
    if not is_exact_signature(value.source_signature) then
        fail(
            "CGCE-DISC-REVISION-EVIDENCE",
            prefix .. ".source_signature",
            "revision source signature must be exact"
        )
    end
    if not signature_coverages[value.signature_coverage] then
        fail(
            "CGCE-DISC-REVISION-EVIDENCE",
            prefix .. ".signature_coverage",
            "revision signature coverage is unsupported"
        )
    end
    if not is_exact_provenance(value.provenance_api) then
        fail(
            "CGCE-DISC-REVISION-EVIDENCE",
            prefix .. ".provenance_api",
            "revision provenance API must be exact"
        )
    end
    if not is_sha256(value.source_artifact_checksum) then
        fail(
            "CGCE-DISC-REVISION-EVIDENCE",
            prefix .. ".source_artifact_checksum",
            "revision source artifact link must be lowercase SHA-256"
        )
    end
    if value.invoked ~= false then
        fail("CGCE-DISC-INVOKED", prefix .. ".invoked", "revision source must not be invoked by discovery")
    end
    if value.authority_verified ~= false then
        fail(
            "CGCE-DISC-REVISION-EVIDENCE",
            prefix .. ".authority_verified",
            "discovery observation cannot claim revision authority verification"
        )
    end

    if value.status == "MATCHED" then
        if value.observed_revision ~= expected_revision then
            fail(
                "CGCE-DISC-REVISION-EVIDENCE",
                prefix .. ".observed_revision",
                "matched revision evidence must equal the expected revision"
            )
        end
        if value.signature_coverage == "NONE" then
            fail(
                "CGCE-DISC-REVISION-EVIDENCE",
                prefix .. ".signature_coverage",
                "matched revision evidence cannot have NONE coverage"
            )
        end
    elseif value.status == "MISMATCH" then
        if not is_positive_integer(value.observed_revision)
            or value.observed_revision == expected_revision then
            fail(
                "CGCE-DISC-REVISION-EVIDENCE",
                prefix .. ".observed_revision",
                "mismatched revision evidence must record a different positive revision"
            )
        end
        if value.signature_coverage == "NONE" then
            fail(
                "CGCE-DISC-REVISION-EVIDENCE",
                prefix .. ".signature_coverage",
                "mismatched revision evidence cannot have NONE coverage"
            )
        end
    elseif value.status == "PARTIAL" then
        if value.observed_revision ~= json_null
            and not is_positive_integer(value.observed_revision) then
            fail(
                "CGCE-DISC-REVISION-EVIDENCE",
                prefix .. ".observed_revision",
                "partial revision must be a positive integer or null"
            )
        end
        if value.signature_coverage ~= "PARTIAL" then
            fail(
                "CGCE-DISC-REVISION-EVIDENCE",
                prefix .. ".signature_coverage",
                "PARTIAL revision status requires PARTIAL coverage"
            )
        end
    else
        if value.observed_revision ~= json_null then
            fail(
                "CGCE-DISC-REVISION-EVIDENCE",
                prefix .. ".observed_revision",
                "unobserved revision must be null"
            )
        end
        if value.signature_coverage ~= "NONE" then
            fail(
                "CGCE-DISC-REVISION-EVIDENCE",
                prefix .. ".signature_coverage",
                "unobserved revision coverage must be NONE"
            )
        end
    end
end

local function validate_optional_path(value, field)
    if value ~= json_null and not is_exact_path(value) then
        fail("CGCE-DISC-RECORD", field, "observed full name must be exact or null")
    end
end

local function validate_optional_signature(value, field)
    if value ~= json_null and not is_exact_signature(value) then
        fail("CGCE-DISC-RECORD", field, "canonical signature must be exact or null")
    end
end

local function validate_record(record, prefix, request_candidates)
    validate_object_keys(record, record_fields, record_field_order, prefix, "CGCE-DISC-RECORD")
    if type(record.logical_symbol) ~= "string"
        or symbol_kinds[record.logical_symbol] == nil then
        fail("CGCE-DISC-RECORD", prefix .. ".logical_symbol", "logical symbol is not in the shared catalog")
    end
    if not statuses[record.status] then
        fail("CGCE-DISC-RECORD", prefix .. ".status", "discovery status is unsupported")
    end
    if not signature_coverages[record.signature_coverage] then
        fail("CGCE-DISC-RECORD", prefix .. ".signature_coverage", "signature coverage is unsupported")
    end
    if record.invoked ~= false then
        fail("CGCE-DISC-INVOKED", prefix .. ".invoked", "discovery candidates must never be invoked")
    end
    if not is_exact_provenance(record.provenance_api) then
        fail("CGCE-DISC-RECORD", prefix .. ".provenance_api", "provenance API must be exact")
    end
    if not is_positive_integer(record.candidate_index) then
        fail("CGCE-DISC-CANDIDATE", prefix .. ".candidate_index", "candidate index must be positive")
    end

    local candidates = request_candidates[record.logical_symbol]
    local candidate = type(candidates) == "table" and candidates[record.candidate_index] or nil
    if type(candidate) ~= "table" then
        fail("CGCE-DISC-CANDIDATE", prefix .. ".candidate_index", "candidate is absent from bound probe request")
    end
    if record.kind ~= candidate.kind or record.kind ~= symbol_kinds[record.logical_symbol] then
        fail("CGCE-DISC-CANDIDATE", prefix .. ".kind", "record kind does not match bound candidate")
    end
    if not is_exact_path(record.exact_query) then
        fail("CGCE-DISC-RECORD", prefix .. ".exact_query", "query must be an exact absolute identity")
    end
    if record.exact_query ~= candidate.path then
        fail("CGCE-DISC-CANDIDATE", prefix .. ".exact_query", "query does not match bound candidate")
    end
    validate_optional_path(record.observed_full_name, prefix .. ".observed_full_name")
    validate_optional_signature(record.canonical_signature, prefix .. ".canonical_signature")

    if record.status == "MATCHED" then
        if record.observed_full_name ~= candidate.path then
            fail("CGCE-DISC-RECORD", prefix .. ".observed_full_name", "matched identity must equal exact query")
        end
        if record.canonical_signature ~= candidate.type_signature then
            fail("CGCE-DISC-RECORD", prefix .. ".canonical_signature", "matched signature must equal candidate")
        end
        if record.signature_coverage == "NONE" then
            fail("CGCE-DISC-RECORD", prefix .. ".signature_coverage", "matched coverage cannot be NONE")
        end
    elseif record.status == "MISMATCH" then
        if record.observed_full_name == json_null or record.canonical_signature == json_null then
            fail("CGCE-DISC-RECORD", prefix, "mismatch must record observed identity and signature")
        end
        if record.observed_full_name == candidate.path
            and record.canonical_signature == candidate.type_signature then
            fail("CGCE-DISC-RECORD", prefix .. ".status", "exact match cannot be marked MISMATCH")
        end
        if record.signature_coverage == "NONE" then
            fail("CGCE-DISC-RECORD", prefix .. ".signature_coverage", "mismatch coverage cannot be NONE")
        end
    elseif record.status == "PARTIAL" then
        if record.signature_coverage ~= "PARTIAL" then
            fail("CGCE-DISC-RECORD", prefix .. ".signature_coverage", "PARTIAL status requires PARTIAL coverage")
        end
    else
        if record.observed_full_name ~= json_null then
            fail("CGCE-DISC-RECORD", prefix .. ".observed_full_name", "unobserved identity must be null")
        end
        if record.canonical_signature ~= json_null then
            fail("CGCE-DISC-RECORD", prefix .. ".canonical_signature", "unobserved signature must be null")
        end
        if record.signature_coverage ~= "NONE" then
            fail("CGCE-DISC-RECORD", prefix .. ".signature_coverage", "unobserved coverage must be NONE")
        end
    end
    return record.logical_symbol, record.candidate_index
end

local function validate_snapshot_slot(slot, index, occupied)
    local prefix = "before_snapshot_54.snapshot.slots[" .. index .. "]"
    if type(slot) ~= "table" or slot == json_null or getmetatable(slot) ~= nil then
        fail("CGCE-DISC-SNAPSHOT", prefix, "snapshot slot must be a plain object")
    end
    local empty = rawget(slot, "empty")
    local allowed = empty == true and empty_slot_fields or occupied_slot_fields
    local required = empty == true
        and { "index", "empty" }
        or {
            "index",
            "empty",
            "static_id",
            "dynamic_guid",
            "quantity",
            "durability",
            "instance_metadata_hash",
        }
    validate_object_keys(slot, allowed, required, prefix, "CGCE-DISC-SNAPSHOT")
    if slot.index ~= index then
        fail("CGCE-DISC-SNAPSHOT", prefix .. ".index", "snapshot slot index must match engine order")
    end
    if slot.empty ~= true and slot.empty ~= false then
        fail("CGCE-DISC-SNAPSHOT", prefix .. ".empty", "snapshot slot occupancy must be boolean")
    end
    if slot.empty then
        return 0, 0
    end
    if not is_json_string(slot.static_id, false) then
        fail("CGCE-DISC-SNAPSHOT", prefix .. ".static_id", "static item ID must be non-empty")
    end
    if not is_json_string(slot.dynamic_guid, false) then
        fail("CGCE-DISC-SNAPSHOT", prefix .. ".dynamic_guid", "dynamic GUID must be non-empty")
    end
    if not is_positive_integer(slot.quantity) then
        fail("CGCE-DISC-SNAPSHOT", prefix .. ".quantity", "item quantity must be positive")
    end
    if not is_json_string(slot.durability, false) then
        fail("CGCE-DISC-SNAPSHOT", prefix .. ".durability", "durability must be canonical and non-empty")
    end
    if not is_sha256(slot.instance_metadata_hash) then
        fail("CGCE-DISC-SNAPSHOT", prefix .. ".instance_metadata_hash", "metadata hash must be lowercase SHA-256")
    end
    occupied[#occupied + 1] = {
        index = index,
        empty = false,
        static_id = slot.static_id,
        dynamic_guid = slot.dynamic_guid,
        quantity = slot.quantity,
        durability = slot.durability,
        instance_metadata_hash = slot.instance_metadata_hash,
    }
    return 1, slot.quantity
end

local function validate_snapshot(snapshot)
    local prefix = "before_snapshot_54.snapshot"
    validate_object_keys(snapshot, snapshot_fields, snapshot_field_order, prefix, "CGCE-DISC-SNAPSHOT")
    if snapshot.version ~= "1.0" then
        fail("CGCE-DISC-SNAPSHOT", prefix .. ".version", "snapshot version must be 1.0")
    end
    if not is_json_string(snapshot.container_id, false) then
        fail("CGCE-DISC-SNAPSHOT", prefix .. ".container_id", "container ID must be non-empty")
    end
    if not is_json_string(snapshot.owner_guild_id, false) then
        fail("CGCE-DISC-SNAPSHOT", prefix .. ".owner_guild_id", "owner guild ID must be non-empty")
    end
    if snapshot.slot_count ~= 54 then
        fail("CGCE-DISC-SNAPSHOT", prefix .. ".slot_count", "before snapshot must contain exactly 54 slots")
    end
    if not is_nonnegative_integer(snapshot.occupied_slot_count) then
        fail("CGCE-DISC-SNAPSHOT", prefix .. ".occupied_slot_count", "occupied count must be non-negative")
    end
    if not is_nonnegative_integer(snapshot.total_item_quantity) then
        fail("CGCE-DISC-SNAPSHOT", prefix .. ".total_item_quantity", "total quantity must be non-negative")
    end
    if not is_sha256(snapshot.item_fingerprint) then
        fail("CGCE-DISC-SNAPSHOT", prefix .. ".item_fingerprint", "item fingerprint must be lowercase SHA-256")
    end
    if dense_array_length(snapshot.slots, prefix .. ".slots", false) ~= 54 then
        fail("CGCE-DISC-SNAPSHOT", prefix .. ".slots", "before snapshot slots must be a dense 54-slot array")
    end

    local occupied = json_array()
    local occupied_count = 0
    local total_quantity = 0
    for index = 1, 54 do
        local count, quantity = validate_snapshot_slot(snapshot.slots[index], index, occupied)
        occupied_count = occupied_count + count
        if quantity > math.maxinteger - total_quantity then
            fail("CGCE-DISC-SNAPSHOT", prefix .. ".total_item_quantity", "total quantity exceeds Lua integer range")
        end
        total_quantity = total_quantity + quantity
    end
    if occupied_count == 0 or occupied_count == 54 then
        fail(
            "CGCE-DISC-SNAPSHOT",
            prefix .. ".slots",
            "representative snapshot requires at least one occupied and one empty slot"
        )
    end
    if snapshot.occupied_slot_count ~= occupied_count then
        fail("CGCE-DISC-SNAPSHOT", prefix .. ".occupied_slot_count", "occupied count does not match slots")
    end
    if snapshot.total_item_quantity ~= total_quantity then
        fail("CGCE-DISC-SNAPSHOT", prefix .. ".total_item_quantity", "total quantity does not match slots")
    end
    local fingerprint_ok, expected_fingerprint = pcall(fingerprint_compute, occupied)
    if not fingerprint_ok or not is_sha256(expected_fingerprint) then
        fail("CGCE-DISC-SNAPSHOT", prefix .. ".item_fingerprint", "canonical fingerprint computation failed")
    end
    if snapshot.item_fingerprint ~= expected_fingerprint then
        fail("CGCE-DISC-SNAPSHOT", prefix .. ".item_fingerprint", "fingerprint does not match canonical slots")
    end
end

local function validate_snapshot_evidence(value)
    local prefix = "before_snapshot_54"
    validate_object_keys(
        value,
        snapshot_evidence_fields,
        snapshot_evidence_field_order,
        prefix,
        "CGCE-DISC-SNAPSHOT"
    )
    if not statuses[value.status] then
        fail("CGCE-DISC-SNAPSHOT", prefix .. ".status", "snapshot status is unsupported")
    end
    if not is_exact_provenance(value.provenance_api) then
        fail("CGCE-DISC-SNAPSHOT", prefix .. ".provenance_api", "snapshot provenance API must be exact")
    end
    if value.invoked ~= false then
        fail("CGCE-DISC-INVOKED", prefix .. ".invoked", "snapshot discovery must not invoke candidates")
    end
    if value.projection_verified ~= false then
        fail(
            "CGCE-DISC-SNAPSHOT",
            prefix .. ".projection_verified",
            "discovery observation cannot claim snapshot projection verification"
        )
    end
    for _, field in ipairs(snapshot_checksum_fields) do
        local link = value[field]
        local valid_link = is_sha256(link)
            or (value.status ~= "MATCHED" and link == json_null)
        if not valid_link then
            fail(
                "CGCE-DISC-SNAPSHOT",
                prefix .. "." .. field,
                "snapshot artifact link must be lowercase SHA-256 or unavailable null"
            )
        end
    end
    if value.status == "MATCHED" then
        validate_snapshot(value.snapshot)
    elseif value.snapshot ~= json_null then
        fail("CGCE-DISC-SNAPSHOT", prefix .. ".snapshot", "unmatched snapshot evidence must be null")
    end
end

local function validate_fatal_safety(value)
    local prefix = "fatal_safety"
    validate_object_keys(value, fatal_fields, fatal_field_order, prefix, "CGCE-DISC-FATAL")
    if value.matched_candidate_index ~= json_null
        and not is_positive_integer(value.matched_candidate_index) then
        fail(
            "CGCE-DISC-FATAL",
            prefix .. ".matched_candidate_index",
            "fatal candidate index must be positive or unavailable null"
        )
    end
    if value.mode ~= json_null and value.mode ~= "NO_SAVE" and value.mode ~= "SAFE_STOP" then
        fail("CGCE-DISC-FATAL", prefix .. ".mode", "fatal mode must be NO_SAVE, SAFE_STOP, or unavailable null")
    end
    if value.behavior_proof_artifact_checksum ~= json_null
        and not is_sha256(value.behavior_proof_artifact_checksum) then
        fail(
            "CGCE-DISC-FATAL",
            prefix .. ".behavior_proof_artifact_checksum",
            "behavior proof link must be lowercase SHA-256 or unavailable null"
        )
    end
    if value.harness_implementation_checksum ~= json_null
        and not is_sha256(value.harness_implementation_checksum) then
        fail(
            "CGCE-DISC-FATAL",
            prefix .. ".harness_implementation_checksum",
            "harness implementation link must be lowercase SHA-256 or unavailable null"
        )
    end
    if value.behavior_verified ~= false then
        fail(
            "CGCE-DISC-FATAL",
            prefix .. ".behavior_verified",
            "discovery observation cannot claim fatal behavior verification"
        )
    end
end

local function blocker(code, field, detail)
    return { code = code, field = field, detail = detail }
end

local function build_manifest_readiness(
    request_candidates,
    records,
    revision_evidence,
    snapshot_evidence,
    fatal_safety
)
    local blockers = json_array()
    local matched_indexes = {}

    for _, symbol in ipairs(symbol_catalog) do
        local candidates = request_candidates[symbol.name]
        if type(candidates) ~= "table" then
            blockers[#blockers + 1] = blocker(
                "CGCE-DISC-MISSING-CANDIDATE",
                "symbols." .. symbol.name,
                "required logical symbol has no probe candidates"
            )
        else
            local match_count = 0
            local matched_index
            local symbol_records = records[symbol.name] or {}
            for candidate_index = 1, #candidates do
                local record = symbol_records[candidate_index]
                local prefix = "symbols." .. symbol.name .. "[" .. candidate_index .. "]"
                if record == nil then
                    blockers[#blockers + 1] = blocker(
                        "CGCE-DISC-MISSING-OBSERVATION",
                        prefix,
                        "probe candidate observation is missing"
                    )
                else
                    if record.status == "MATCHED" then
                        match_count = match_count + 1
                        matched_index = candidate_index
                    elseif record.status ~= "MISMATCH" then
                        blockers[#blockers + 1] = blocker(
                            "CGCE-DISC-OBSERVATION-STATUS",
                            prefix .. ".status",
                            "probe candidate status is " .. record.status
                        )
                    end
                    if (record.status == "MATCHED" or record.status == "MISMATCH")
                        and record.signature_coverage ~= "FULL" then
                        blockers[#blockers + 1] = blocker(
                            "CGCE-DISC-SIGNATURE-COVERAGE",
                            prefix .. ".signature_coverage",
                            "probe candidate signature coverage is " .. record.signature_coverage
                        )
                    end
                end
            end
            if match_count ~= 1 then
                blockers[#blockers + 1] = blocker(
                    "CGCE-DISC-MATCH-COUNT",
                    "symbols." .. symbol.name,
                    "logical symbol has " .. match_count
                        .. " MATCHED candidates; exactly one is required"
                )
            else
                matched_indexes[symbol.name] = matched_index
            end
        end
    end

    if revision_evidence.status ~= "MATCHED" then
        blockers[#blockers + 1] = blocker(
            "CGCE-DISC-REVISION-STATUS",
            "revision_evidence.status",
            "revision evidence status is " .. revision_evidence.status
        )
    elseif revision_evidence.signature_coverage ~= "FULL" then
        blockers[#blockers + 1] = blocker(
            "CGCE-DISC-SIGNATURE-COVERAGE",
            "revision_evidence.signature_coverage",
            "revision evidence signature coverage is " .. revision_evidence.signature_coverage
        )
    end

    if snapshot_evidence.status ~= "MATCHED" then
        blockers[#blockers + 1] = blocker(
            "CGCE-DISC-SNAPSHOT-STATUS",
            "before_snapshot_54.status",
            "canonical 54-slot before snapshot status is " .. snapshot_evidence.status
        )
    end

    local fatal_index = matched_indexes.fatal_safe_stop_function
    if fatal_index ~= nil then
        if fatal_safety.matched_candidate_index ~= fatal_index then
            blockers[#blockers + 1] = blocker(
                "CGCE-DISC-FATAL-CANDIDATE",
                "fatal_safety.matched_candidate_index",
                "fatal metadata does not reference the unique MATCHED candidate"
            )
        end
        if fatal_safety.mode == json_null then
            blockers[#blockers + 1] = blocker(
                "CGCE-DISC-FATAL-METADATA",
                "fatal_safety.mode",
                "fatal safety mode link is missing"
            )
        end
        if fatal_safety.behavior_proof_artifact_checksum == json_null then
            blockers[#blockers + 1] = blocker(
                "CGCE-DISC-FATAL-METADATA",
                "fatal_safety.behavior_proof_artifact_checksum",
                "fatal behavior-proof artifact link is missing"
            )
        end
        if fatal_safety.harness_implementation_checksum == json_null then
            blockers[#blockers + 1] = blocker(
                "CGCE-DISC-FATAL-METADATA",
                "fatal_safety.harness_implementation_checksum",
                "fatal harness implementation link is missing"
            )
        end
    end

    return {
        ready = #blockers == 0,
        blockers = blockers,
    }
end

local function require_observation(handle)
    local record = parsed_observations[handle]
    if record == nil then
        fail("CGCE-DISC-HANDLE", "handle", "discovery observation handle is invalid")
    end
    return record
end

function discovery_evidence.parse(text, request_handle, expected_revision)
    local checksum_ok, request_checksum = pcall(probe_checksum, request_handle)
    if not checksum_ok or not is_sha256(request_checksum) then
        fail("CGCE-DISC-REQUEST", "request_handle", "discovery probe request handle is invalid")
    end
    local table_ok, request_value = pcall(probe_to_table, request_handle)
    if not table_ok
        or type(request_value) ~= "table"
        or request_value.checksum ~= request_checksum
        or type(request_value.candidates) ~= "table" then
        fail("CGCE-DISC-REQUEST", "request_handle", "discovery probe request handle is invalid")
    end

    local value = parse_json(text)
    validate_top_level(value, expected_revision, request_checksum)
    verify_checksum(value)
    validate_revision_evidence(value.revision_evidence, expected_revision)

    local record_count = dense_array_length(value.symbols, "symbols", true)
    local pair_seen = {}
    local records = {}
    for index = 1, record_count do
        local logical_symbol, candidate_index = validate_record(
            value.symbols[index],
            "symbols[" .. index .. "]",
            request_value.candidates
        )
        local symbol_pairs = pair_seen[logical_symbol]
        if symbol_pairs == nil then
            symbol_pairs = {}
            pair_seen[logical_symbol] = symbol_pairs
            records[logical_symbol] = {}
        end
        if symbol_pairs[candidate_index] then
            fail(
                "CGCE-DISC-DUPLICATE",
                "symbols[" .. index .. "].candidate_index",
                "duplicate logical-symbol candidate observation"
            )
        end
        symbol_pairs[candidate_index] = true
        records[logical_symbol][candidate_index] = value.symbols[index]
    end

    validate_snapshot_evidence(value.before_snapshot_54)
    validate_fatal_safety(value.fatal_safety)
    local readiness = build_manifest_readiness(
        request_value.candidates,
        records,
        value.revision_evidence,
        value.before_snapshot_54,
        value.fatal_safety
    )

    local handle = function() end
    parsed_observations[handle] = {
        encoded = json_encode(value),
        checksum = value.checksum,
        readiness = json_encode(readiness),
    }
    return handle
end


function discovery_evidence.to_table(handle)
    return json_decode(require_observation(handle).encoded)
end

function discovery_evidence.manifest_readiness(handle)
    return json_decode(require_observation(handle).readiness)
end

function discovery_evidence.checksum(handle)
    return require_observation(handle).checksum
end

function discovery_evidence.authoritative(handle)
    require_observation(handle)
    return false
end

function discovery_evidence.mutation_capability(handle)
    require_observation(handle)
    return false
end

return discovery_evidence
