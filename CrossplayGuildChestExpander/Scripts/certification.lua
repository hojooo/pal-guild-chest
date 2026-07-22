local constants = require("CrossplayGuildChestExpander.Scripts.constants")
local json = require("CrossplayGuildChestExpander.Scripts.json")
local sha256 = require("CrossplayGuildChestExpander.Scripts.sha256")

local certification = {}

local artifact_fields = {
    certification_version = true,
    game_revision = true,
    deployment_profile = true,
    binding_manifest_checksum = true,
    gate_a_checksum = true,
    release_report_checksum = true,
    required_clients = true,
    slots = true,
    checksum = true,
}

local slot_fields = {
    target_slots = true,
    evidence = true,
}

local target_candidates = {}
for _, slots in ipairs(constants.target_slot_candidates) do
    target_candidates[slots] = true
end

local required_client_set = {}
for _, client in ipairs(constants.required_clients) do
    required_client_set[client] = true
end

local common_evidence_fields = {
    "ui_access",
    "last_slot_access",
    "restart_reconnect",
    "cross_platform_consistency",
}

local common_evidence_set = {}
for _, field in ipairs(common_evidence_fields) do
    common_evidence_set[field] = true
end

local function fail(code, field, detail)
    error({ code = code, field = field, detail = detail }, 0)
end

local function is_sha256(value)
    return type(value) == "string" and #value == 64 and value:match("^[0-9a-f]+$") ~= nil
end

local function array_length(value, field)
    if type(value) ~= "table" then
        fail("CGCE-CERT-TYPE", field, field .. " must be an array")
    end
    local count = 0
    local largest = 0
    for key in pairs(value) do
        if type(key) ~= "number" or math.type(key) ~= "integer" or key < 1 then
            fail("CGCE-CERT-TYPE", field, field .. " must be an array")
        end
        count = count + 1
        if key > largest then
            largest = key
        end
    end
    if largest ~= count then
        fail("CGCE-CERT-TYPE", field, field .. " must be a dense array")
    end
    return count
end

local function validate_schema(artifact)
    if type(artifact) ~= "table" then
        fail("CGCE-CERT-TYPE", nil, "release artifact must be an object")
    end
    for key in pairs(artifact) do
        if not artifact_fields[key] then
            fail("CGCE-CERT-UNKNOWN-KEY", key, "unknown certification artifact key")
        end
    end
    for field in pairs(artifact_fields) do
        if artifact[field] == nil then
            fail("CGCE-CERT-MISSING-KEY", field, "required certification artifact key is missing")
        end
    end
end

local function validate_checksum(artifact, pinned_checksum)
    if not is_sha256(pinned_checksum) or artifact.checksum ~= pinned_checksum then
        fail("CGCE-CERT-PIN", "checksum", "release artifact does not match the build checksum pin")
    end
    if not is_sha256(artifact.checksum) then
        fail("CGCE-CERT-CHECKSUM", "checksum", "artifact checksum must be lowercase SHA-256")
    end

    local unsigned = {}
    for key, value in pairs(artifact) do
        if key ~= "checksum" then
            unsigned[key] = value
        end
    end
    if sha256.hex(json.encode(unsigned)) ~= artifact.checksum then
        fail("CGCE-CERT-CHECKSUM", "checksum", "certification artifact self-checksum mismatch")
    end
end

local function validate_required_clients(clients)
    local length = array_length(clients, "required_clients")
    if length ~= #constants.required_clients then
        fail("CGCE-CERT-REQUIRED-CLIENTS", "required_clients", "required clients do not match the release profile")
    end
    for index, expected in ipairs(constants.required_clients) do
        if clients[index] ~= expected then
            fail("CGCE-CERT-REQUIRED-CLIENTS", "required_clients", "required clients do not match the canonical order")
        end
    end
end

local function validate_evidence_record(record, field, client)
    if type(record) ~= "table" then
        fail("CGCE-CERT-CLIENT-EVIDENCE", field, "client evidence record is missing")
    end
    for _, required_field in ipairs(common_evidence_fields) do
        if record[required_field] == nil then
            fail("CGCE-CERT-EVIDENCE-MISSING", field .. "." .. required_field, "required client evidence check is missing")
        end
    end
    if client == "PS5" then
        if record.community_server_list ~= true then
            fail("CGCE-CERT-PS5-COMMUNITY", field .. ".community_server_list", "PS5 Community Server list evidence is required")
        end
        if record.dualsense_last_slot ~= true then
            fail("CGCE-CERT-PS5-DUALSENSE", field .. ".dualsense_last_slot", "PS5 DualSense last-slot evidence is required")
        end
    end

    local count = 0
    for check, passed in pairs(record) do
        count = count + 1
        local allowed = common_evidence_set[check]
            or (client == "PS5" and (check == "community_server_list" or check == "dualsense_last_slot"))
        if not allowed then
            fail("CGCE-CERT-EVIDENCE-UNKNOWN", field .. "." .. tostring(check), "unknown client evidence check")
        end
        if type(check) ~= "string" or #check == 0 or passed ~= true then
            fail("CGCE-CERT-EVIDENCE-NOT-PASSED", field .. "." .. tostring(check), "every client evidence check must be true")
        end
    end
    if count == 0 then
        fail("CGCE-CERT-CLIENT-EVIDENCE", field, "client evidence record must not be empty")
    end
end

local function validate_slot(slot, index, previous)
    local prefix = "slots[" .. index .. "]"
    if type(slot) ~= "table" then
        fail("CGCE-CERT-SLOT", prefix, "slot certification must be an object")
    end
    for key in pairs(slot) do
        if not slot_fields[key] then
            fail("CGCE-CERT-SLOT", prefix .. "." .. tostring(key), "unknown slot certification key")
        end
    end
    for field in pairs(slot_fields) do
        if slot[field] == nil then
            fail("CGCE-CERT-SLOT", prefix .. "." .. field, "slot certification key is required")
        end
    end
    if type(slot.target_slots) ~= "number" or math.type(slot.target_slots) ~= "integer"
        or not target_candidates[slot.target_slots] or (previous and slot.target_slots <= previous) then
        fail("CGCE-CERT-SLOT", prefix .. ".target_slots", "certified slots must be unique ascending candidates")
    end
    if type(slot.evidence) ~= "table" then
        fail("CGCE-CERT-CLIENT-EVIDENCE", prefix .. ".evidence", "per-client evidence must be an object")
    end
    for client in pairs(slot.evidence) do
        if not required_client_set[client] then
            fail("CGCE-CERT-CLIENT-EVIDENCE", prefix .. ".evidence." .. tostring(client), "unexpected client evidence")
        end
    end
    for _, client in ipairs(constants.required_clients) do
        validate_evidence_record(slot.evidence[client], prefix .. ".evidence." .. client, client)
    end
    return slot.target_slots
end

function certification.verify(release_artifact, pinned_checksum, revision, profile)
    validate_schema(release_artifact)
    validate_checksum(release_artifact, pinned_checksum)

    if release_artifact.certification_version ~= constants.versions.certification then
        fail("CGCE-CERT-VERSION", "certification_version", "unsupported certification artifact version")
    end
    if type(revision) ~= "number" or math.type(revision) ~= "integer"
        or release_artifact.game_revision ~= revision then
        fail("CGCE-CERT-REVISION", "game_revision", "live revision does not exactly match certification artifact")
    end
    if profile ~= constants.deployment_profile or release_artifact.deployment_profile ~= profile then
        fail("CGCE-CERT-PROFILE", "deployment_profile", "deployment profile does not exactly match certification artifact")
    end
    for _, field in ipairs({ "binding_manifest_checksum", "gate_a_checksum", "release_report_checksum" }) do
        if not is_sha256(release_artifact[field]) then
            fail("CGCE-CERT-BOUND-CHECKSUM", field, field .. " must be a lowercase SHA-256 binding")
        end
    end
    validate_required_clients(release_artifact.required_clients)

    local length = array_length(release_artifact.slots, "slots")
    if length == 0 then
        fail("CGCE-CERT-SLOT", "slots", "at least one certified slot is required")
    end
    local certified_slots = {}
    local previous
    for index = 1, length do
        local target_slots = validate_slot(release_artifact.slots[index], index, previous)
        certified_slots[index] = target_slots
        previous = target_slots
    end
    return certified_slots
end

return certification
