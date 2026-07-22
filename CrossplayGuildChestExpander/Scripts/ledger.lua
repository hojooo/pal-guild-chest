local audit_module = require("CrossplayGuildChestExpander.Scripts.audit")
local json_module = require("CrossplayGuildChestExpander.Scripts.json")
local path_guard_module = require("CrossplayGuildChestExpander.Scripts.path_guard")
local sha256_module = require("CrossplayGuildChestExpander.Scripts.sha256")

local audit_canonical_json = audit_module.canonical_json
local audit_capture = audit_module.capture
local audit_checksum = audit_module.checksum
local audit_to_table = audit_module.to_table
local json_array = json_module.array
local json_decode = json_module.decode
local json_encode = json_module.encode
local path_resolve = path_guard_module.resolve
local sha256_hex = sha256_module.hex

local ledger = {}
local built_ledgers = setmetatable({}, { __mode = "k" })

local LEDGER_VERSION = "1.0"
local STATUSES = {
    VALIDATING_RESTART_REQUIRED = true,
    COMPLETE = true,
}
local SECRET_FRAGMENTS = {
    "password",
    "token",
    "authorization",
    "cookie",
    "secret",
    "credential",
    "apikey",
    "privatekey",
}

local build_fields = { "audit", "mod_version", "guilds" }
local build_guild_fields = {
    "guild_id",
    "container_id",
    "owner_guild_id",
    "after_slots",
    "after_occupied_slot_count",
    "after_total_item_quantity",
    "after_fingerprint",
    "status",
    "restart_required",
}
local ledger_fields = {
    "ledger_version",
    "world_id",
    "game_revision",
    "deployment_profile",
    "mod_version",
    "target_slots",
    "source_audit_checksum",
    "guilds",
    "checksum",
}
local ledger_guild_fields = {
    "guild_id",
    "container_id",
    "owner_guild_id",
    "before_slots",
    "after_slots",
    "before_occupied_slot_count",
    "after_occupied_slot_count",
    "before_total_item_quantity",
    "after_total_item_quantity",
    "before_fingerprint",
    "after_fingerprint",
    "status",
    "restart_required",
}

local function problem(code, field, detail)
    return { code = code, field = field, detail = detail }
end

local function fail(code, field, detail)
    error(problem(code, field, detail), 0)
end

local function is_plain_table(value)
    return type(value) == "table" and getmetatable(value) == nil
end

local function allowed_map(fields)
    local result = {}
    for _, field in ipairs(fields) do
        result[field] = true
    end
    return result
end

local function validate_object(value, fields, field, code)
    if not is_plain_table(value) then
        fail(code, field, field .. " must be a plain object")
    end
    local allowed = allowed_map(fields)
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
    if unknown[1] ~= nil then
        local prefix = field == "context" and "" or (field .. ".")
        fail(code, prefix .. unknown[1], "unknown ledger field")
    end
    if invalid_key then
        fail(code, field .. "[invalid-key]", "ledger object keys must be strings")
    end
    for _, name in ipairs(fields) do
        if rawget(value, name) == nil then
            local prefix = field == "context" and "" or (field .. ".")
            fail(code, prefix .. name, "required ledger field is missing")
        end
    end
end

local function array_length(value, field, code)
    if not is_plain_table(value) then
        fail(code, field, field .. " must be a plain dense array")
    end
    local count = 0
    local largest = 0
    for key in next, value do
        if type(key) ~= "number" or math.type(key) ~= "integer" or key < 1 then
            fail(code, field, field .. " must be a plain dense array")
        end
        count = count + 1
        if key > largest then
            largest = key
        end
    end
    if count ~= largest then
        fail(code, field, field .. " must be a plain dense array")
    end
    return count
end

local function is_sha256(value)
    return type(value) == "string"
        and #value == 64
        and value:match("^[0-9a-f]+$") ~= nil
end

local function validate_text(value, field, code)
    if type(value) ~= "string"
        or #value == 0
        or value:find("[%z\1-\31\127]") ~= nil
        or not pcall(json_encode, value) then
        fail(code, field, field .. " must be a non-empty control-free UTF-8 string")
    end
    return value
end

local function validate_nonnegative_integer(value, field, code)
    if type(value) ~= "number" or math.type(value) ~= "integer" or value < 0 then
        fail(code, field, field .. " must be a nonnegative integer")
    end
    return value
end

local function validate_positive_integer(value, field, code)
    if type(value) ~= "number" or math.type(value) ~= "integer" or value < 1 then
        fail(code, field, field .. " must be a positive integer")
    end
    return value
end

local function secret_key(key)
    if type(key) ~= "string" then
        return false
    end
    local normalized = key:lower():gsub("[^a-z0-9]", "")
    for _, fragment in ipairs(SECRET_FRAGMENTS) do
        if normalized:find(fragment, 1, true) ~= nil then
            return true
        end
    end
    return false
end

local function reject_secret_keys(value, field, seen)
    if type(value) ~= "table" then
        return
    end
    if seen[value] then
        fail("CGCE-LEDGER-TYPE", field, "cyclic ledger values are forbidden")
    end
    seen[value] = true
    for key, item in next, value do
        local child
        if type(key) == "string" then
            child = field == "context" and key or (field .. "." .. key)
            if secret_key(key) then
                fail("CGCE-LEDGER-SECRET-KEY", child, "secret-bearing ledger keys are forbidden")
            end
        elseif type(key) == "number" and math.type(key) == "integer" then
            child = field .. "[" .. tostring(key) .. "]"
        else
            child = field .. "[invalid-key]"
        end
        reject_secret_keys(item, child, seen)
    end
    seen[value] = nil
end

local function copy_json(value, code, field)
    local encoded_ok, encoded = pcall(json_encode, value)
    if not encoded_ok then
        fail(code, field, field .. " is not canonical JSON data")
    end
    local decoded_ok, detached = pcall(json_decode, encoded)
    if not decoded_ok then
        fail(code, field, field .. " could not be detached")
    end
    return detached, encoded
end

local function unsigned_copy(value)
    local result = {}
    for key, item in next, value do
        if key ~= "checksum" then
            result[key] = item
        end
    end
    return result
end

local function trusted_audit(handle, code)
    local table_ok, detached = pcall(audit_to_table, handle)
    local checksum_ok, checksum = pcall(audit_checksum, handle)
    local canonical_ok, canonical = pcall(audit_canonical_json, handle)
    if not table_ok or not checksum_ok or not canonical_ok or not is_sha256(checksum) then
        fail(code, "audit", "audit must be a trusted Task 5 capture")
    end
    local copied, encoded = copy_json(detached, code, "audit")
    if encoded ~= canonical
        or copied.checksum ~= checksum
        or sha256_hex(json_encode(unsigned_copy(copied))) ~= checksum then
        fail(code, "audit", "trusted audit checksum does not match canonical bytes")
    end
    reject_secret_keys(copied, "audit", {})
    return copied, checksum
end

local function validate_status(value, restart_required, field)
    if not STATUSES[value] then
        fail("CGCE-LEDGER-STATUS", field .. ".status", "ledger guild status is invalid")
    end
    if type(restart_required) ~= "boolean" then
        fail("CGCE-LEDGER-STATUS", field .. ".restart_required", "restart_required must be boolean")
    end
    local expected = value == "VALIDATING_RESTART_REQUIRED"
    if restart_required ~= expected then
        fail("CGCE-LEDGER-STATUS", field .. ".restart_required", "restart_required must match guild status")
    end
end

local function validate_full_guild(record, field, target_slots)
    validate_object(record, ledger_guild_fields, field, "CGCE-LEDGER-GUILD")
    local projected = {
        guild_id = validate_text(record.guild_id, field .. ".guild_id", "CGCE-LEDGER-GUILD"),
        container_id = validate_text(record.container_id, field .. ".container_id", "CGCE-LEDGER-GUILD"),
        owner_guild_id = validate_text(record.owner_guild_id, field .. ".owner_guild_id", "CGCE-LEDGER-GUILD"),
        before_slots = validate_nonnegative_integer(record.before_slots, field .. ".before_slots", "CGCE-LEDGER-GUILD"),
        after_slots = validate_nonnegative_integer(record.after_slots, field .. ".after_slots", "CGCE-LEDGER-GUILD"),
        before_occupied_slot_count = validate_nonnegative_integer(
            record.before_occupied_slot_count,
            field .. ".before_occupied_slot_count",
            "CGCE-LEDGER-GUILD"
        ),
        after_occupied_slot_count = validate_nonnegative_integer(
            record.after_occupied_slot_count,
            field .. ".after_occupied_slot_count",
            "CGCE-LEDGER-GUILD"
        ),
        before_total_item_quantity = validate_nonnegative_integer(
            record.before_total_item_quantity,
            field .. ".before_total_item_quantity",
            "CGCE-LEDGER-GUILD"
        ),
        after_total_item_quantity = validate_nonnegative_integer(
            record.after_total_item_quantity,
            field .. ".after_total_item_quantity",
            "CGCE-LEDGER-GUILD"
        ),
        before_fingerprint = record.before_fingerprint,
        after_fingerprint = record.after_fingerprint,
        status = record.status,
        restart_required = record.restart_required,
    }
    if projected.owner_guild_id ~= projected.guild_id then
        fail("CGCE-LEDGER-AUDIT-MISMATCH", field .. ".owner_guild_id", "ledger owner identity must match guild identity")
    end
    if not is_sha256(projected.before_fingerprint) then
        fail("CGCE-LEDGER-GUILD", field .. ".before_fingerprint", "before fingerprint must be lowercase SHA-256")
    end
    if not is_sha256(projected.after_fingerprint) then
        fail("CGCE-LEDGER-GUILD", field .. ".after_fingerprint", "after fingerprint must be lowercase SHA-256")
    end
    if projected.before_occupied_slot_count > projected.before_slots then
        fail("CGCE-LEDGER-INVARIANT", field .. ".before_occupied_slot_count", "occupied count exceeds before slot count")
    end
    if projected.after_occupied_slot_count > projected.after_slots then
        fail("CGCE-LEDGER-INVARIANT", field .. ".after_occupied_slot_count", "occupied count exceeds after slot count")
    end
    local expected_after = projected.before_slots < target_slots and target_slots or projected.before_slots
    if projected.after_slots ~= expected_after then
        fail("CGCE-LEDGER-INVARIANT", field .. ".after_slots", "after slots violate exact expand-only target")
    end
    if projected.after_occupied_slot_count ~= projected.before_occupied_slot_count then
        fail("CGCE-LEDGER-INVARIANT", field .. ".after_occupied_slot_count", "occupied slot count changed")
    end
    if projected.after_total_item_quantity ~= projected.before_total_item_quantity then
        fail("CGCE-LEDGER-INVARIANT", field .. ".after_total_item_quantity", "total item quantity changed")
    end
    if projected.after_fingerprint ~= projected.before_fingerprint then
        fail("CGCE-LEDGER-INVARIANT", field .. ".after_fingerprint", "item fingerprint changed")
    end
    validate_status(projected.status, projected.restart_required, field)
    return projected
end

local function project_full_guilds(value, target_slots)
    local length = array_length(value, "guilds", "CGCE-LEDGER-GUILD")
    local result = json_array()
    local seen_guilds = {}
    local seen_containers = {}
    for index = 1, length do
        local field = "guilds[" .. tostring(index) .. "]"
        local record = validate_full_guild(rawget(value, index), field, target_slots)
        if seen_guilds[record.guild_id] then
            fail("CGCE-LEDGER-GUILD", field .. ".guild_id", "duplicate guild ID")
        end
        if seen_containers[record.container_id] then
            fail("CGCE-LEDGER-GUILD", field .. ".container_id", "duplicate container ID")
        end
        seen_guilds[record.guild_id] = true
        seen_containers[record.container_id] = true
        result[index] = record
    end
    table.sort(result, function(left, right)
        return left.guild_id < right.guild_id
    end)
    return result
end

local function finalize(unsigned)
    unsigned.checksum = sha256_hex(json_encode(unsigned))
    local built = json_decode(json_encode(unsigned))
    built_ledgers[built] = json_encode(built)
    return built
end

function ledger.build(context)
    if not is_plain_table(context) then
        fail("CGCE-LEDGER-CONTEXT", "context", "ledger context must be a plain object")
    end
    reject_secret_keys(context, "context", {})
    validate_object(context, build_fields, "context", "CGCE-LEDGER-CONTEXT")
    local source, source_checksum = trusted_audit(context.audit, "CGCE-LEDGER-AUDIT")
    validate_text(context.mod_version, "mod_version", "CGCE-LEDGER-CONTEXT")
    if array_length(source.blocking_errors, "audit.blocking_errors", "CGCE-LEDGER-AUDIT") > 0 then
        fail("CGCE-LEDGER-AUDIT", "audit.blocking_errors", "source audit contains blocking findings")
    end

    local source_guilds = {}
    for _, record in ipairs(source.guilds) do
        source_guilds[record.guild_id] = record
    end
    local length = array_length(context.guilds, "guilds", "CGCE-LEDGER-GUILD")
    local full = json_array()
    for index = 1, length do
        local field = "guilds[" .. tostring(index) .. "]"
        local input = rawget(context.guilds, index)
        validate_object(input, build_guild_fields, field, "CGCE-LEDGER-GUILD")
        local guild_id = validate_text(input.guild_id, field .. ".guild_id", "CGCE-LEDGER-GUILD")
        local source_guild = source_guilds[guild_id]
        if source_guild == nil or not is_plain_table(source_guild.snapshot) then
            fail("CGCE-LEDGER-AUDIT-MISMATCH", field .. ".guild_id", "guild has no exact source-audit snapshot")
        end
        local before = source_guild.snapshot
        if input.container_id ~= before.container_id then
            fail("CGCE-LEDGER-AUDIT-MISMATCH", field .. ".container_id", "container identity differs from source audit")
        end
        if input.owner_guild_id ~= before.owner_guild_id or input.owner_guild_id ~= guild_id then
            fail("CGCE-LEDGER-AUDIT-MISMATCH", field .. ".owner_guild_id", "owner identity differs from source audit")
        end
        full[index] = {
            guild_id = guild_id,
            container_id = input.container_id,
            owner_guild_id = input.owner_guild_id,
            before_slots = before.slot_count,
            after_slots = input.after_slots,
            before_occupied_slot_count = before.occupied_slot_count,
            after_occupied_slot_count = input.after_occupied_slot_count,
            before_total_item_quantity = before.total_item_quantity,
            after_total_item_quantity = input.after_total_item_quantity,
            before_fingerprint = before.item_fingerprint,
            after_fingerprint = input.after_fingerprint,
            status = input.status,
            restart_required = input.restart_required,
        }
    end

    local unsigned = {
        ledger_version = LEDGER_VERSION,
        world_id = source.world_id,
        game_revision = source.game_revision,
        deployment_profile = source.deployment_profile,
        mod_version = context.mod_version,
        target_slots = source.target_slots,
        source_audit_checksum = source_checksum,
        guilds = project_full_guilds(full, source.target_slots),
    }
    reject_secret_keys(unsigned, "ledger", {})
    return finalize(unsigned)
end

local function validate_ledger(value)
    if not is_plain_table(value) then
        fail("CGCE-LEDGER-TYPE", "ledger", "ledger must be a plain object")
    end
    reject_secret_keys(value, "ledger", {})
    validate_object(value, ledger_fields, "ledger", "CGCE-LEDGER-TYPE")
    if value.ledger_version ~= LEDGER_VERSION then
        fail("CGCE-LEDGER-VERSION", "ledger_version", "unsupported ledger version")
    end
    validate_text(value.world_id, "world_id", "CGCE-LEDGER-TYPE")
    validate_positive_integer(value.game_revision, "game_revision", "CGCE-LEDGER-TYPE")
    validate_text(value.deployment_profile, "deployment_profile", "CGCE-LEDGER-TYPE")
    validate_text(value.mod_version, "mod_version", "CGCE-LEDGER-TYPE")
    validate_positive_integer(value.target_slots, "target_slots", "CGCE-LEDGER-TYPE")
    if not is_sha256(value.source_audit_checksum) then
        fail("CGCE-LEDGER-AUDIT", "source_audit_checksum", "source audit checksum must be lowercase SHA-256")
    end
    if not is_sha256(value.checksum) then
        fail("CGCE-LEDGER-CHECKSUM", "checksum", "ledger checksum must be lowercase SHA-256")
    end

    local normalized = {
        ledger_version = LEDGER_VERSION,
        world_id = value.world_id,
        game_revision = value.game_revision,
        deployment_profile = value.deployment_profile,
        mod_version = value.mod_version,
        target_slots = value.target_slots,
        source_audit_checksum = value.source_audit_checksum,
        guilds = project_full_guilds(value.guilds, value.target_slots),
    }
    if sha256_hex(json_encode(normalized)) ~= value.checksum then
        fail("CGCE-LEDGER-CHECKSUM", "checksum", "ledger self-checksum mismatch")
    end
    normalized.checksum = value.checksum
    local canonical = json_encode(normalized)
    if canonical ~= json_encode(value) then
        fail("CGCE-LEDGER-CHECKSUM", "checksum", "ledger is not canonical")
    end
    return json_decode(canonical)
end

local function capture_read_ports(fs)
    if not is_plain_table(fs) then
        return nil
    end
    local names = {
        "capabilities",
        "canonicalize",
        "inspect_no_follow",
        "propose_temp_sibling",
        "read_all_no_follow",
    }
    local ports = {}
    for _, name in ipairs(names) do
        local port = rawget(fs, name)
        if type(port) ~= "function" then
            return nil
        end
        ports[name] = port
    end
    return ports
end

local function read_failed()
    return {
        status = "READ_FAILED",
        error = problem("CGCE-LEDGER-READ-FAILED", "ledger", "ledger could not be read safely"),
    }
end

local function malformed()
    return {
        status = "MALFORMED",
        error = problem("CGCE-LEDGER-MALFORMED", "ledger", "ledger bytes or checksum are malformed"),
    }
end

local function load_ledger(fs, root, relative_path)
    local ports = capture_read_ports(fs)
    if ports == nil then
        return read_failed()
    end
    local guard_fs = {
        capabilities = ports.capabilities,
        canonicalize = ports.canonicalize,
        inspect_no_follow = ports.inspect_no_follow,
        propose_temp_sibling = ports.propose_temp_sibling,
    }
    local resolved_ok, resolved = pcall(path_resolve, guard_fs, root, relative_path)
    if not resolved_ok then
        return read_failed()
    end
    local read_ok, bytes, secondary = pcall(ports.read_all_no_follow, resolved.target)
    if not read_ok then
        return read_failed()
    end
    if bytes == nil and secondary == "missing" then
        return { status = "MISSING" }
    end
    if type(bytes) ~= "string" or secondary ~= nil then
        return read_failed()
    end
    local decode_ok, decoded = pcall(json_decode, bytes)
    if not decode_ok then
        return malformed()
    end
    local validate_ok, validated = pcall(validate_ledger, decoded)
    if not validate_ok then
        return malformed()
    end
    return { status = "LOADED", ledger = validated }
end

function ledger.load(fs, root, relative_path)
    return load_ledger(fs, root, relative_path)
end

local function capture_write_ports(fs)
    if not is_plain_table(fs) then
        fail("CGCE-LEDGER-SAVE", "fs", "filesystem port must be a plain object")
    end
    local names = {
        "capabilities",
        "canonicalize",
        "inspect_no_follow",
        "propose_temp_sibling",
        "create_exclusive",
        "write_all",
        "flush_file",
        "close_file",
        "atomic_replace",
        "flush_directory",
        "read_all_no_follow",
    }
    local ports = {}
    for _, name in ipairs(names) do
        local port = rawget(fs, name)
        if type(port) ~= "function" then
            fail("CGCE-LEDGER-SAVE", name, "required filesystem operation is unavailable")
        end
        ports[name] = port
    end
    return ports
end

local function call_true(port, ...)
    local ok, value, secondary = pcall(port, ...)
    return ok and value == true and secondary == nil
end

function ledger.save(fs, root, relative_path, value)
    local registered = built_ledgers[value]
    local encoded_ok, supplied_bytes = pcall(json_encode, value)
    if registered == nil or not encoded_ok or supplied_bytes ~= registered then
        fail("CGCE-LEDGER-PROVENANCE", "ledger", "only an unchanged ledger.build result may be saved")
    end
    local validated = validate_ledger(value)
    local bytes = json_encode(validated)
    local ports = capture_write_ports(fs)
    local guard_fs = {
        capabilities = ports.capabilities,
        canonicalize = ports.canonicalize,
        inspect_no_follow = ports.inspect_no_follow,
        propose_temp_sibling = ports.propose_temp_sibling,
    }
    local resolved_ok, resolved = pcall(path_resolve, guard_fs, root, relative_path)
    if not resolved_ok then
        fail("CGCE-LEDGER-SAVE", "path_guard", "safe ledger path resolution failed")
    end

    local created_ok, handle, secondary = pcall(ports.create_exclusive, resolved.temp_sibling)
    local handle_type = type(handle)
    local opaque_handle = handle_type == "function"
        or handle_type == "userdata"
        or handle_type == "thread"
    if created_ok and handle ~= nil and (secondary ~= nil or not opaque_handle) then
        pcall(ports.close_file, handle)
    end
    if not created_ok
        or secondary ~= nil
        or not opaque_handle then
        fail("CGCE-LEDGER-SAVE", "create_exclusive", "exclusive temporary ledger creation failed")
    end
    local closed = false
    local function close_once()
        if closed then
            return true
        end
        closed = true
        return call_true(ports.close_file, handle)
    end
    local function fail_after_create(field, detail)
        close_once()
        fail("CGCE-LEDGER-SAVE", field, detail)
    end

    if not call_true(ports.write_all, handle, bytes) then
        fail_after_create("write_all", "temporary ledger write failed")
    end
    if not call_true(ports.flush_file, handle) then
        fail_after_create("flush_file", "temporary ledger durable flush failed")
    end
    if not close_once() then
        fail("CGCE-LEDGER-SAVE", "close_file", "temporary ledger close failed")
    end
    if not call_true(ports.atomic_replace, resolved.temp_sibling, resolved.target) then
        fail("CGCE-LEDGER-SAVE", "atomic_replace", "atomic ledger replace failed")
    end
    if not call_true(ports.flush_directory, resolved.parent) then
        fail("CGCE-LEDGER-SAVE", "flush_directory", "ledger directory durability barrier failed")
    end
    local read_ok, read_bytes, read_error = pcall(ports.read_all_no_follow, resolved.target)
    if not read_ok or read_error ~= nil or type(read_bytes) ~= "string" or read_bytes ~= bytes then
        fail("CGCE-LEDGER-READBACK", "read_all_no_follow", "persisted ledger bytes do not match canonical bytes")
    end

    return {
        path = resolved.target,
        relative_path = resolved.relative_path,
        ledger_checksum = validated.checksum,
        source_audit_checksum = validated.source_audit_checksum,
        byte_length = #bytes,
        durable = true,
        read_back_verified = true,
    }
end

local function sort_findings(findings)
    table.sort(findings, function(left, right)
        if left.code ~= right.code then
            return left.code < right.code
        end
        if left.field ~= right.field then
            return left.field < right.field
        end
        return left.detail < right.detail
    end)
end

local function add_finding(findings, code, field, detail)
    findings[#findings + 1] = problem(code, field, detail)
end

local function audit_failure_result()
    return {
        status = "AUDIT_BLOCKED",
        source = "live_save",
        can_mark_completed = false,
        guilds = json_array(),
        findings = json_array({
            problem("CGCE-LEDGER-AUDIT-BLOCKED", "audit", "fresh live audit could not be captured"),
        }),
    }
end

local function load_status_result(load_result, fresh, fresh_checksum)
    local findings = json_array()
    add_finding(
        findings,
        "CGCE-LEDGER-" .. load_result.status,
        "ledger",
        "existing ledger status is " .. load_result.status:lower()
    )
    local guilds = json_array()
    for _, live in ipairs(fresh.guilds) do
        local status
        if live.status == "not_initialized" then
            status = "NOT_INITIALIZED"
        elseif live.status == "excluded_by_filter" then
            status = "EXCLUDED"
        elseif live.status == "eligible_noop" then
            status = "NOOP_UNTRACKED"
        elseif live.status == "eligible_expand" then
            status = "UNTRACKED"
        else
            status = "BLOCKED"
        end
        guilds[#guilds + 1] = {
            guild_id = live.guild_id,
            status = status,
            findings = json_array(),
        }
    end
    return {
        status = load_result.status,
        source = "live_save",
        fresh_audit_checksum = fresh_checksum,
        can_mark_completed = false,
        guilds = guilds,
        findings = findings,
    }
end

local function compare_live(loaded, fresh, fresh_checksum)
    local findings = json_array()
    local guild_results = json_array()
    local drift = false
    local audit_blocked = #fresh.blocking_errors > 0

    local header_checks = {
        { "world_id", "CGCE-LEDGER-WORLD-DRIFT" },
        { "game_revision", "CGCE-LEDGER-REVISION-DRIFT" },
        { "deployment_profile", "CGCE-LEDGER-PROFILE-DRIFT" },
        { "target_slots", "CGCE-LEDGER-TARGET-DRIFT" },
    }
    for _, check in ipairs(header_checks) do
        local field, code = check[1], check[2]
        if loaded[field] ~= fresh[field] then
            add_finding(findings, code, field, "live audit identity differs from ledger")
            drift = true
        end
    end

    local ledger_by_guild = {}
    for _, record in ipairs(loaded.guilds) do
        ledger_by_guild[record.guild_id] = record
    end
    local seen_live = {}
    for _, live in ipairs(fresh.guilds) do
        local guild_id = live.guild_id
        seen_live[guild_id] = true
        local stored = ledger_by_guild[guild_id]
        local per_guild = json_array()
        local status

        if live.status == "blocked" then
            status = "BLOCKED"
            for _, audit_error in ipairs(live.errors) do
                if audit_error.code == "CGCE-AUD-OWNER-MISMATCH" then
                    add_finding(per_guild, "CGCE-LEDGER-OWNER-DRIFT", "guilds." .. guild_id .. ".owner_guild_id", "live owner identity differs from ledger")
                elseif audit_error.code == "CGCE-AUD-CONTAINER-UNRESOLVED" then
                    add_finding(per_guild, "CGCE-LEDGER-CONTAINER-MISSING", "guilds." .. guild_id .. ".container_id", "live container could not be resolved")
                else
                    add_finding(per_guild, "CGCE-LEDGER-AUDIT-BLOCKED", "guilds." .. guild_id, "fresh audit blocked this guild")
                end
            end
            audit_blocked = true
        elseif live.status == "not_initialized" then
            if stored == nil then
                status = "NOT_INITIALIZED"
            else
                status = "DRIFT"
                add_finding(per_guild, "CGCE-LEDGER-CONTAINER-MISSING", "guilds." .. guild_id .. ".container_id", "ledger container is missing from live guild")
                drift = true
            end
        elseif stored == nil then
            if live.status == "excluded_by_filter" then
                status = "EXCLUDED"
            elseif live.status == "eligible_noop" then
                status = "NOOP_UNTRACKED"
            else
                status = "UNTRACKED"
                add_finding(per_guild, "CGCE-LEDGER-GUILD-UNTRACKED", "guilds." .. guild_id, "eligible live guild is absent from ledger")
                drift = true
            end
        else
            local live_snapshot = live.snapshot
            if not is_plain_table(live_snapshot) then
                status = "DRIFT"
                add_finding(per_guild, "CGCE-LEDGER-CONTAINER-MISSING", "guilds." .. guild_id .. ".container_id", "live guild has no comparable snapshot")
                drift = true
            else
                local comparisons = {
                    { stored.container_id, live_snapshot.container_id, "CGCE-LEDGER-CONTAINER-DRIFT", "container_id" },
                    { stored.owner_guild_id, live_snapshot.owner_guild_id, "CGCE-LEDGER-OWNER-DRIFT", "owner_guild_id" },
                    { stored.after_slots, live_snapshot.slot_count, "CGCE-LEDGER-SLOT-COUNT-DRIFT", "slot_count" },
                    { stored.after_occupied_slot_count, live_snapshot.occupied_slot_count, "CGCE-LEDGER-OCCUPIED-COUNT-DRIFT", "occupied_slot_count" },
                    { stored.after_total_item_quantity, live_snapshot.total_item_quantity, "CGCE-LEDGER-QUANTITY-DRIFT", "total_item_quantity" },
                    { stored.after_fingerprint, live_snapshot.item_fingerprint, "CGCE-LEDGER-FINGERPRINT-DRIFT", "item_fingerprint" },
                }
                if live.chest_container_id ~= stored.container_id then
                    add_finding(per_guild, "CGCE-LEDGER-CONTAINER-DRIFT", "guilds." .. guild_id .. ".container_id", "configured live container differs from ledger")
                end
                for _, comparison in ipairs(comparisons) do
                    if comparison[1] ~= comparison[2] then
                        add_finding(
                            per_guild,
                            comparison[3],
                            "guilds." .. guild_id .. "." .. comparison[4],
                            "live save state differs from ledger after-state"
                        )
                    end
                end
                if #per_guild == 0 then
                    status = "MATCH"
                else
                    status = "DRIFT"
                    drift = true
                end
            end
        end

        sort_findings(per_guild)
        for _, finding in ipairs(per_guild) do
            findings[#findings + 1] = finding
        end
        guild_results[#guild_results + 1] = {
            guild_id = guild_id,
            status = status,
            findings = per_guild,
        }
    end

    for _, stored in ipairs(loaded.guilds) do
        if not seen_live[stored.guild_id] then
            local per_guild = json_array({
                problem(
                    "CGCE-LEDGER-GUILD-MISSING",
                    "guilds." .. stored.guild_id,
                    "ledger guild is absent from fresh live audit"
                ),
            })
            guild_results[#guild_results + 1] = {
                guild_id = stored.guild_id,
                status = "MISSING",
                findings = per_guild,
            }
            findings[#findings + 1] = per_guild[1]
            drift = true
        end
    end

    if audit_blocked then
        add_finding(findings, "CGCE-LEDGER-AUDIT-BLOCKED", "audit", "fresh live audit contains blocking findings")
    end
    sort_findings(findings)
    table.sort(guild_results, function(left, right)
        return left.guild_id < right.guild_id
    end)

    local status = audit_blocked and "AUDIT_BLOCKED" or (drift and "DRIFT" or "MATCH")
    local has_restart_required = false
    for _, stored in ipairs(loaded.guilds) do
        has_restart_required = has_restart_required or stored.restart_required
    end
    return {
        status = status,
        source = "live_save",
        fresh_audit_checksum = fresh_checksum,
        ledger_checksum = loaded.checksum,
        can_mark_completed = status == "MATCH" and has_restart_required,
        guilds = guild_results,
        findings = findings,
    }
end

function ledger.verify(fs, root, relative_path, audit_context)
    local capture_ok, handle = pcall(audit_capture, audit_context)
    if not capture_ok then
        return audit_failure_result()
    end
    local trusted_ok, fresh, fresh_checksum = pcall(trusted_audit, handle, "CGCE-LEDGER-AUDIT")
    if not trusted_ok then
        return audit_failure_result()
    end

    local load_result = load_ledger(fs, root, relative_path)
    if load_result.status ~= "LOADED" then
        return load_status_result(load_result, fresh, fresh_checksum)
    end
    return compare_live(load_result.ledger, fresh, fresh_checksum)
end

return ledger
