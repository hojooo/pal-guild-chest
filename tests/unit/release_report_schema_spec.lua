local a = require("tests.support.assertions")
local json = require("CrossplayGuildChestExpander.Scripts.json")
local sha256 = require("CrossplayGuildChestExpander.Scripts.sha256")

local SCHEMA_PATH = "docs/release-report.schema.json"
local SHA256_PATTERN = "^[0-9a-f]{64}$"

local function read_schema()
    local file = assert(io.open(SCHEMA_PATH, "rb"))
    local text = file:read("*a")
    file:close()
    return json.decode(text)
end

local function is_array(value)
    if type(value) ~= "table" then
        return false
    end
    if next(value) == nil then
        return json.encode(value) == "[]"
    end
    local count, largest = 0, 0
    for key in pairs(value) do
        if type(key) ~= "number" or math.type(key) ~= "integer" or key < 1 then
            return false
        end
        count = count + 1
        largest = math.max(largest, key)
    end
    return count == largest
end

local function deep_equal(left, right, seen)
    if left == right then
        return true
    end
    if type(left) ~= "table" or type(right) ~= "table" then
        return false
    end
    seen = seen or {}
    if seen[left] == right then
        return true
    end
    seen[left] = right
    for key, value in pairs(left) do
        if not deep_equal(value, right[key], seen) then
            return false
        end
    end
    for key in pairs(right) do
        if left[key] == nil then
            return false
        end
    end
    return true
end

local function resolve_reference(root, reference)
    local name = reference:match("^#/%$defs/([A-Za-z0-9_%-]+)$")
    assert(name ~= nil, "unsupported schema reference: " .. tostring(reference))
    assert(root["$defs"] and root["$defs"][name], "missing schema definition: " .. name)
    return root["$defs"][name]
end

local function validate(root, rule, value, path)
    path = path or "$"
    if rule["$ref"] then
        return validate(root, resolve_reference(root, rule["$ref"]), value, path)
    end

    if rule.const ~= nil and not deep_equal(rule.const, value) then
        return false, path .. " does not match const"
    end
    if rule.enum then
        local matched = false
        for _, candidate in ipairs(rule.enum) do
            if deep_equal(candidate, value) then
                matched = true
                break
            end
        end
        if not matched then
            return false, path .. " is not in enum"
        end
    end

    if rule.allOf then
        for _, child_rule in ipairs(rule.allOf) do
            local ok, err = validate(root, child_rule, value, path)
            if not ok then
                return false, err
            end
        end
    end
    if rule["if"] then
        local condition_matches = validate(root, rule["if"], value, path)
        local branch = condition_matches and rule["then"] or rule["else"]
        if branch then
            local ok, err = validate(root, branch, value, path)
            if not ok then
                return false, err
            end
        end
    end

    if rule.type == "object" then
        if type(value) ~= "table" or is_array(value) then
            return false, path .. " must be an object"
        end
        for _, key in ipairs(rule.required or {}) do
            if value[key] == nil then
                return false, path .. "." .. key .. " is required"
            end
        end
        for key, child in pairs(value) do
            local child_rule = rule.properties and rule.properties[key]
            if child_rule == nil then
                if rule.additionalProperties == false then
                    return false, path .. "." .. tostring(key) .. " is not allowed"
                end
            else
                local ok, err = validate(root, child_rule, child, path .. "." .. key)
                if not ok then
                    return false, err
                end
            end
        end
    elseif rule.type == "array" then
        if not is_array(value) then
            return false, path .. " must be an array"
        end
        if rule.minItems and #value < rule.minItems then
            return false, path .. " has too few items"
        end
        if rule.maxItems and #value > rule.maxItems then
            return false, path .. " has too many items"
        end
        if rule.prefixItems then
            for index, child_rule in ipairs(rule.prefixItems) do
                if value[index] ~= nil then
                    local ok, err = validate(root, child_rule, value[index], path .. "[" .. index .. "]")
                    if not ok then
                        return false, err
                    end
                end
            end
            if rule.items == false and #value > #rule.prefixItems then
                return false, path .. " has an extra tuple item"
            end
        elseif type(rule.items) == "table" then
            for index, child in ipairs(value) do
                local ok, err = validate(root, rule.items, child, path .. "[" .. index .. "]")
                if not ok then
                    return false, err
                end
            end
        end
        if rule.uniqueItems then
            for left = 1, #value do
                for right = left + 1, #value do
                    if deep_equal(value[left], value[right]) then
                        return false, path .. " contains duplicate items"
                    end
                end
            end
        end
    elseif rule.type == "string" then
        if type(value) ~= "string" then
            return false, path .. " must be a string"
        end
        if rule.minLength and #value < rule.minLength then
            return false, path .. " is too short"
        end
        if rule.maxLength and #value > rule.maxLength then
            return false, path .. " is too long"
        end
        if rule.pattern then
            assert(rule.pattern == SHA256_PATTERN, "unsupported schema pattern: " .. rule.pattern)
            if #value ~= 64 or value:match("^[0-9a-f]+$") == nil then
                return false, path .. " does not match pattern"
            end
        end
    elseif rule.type == "integer" then
        if type(value) ~= "number" or math.type(value) ~= "integer" then
            return false, path .. " must be an integer"
        end
    elseif rule.type == "number" then
        if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
            return false, path .. " must be a finite number"
        end
    elseif rule.type == "boolean" then
        if type(value) ~= "boolean" then
            return false, path .. " must be a boolean"
        end
    end

    if type(value) == "number" then
        if rule.minimum and value < rule.minimum then
            return false, path .. " is below minimum"
        end
        if rule.maximum and value > rule.maximum then
            return false, path .. " exceeds maximum"
        end
        if rule.exclusiveMinimum and value <= rule.exclusiveMinimum then
            return false, path .. " is not above exclusiveMinimum"
        end
    end
    return true
end

local function checksum(character)
    return string.rep(character or "a", 64)
end

local function client_evidence(client, character)
    return {
        client = client,
        evidence_checksum = checksum(character),
    }
end

local function required_clients()
    return {
        client_evidence("SteamWindows", "1"),
        client_evidence("PS5", "2"),
        client_evidence("Mac", "3"),
    }
end

local function valid_report()
    local report = {
        schema_version = "1.0",
        report_kind = "public_release",
        game_revision = 123456,
        deployment_profile = "windows-dedicated-ps5-macos-required",
        binding_manifest_checksum = checksum("a"),
        gate_a_checksum = checksum("b"),
        package_evidence = {
            evidence_checksum = checksum("c"),
            server_only = true,
            is_server = true,
            client_install_rule_count = 0,
            min_revision = 123456,
        },
        connectivity_evidence = {
            evidence_checksum = checksum("d"),
            public_lobby = true,
            matching_ports = true,
            required_crossplay_platforms = { "Steam", "PS5", "Mac" },
            client_mods_disabled = true,
            json_log_format = true,
        },
        migration_evidence = {
            evidence_checksum = checksum("e"),
            item_fingerprint_changes = 0,
            second_run_mutations = 0,
            after_restart_verified = true,
        },
        new_guild_evidence = {
            evidence_checksum = checksum("f"),
            trials = 20,
            first_use_failures = 0,
            tick_stalls = 0,
            live_state_cache_invalidation_verified = true,
        },
        removal_evidence = {
            evidence_checksum = checksum("4"),
            required_client_evidence = required_clients(),
            item_guid_changes = 0,
            item_quantity_changes = 0,
        },
        performance_evidence = {
            evidence_checksum = checksum("5"),
            server_environment_evidence_checksum = checksum("0"),
            server_os_family = "Windows",
            test_player_count = 32,
            world_guild_count = 100,
            world_container_count = 100,
            steady_cpu_increase_percentage_points = 1,
            memory_increase_mb = 100,
            audit_100_guilds_seconds = 5,
            migration_100_empty_guilds_seconds = 10,
            single_54_to_358_ms = 100,
            periodic_scan_interval_seconds = 60,
            save_duration_increase_percent = 15,
            chest_open_p95_increase_ms = 300,
            reconnect_duration_increase_percent = 10,
            soak_hours = 6,
            critical_errors = 0,
        },
        required_client_evidence = required_clients(),
        optional_client_evidence = json.array(),
        slot_evidence = {
            { target_slots = 54, evidence_checksum = checksum("6") },
            { target_slots = 120, evidence_checksum = checksum("7") },
            { target_slots = 256, evidence_checksum = checksum("8") },
            { target_slots = 358, evidence_checksum = checksum("9") },
        },
        release_eligible = true,
    }
    report.checksum = sha256.hex(json.encode(report))
    return report
end

local function expect_valid(schema, report)
    local ok, err = validate(schema, schema, report)
    if not ok then
        error(err, 2)
    end
end

local function expect_invalid(schema, report)
    local ok = validate(schema, schema, report)
    a.equal(false, ok)
end

describe("public release report JSON Schema", function()
    it("is a strict public-release-only self-checksummed contract", function()
        local schema = read_schema()
        a.equal("https://json-schema.org/draft/2020-12/schema", schema["$schema"])
        a.equal("object", schema.type)
        a.equal(false, schema.additionalProperties)
        a.deep_equal({
            algorithm = "SHA-256",
            canonical_json = true,
            excluded_property = "checksum",
            encoding = "lowercase-hex",
        }, schema["x-cgce-self-checksum"])
        a.equal(nil, schema.properties.certification_checksum)
        a.equal(nil, schema.properties.certification_artifact_checksum)

        expect_valid(schema, valid_report())
    end)

    it("requires Steam Windows, PS5, and Mac evidence in canonical order", function()
        local schema = read_schema()

        local missing_mac = valid_report()
        missing_mac.required_client_evidence[3] = nil
        expect_invalid(schema, missing_mac)

        local reordered = valid_report()
        reordered.required_client_evidence[1], reordered.required_client_evidence[2] =
            reordered.required_client_evidence[2], reordered.required_client_evidence[1]
        expect_invalid(schema, reordered)

        local no_removal_mac = valid_report()
        no_removal_mac.removal_evidence.required_client_evidence[3] = nil
        expect_invalid(schema, no_removal_mac)
    end)

    it("allows optional Xbox only as checksum-bound evidence", function()
        local schema = read_schema()
        local xbox = valid_report()
        xbox.optional_client_evidence = { client_evidence("Xbox", "0") }
        expect_valid(schema, xbox)

        local no_checksum = valid_report()
        no_checksum.optional_client_evidence = { { client = "Xbox" } }
        expect_invalid(schema, no_checksum)

        local optional_linux = valid_report()
        optional_linux.optional_client_evidence = { client_evidence("Linux", "0") }
        expect_invalid(schema, optional_linux)
    end)

    it("accepts only the certified slot-candidate prefix order", function()
        local schema = read_schema()

        local prefix = valid_report()
        prefix.slot_evidence[3] = nil
        prefix.slot_evidence[4] = nil
        expect_valid(schema, prefix)

        local final_only = valid_report()
        final_only.slot_evidence = {
            { target_slots = 358, evidence_checksum = checksum("9") },
        }
        expect_invalid(schema, final_only)

        local reordered = valid_report()
        reordered.slot_evidence[2], reordered.slot_evidence[3] =
            reordered.slot_evidence[3], reordered.slot_evidence[2]
        expect_invalid(schema, reordered)
    end)

    it("separates evidence validity from release eligibility while enforcing eligible thresholds", function()
        local schema = read_schema()

        local operational = valid_report()
        operational.report_kind = "operational"
        expect_invalid(schema, operational)

        local ineligible = valid_report()
        ineligible.release_eligible = false
        expect_valid(schema, ineligible)

        local uppercase = valid_report()
        uppercase.gate_a_checksum = checksum("A")
        expect_invalid(schema, uppercase)

        local over_threshold = valid_report()
        over_threshold.release_eligible = false
        over_threshold.performance_evidence.memory_increase_mb = 101
        expect_valid(schema, over_threshold)

        local falsely_eligible = valid_report()
        falsely_eligible.performance_evidence.memory_increase_mb = 101
        expect_invalid(schema, falsely_eligible)

        local critical_failure = valid_report()
        critical_failure.release_eligible = false
        critical_failure.performance_evidence.critical_errors = 1
        expect_valid(schema, critical_failure)

        local critical_but_eligible = valid_report()
        critical_but_eligible.performance_evidence.critical_errors = 1
        expect_invalid(schema, critical_but_eligible)

        local below_release_scale = {
            { field = "test_player_count", value = 31 },
            { field = "world_guild_count", value = 99 },
            { field = "world_container_count", value = 99 },
        }
        for _, case in ipairs(below_release_scale) do
            local report = valid_report()
            report.performance_evidence[case.field] = case.value
            expect_invalid(schema, report)
        end

        local small_ineligible_test = valid_report()
        small_ineligible_test.release_eligible = false
        small_ineligible_test.performance_evidence.test_player_count = 1
        small_ineligible_test.performance_evidence.world_guild_count = 1
        small_ineligible_test.performance_evidence.world_container_count = 1
        expect_valid(schema, small_ineligible_test)

        local missing_environment = valid_report()
        missing_environment.performance_evidence.server_environment_evidence_checksum = nil
        expect_invalid(schema, missing_environment)

        local non_windows = valid_report()
        non_windows.performance_evidence.server_os_family = "Linux"
        expect_invalid(schema, non_windows)

        local malformed_checksum = valid_report()
        malformed_checksum.gate_a_checksum = checksum("A")
        expect_invalid(schema, malformed_checksum)
    end)

    it("rejects reverse certification references and raw identifiers or secrets at every object boundary", function()
        local schema = read_schema()
        local injections = {
            function(report)
                report.certification_checksum = checksum("a")
            end,
            function(report)
                report.certification_artifact_checksum = checksum("a")
            end,
            function(report)
                report.world_id = "raw-world"
            end,
            function(report)
                report.required_client_evidence[1].player_id = "raw-player"
            end,
            function(report)
                report.removal_evidence.guild_id = "raw-guild"
            end,
            function(report)
                report.migration_evidence.container_id = "raw-container"
            end,
            function(report)
                report.package_evidence.password = "secret"
            end,
            function(report)
                report.connectivity_evidence.approval_token = "secret"
            end,
            function(report)
                report.connectivity_evidence.public_ip = "203.0.113.1"
            end,
            function(report)
                report.connectivity_evidence.command_line = "server -publiclobby"
            end,
        }

        for _, inject in ipairs(injections) do
            local report = valid_report()
            inject(report)
            expect_invalid(schema, report)
        end
    end)
end)
