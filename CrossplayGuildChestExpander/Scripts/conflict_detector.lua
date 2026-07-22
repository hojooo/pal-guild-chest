local json_module = require("CrossplayGuildChestExpander.Scripts.json")

local encode_json = json_module.encode
local new_json_array = json_module.array

local conflict_detector = {}

local policy_fields = {
    "policy_version",
    "verified",
    "gate_a_accepted",
    "target_slots",
    "known_slot_counts",
    "paths",
    "types",
}

local path_fields = {
    "owner_package",
    "target_default",
    "container_resizer_hook",
    "guild_chest_storage",
}

local type_fields = { "container_class", "slot" }
local descriptor_fields = { "path", "type_signature" }
local mod_fields = { "package_name", "package_version", "package_path", "claimed_paths" }
local hook_fields = { "function_path", "owner_package_path" }
local container_fields = {
    "class_path",
    "class_type_signature",
    "slot_type_path",
    "slot_type_signature",
    "slot_count",
}

local function fail(code, field, detail)
    error({ code = code, field = field, detail = detail }, 0)
end

local function is_plain_table(value)
    return type(value) == "table" and getmetatable(value) == nil
end

local function validate_object(value, fields, field)
    if not is_plain_table(value) then
        fail("CGCE-CONFLICT-TYPE", field, field .. " must be a plain object")
    end

    local allowed = {}
    for _, name in ipairs(fields) do
        allowed[name] = true
    end

    local unknown = {}
    local has_invalid_key = false
    for key in pairs(value) do
        if type(key) ~= "string" then
            has_invalid_key = true
        elseif not allowed[key] then
            unknown[#unknown + 1] = key
        end
    end
    table.sort(unknown)
    if #unknown > 0 then
        fail("CGCE-CONFLICT-UNKNOWN-KEY", field .. "." .. unknown[1], "unknown conflict input key")
    end
    if has_invalid_key then
        fail("CGCE-CONFLICT-UNKNOWN-KEY", field .. "[invalid-key]", "conflict input keys must be strings")
    end

    for _, name in ipairs(fields) do
        if value[name] == nil then
            fail("CGCE-CONFLICT-MISSING-KEY", field .. "." .. name, "required conflict input key is missing")
        end
    end
end

local function array_length(value, field)
    if not is_plain_table(value) then
        fail("CGCE-CONFLICT-TYPE", field, field .. " must be a plain dense array")
    end

    local count, largest = 0, 0
    for key in pairs(value) do
        if type(key) ~= "number" or math.type(key) ~= "integer" or key < 1 then
            fail("CGCE-CONFLICT-TYPE", field, field .. " must be a plain dense array")
        end
        count = count + 1
        if key > largest then
            largest = key
        end
    end
    if count ~= largest then
        fail("CGCE-CONFLICT-TYPE", field, field .. " must be a plain dense array")
    end
    return count
end

local function validate_text(value, field)
    if type(value) ~= "string" or #value == 0 or value:find("[%z\1-\31\127]") then
        fail("CGCE-CONFLICT-VALUE", field, field .. " must be a non-empty control-free string")
    end
    if not pcall(encode_json, value) then
        fail("CGCE-CONFLICT-VALUE", field, field .. " must be valid UTF-8")
    end
end

local function validate_exact_path(value, field)
    validate_text(value, field)
    if value:sub(1, 1) ~= "/" or value:find("[*?]") or value:find("...", 1, true) then
        fail("CGCE-CONFLICT-PATH-NOT-EXACT", field, "policy and inventory paths must be exact absolute object paths")
    end
end

local function validate_exact_type(value, field)
    validate_text(value, field)
    local wildcard_only = value:match("^%s*[%*%?]%s*$") ~= nil
    local wildcard_argument = value:match("[%(,<]%s*[%*%?]%s*[%),>]") ~= nil
    if wildcard_only or wildcard_argument or value:find("...", 1, true) then
        fail("CGCE-CONFLICT-TYPE-NOT-EXACT", field, "type signatures must be exact")
    end
end

local function validate_positive_integer(value, field)
    if type(value) ~= "number" or math.type(value) ~= "integer" or value < 1 then
        fail("CGCE-CONFLICT-VALUE", field, field .. " must be a positive integer")
    end
end

local function validate_policy(policy)
    validate_object(policy, policy_fields, "policy")
    if policy.policy_version ~= "1.0" then
        fail("CGCE-CONFLICT-VALUE", "policy.policy_version", "unsupported conflict policy version")
    end
    if type(policy.verified) ~= "boolean" then
        fail("CGCE-CONFLICT-TYPE", "policy.verified", "policy.verified must be a boolean")
    end
    if policy.verified ~= true then
        fail("CGCE-CONFLICT-POLICY-UNVERIFIED", "policy.verified", "conflict policy must be verified before scanning")
    end
    if type(policy.gate_a_accepted) ~= "boolean" then
        fail("CGCE-CONFLICT-TYPE", "policy.gate_a_accepted", "policy.gate_a_accepted must be a boolean")
    end
    validate_positive_integer(policy.target_slots, "policy.target_slots")

    local known_length = array_length(policy.known_slot_counts, "policy.known_slot_counts")
    if known_length == 0 then
        fail("CGCE-CONFLICT-VALUE", "policy.known_slot_counts", "at least one known slot count is required")
    end
    local previous, contains_target
    for index = 1, known_length do
        local count = policy.known_slot_counts[index]
        validate_positive_integer(count, "policy.known_slot_counts[" .. index .. "]")
        if previous and count <= previous then
            fail("CGCE-CONFLICT-VALUE", "policy.known_slot_counts", "known slot counts must be unique and ascending")
        end
        contains_target = contains_target or count == policy.target_slots
        previous = count
    end
    if not contains_target then
        fail("CGCE-CONFLICT-VALUE", "policy.known_slot_counts", "known slot counts must include the target")
    end

    validate_object(policy.paths, path_fields, "policy.paths")
    for _, name in ipairs(path_fields) do
        validate_exact_path(policy.paths[name], "policy.paths." .. name)
    end

    validate_object(policy.types, type_fields, "policy.types")
    for _, name in ipairs(type_fields) do
        local prefix = "policy.types." .. name
        local descriptor = policy.types[name]
        validate_object(descriptor, descriptor_fields, prefix)
        validate_exact_path(descriptor.path, prefix .. ".path")
        validate_exact_type(descriptor.type_signature, prefix .. ".type_signature")
    end
end

local function validate_mods(mods)
    local length = array_length(mods, "mods")
    local validated = {}
    for index = 1, length do
        local field = "mods[" .. index .. "]"
        local record = mods[index]
        validate_object(record, mod_fields, field)
        validate_text(record.package_name, field .. ".package_name")
        validate_text(record.package_version, field .. ".package_version")
        validate_exact_path(record.package_path, field .. ".package_path")
        local claimed_length = array_length(record.claimed_paths, field .. ".claimed_paths")
        local seen = {}
        for path_index = 1, claimed_length do
            local path_field = field .. ".claimed_paths[" .. path_index .. "]"
            local path = record.claimed_paths[path_index]
            validate_exact_path(path, path_field)
            if seen[path] then
                fail("CGCE-CONFLICT-VALUE", field .. ".claimed_paths", "claimed paths must be unique")
            end
            seen[path] = true
        end
        validated[index] = record
    end
    return validated
end

local function validate_hooks(hooks)
    local length = array_length(hooks, "hooks")
    for index = 1, length do
        local field = "hooks[" .. index .. "]"
        local record = hooks[index]
        validate_object(record, hook_fields, field)
        validate_exact_path(record.function_path, field .. ".function_path")
        validate_exact_path(record.owner_package_path, field .. ".owner_package_path")
    end
    return length
end

local function validate_containers(containers)
    local length = array_length(containers, "containers")
    for index = 1, length do
        local field = "containers[" .. index .. "]"
        local record = containers[index]
        validate_object(record, container_fields, field)
        validate_exact_path(record.class_path, field .. ".class_path")
        validate_exact_type(record.class_type_signature, field .. ".class_type_signature")
        validate_exact_path(record.slot_type_path, field .. ".slot_type_path")
        validate_exact_type(record.slot_type_signature, field .. ".slot_type_signature")
        validate_positive_integer(record.slot_count, field .. ".slot_count")
    end
    return length
end

local function add_finding(findings, code, severity, field, detail, forced_noop)
    findings[#findings + 1] = {
        code = code,
        severity = severity,
        field = field,
        detail = detail,
        forced_noop = forced_noop,
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

local function sorted_inventory(mods)
    local ordered = {}
    for index, record in ipairs(mods) do
        ordered[index] = record
    end
    table.sort(ordered, function(left, right)
        if left.package_name ~= right.package_name then
            return left.package_name < right.package_name
        end
        if left.package_version ~= right.package_version then
            return left.package_version < right.package_version
        end
        return left.package_path < right.package_path
    end)

    local inventory = new_json_array()
    for index, record in ipairs(ordered) do
        inventory[index] = {
            package_name = record.package_name,
            package_version = record.package_version,
        }
    end
    return inventory
end

function conflict_detector.scan(policy, mods, hooks, containers)
    validate_policy(policy)
    mods = validate_mods(mods)
    local hook_count = validate_hooks(hooks)
    local container_count = validate_containers(containers)

    local findings = new_json_array()
    if not policy.gate_a_accepted then
        add_finding(
            findings,
            "CGCE-CONFLICT-COVERAGE-PARTIAL",
            "WARNING",
            "policy.gate_a_accepted",
            "collision coverage remains partial until Gate A is accepted",
            false
        )
    end

    for mod_index, record in ipairs(mods) do
        if record.package_path ~= policy.paths.owner_package then
            for path_index, claimed_path in ipairs(record.claimed_paths) do
                local field = "mods[" .. mod_index .. "].claimed_paths[" .. path_index .. "]"
                if claimed_path == policy.paths.guild_chest_storage then
                    add_finding(
                        findings,
                        "CGCE-CONFLICT-STORAGE-COLLISION",
                        "BLOCKING",
                        field,
                        "a foreign package claims the exact guild chest storage path",
                        false
                    )
                elseif claimed_path == policy.paths.target_default then
                    add_finding(
                        findings,
                        "CGCE-CONFLICT-TARGET-DEFAULT-COLLISION",
                        "BLOCKING",
                        field,
                        "a foreign package claims the exact target-default path",
                        false
                    )
                end
            end
        end
    end

    for index = 1, hook_count do
        local record = hooks[index]
        if record.function_path == policy.paths.container_resizer_hook
            and record.owner_package_path ~= policy.paths.owner_package then
            add_finding(
                findings,
                "CGCE-CONFLICT-HOOK-COLLISION",
                "BLOCKING",
                "hooks[" .. index .. "].function_path",
                "a foreign package owns the exact container-resizer hook",
                false
            )
        end
    end

    local known_counts = {}
    for _, count in ipairs(policy.known_slot_counts) do
        known_counts[count] = true
    end
    for index = 1, container_count do
        local record = containers[index]
        local prefix = "containers[" .. index .. "]"
        local expected_class = policy.types.container_class
        if record.class_path ~= expected_class.path
            or record.class_type_signature ~= expected_class.type_signature then
            local field = record.class_path ~= expected_class.path
                and prefix .. ".class_path"
                or prefix .. ".class_type_signature"
            add_finding(
                findings,
                "CGCE-CONFLICT-CONTAINER-TYPE-REPLACED",
                "BLOCKING",
                field,
                "container class path or type signature differs from verified policy",
                false
            )
        end

        local expected_slot = policy.types.slot
        if record.slot_type_path ~= expected_slot.path
            or record.slot_type_signature ~= expected_slot.type_signature then
            local field = record.slot_type_path ~= expected_slot.path
                and prefix .. ".slot_type_path"
                or prefix .. ".slot_type_signature"
            add_finding(
                findings,
                "CGCE-CONFLICT-SLOT-TYPE-REPLACED",
                "BLOCKING",
                field,
                "slot type path or type signature differs from verified policy",
                false
            )
        end

        if not known_counts[record.slot_count] then
            if record.slot_count < policy.target_slots then
                add_finding(
                    findings,
                    "CGCE-CONFLICT-UNKNOWN-COUNT-BELOW-TARGET",
                    "BLOCKING",
                    prefix .. ".slot_count",
                    "an unknown slot count below target requires operator investigation",
                    false
                )
            elseif record.slot_count > policy.target_slots then
                add_finding(
                    findings,
                    "CGCE-CONFLICT-UNKNOWN-COUNT-ABOVE-TARGET",
                    "WARNING",
                    prefix .. ".slot_count",
                    "an unknown slot count above target is forced to no-op",
                    true
                )
            end
        end
    end

    sort_findings(findings)
    local blocking, forced_noop = false, false
    for _, finding in ipairs(findings) do
        blocking = blocking or finding.severity == "BLOCKING"
        forced_noop = forced_noop or finding.forced_noop
    end

    return {
        coverage = policy.gate_a_accepted and "complete" or "partial",
        apply_authorized = false,
        blocking = blocking,
        forced_noop = forced_noop,
        mod_inventory = sorted_inventory(mods),
        findings = findings,
    }
end

return conflict_detector
