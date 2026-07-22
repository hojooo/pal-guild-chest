local a = require("tests.support.assertions")
local conflict_detector = require("CrossplayGuildChestExpander.Scripts.conflict_detector")
local json = require("CrossplayGuildChestExpander.Scripts.json")

local function descriptor(path, type_signature)
    return {
        path = path,
        type_signature = type_signature,
    }
end

local function policy(gate_a_accepted)
    return {
        policy_version = "1.0",
        verified = true,
        gate_a_accepted = gate_a_accepted == true,
        target_slots = 358,
        known_slot_counts = { 54, 120, 256, 358 },
        paths = {
            owner_package = "/CGCE/Server",
            target_default = "/Game/Exact/GuildChestDefault",
            container_resizer_hook = "/Script/Exact.Container:Resize",
            guild_chest_storage = "/Save/Exact/GuildChestStorage",
        },
        types = {
            container_class = descriptor(
                "/Script/Exact.GuildChestContainer",
                "class(/Script/Exact.GuildChestContainer)"
            ),
            slot = descriptor(
                "/Script/Exact.GuildChestSlot",
                "struct(/Script/Exact.GuildChestSlot)"
            ),
        },
    }
end

local function mod(package_name, package_version, package_path, claimed_paths)
    return {
        package_name = package_name,
        package_version = package_version,
        package_path = package_path,
        claimed_paths = claimed_paths or {},
    }
end

local function hook(function_path, owner_package_path)
    return {
        function_path = function_path,
        owner_package_path = owner_package_path,
    }
end

local function container(slot_count)
    return {
        class_path = "/Script/Exact.GuildChestContainer",
        class_type_signature = "class(/Script/Exact.GuildChestContainer)",
        slot_type_path = "/Script/Exact.GuildChestSlot",
        slot_type_signature = "struct(/Script/Exact.GuildChestSlot)",
        slot_count = slot_count or 54,
    }
end

local function expect_error(code, field, fn)
    local ok, err = pcall(fn)
    a.equal(false, ok)
    a.equal("table", type(err))
    a.equal(code, err.code)
    a.equal(field, err.field)
    a.equal("string", type(err.detail))
    return err
end

local function finding_codes(result)
    local codes = {}
    for index, finding in ipairs(result.findings) do
        codes[index] = finding.code
    end
    return codes
end

describe("conflict_detector.scan", function()
    it("keeps pre-Gate-A inventory partial and permanently non-authoritative", function()
        local result = conflict_detector.scan(policy(false), {
            mod("Zulu", "2.0.0", "/Mods/Zulu"),
            mod("Alpha", "10.0.0", "/Mods/Alpha10"),
            mod("Alpha", "2.0.0", "/Mods/Alpha2"),
        }, {}, { container(54) })

        a.equal("partial", result.coverage)
        a.equal(false, result.apply_authorized)
        a.equal(false, result.blocking)
        a.equal(false, result.forced_noop)
        a.deep_equal({
            { package_name = "Alpha", package_version = "10.0.0" },
            { package_name = "Alpha", package_version = "2.0.0" },
            { package_name = "Zulu", package_version = "2.0.0" },
        }, result.mod_inventory)
        a.deep_equal({ "CGCE-CONFLICT-COVERAGE-PARTIAL" }, finding_codes(result))
        a.equal("WARNING", result.findings[1].severity)
        a.equal(false, result.findings[1].forced_noop)
    end)

    it("reports complete collision coverage after Gate A without granting apply authority", function()
        local result = conflict_detector.scan(policy(true), {}, {}, { container(54) })

        a.equal("complete", result.coverage)
        a.equal(false, result.apply_authorized)
        a.equal(false, result.blocking)
        a.equal(false, result.forced_noop)
        a.deep_equal({}, result.findings)
        a.equal("[]", json.encode(result.findings))
        a.equal("[]", json.encode(result.mod_inventory))
    end)

    it("blocks only exact foreign target-default and storage claims", function()
        local current_policy = policy(true)
        local result = conflict_detector.scan(current_policy, {
            mod("Owner", "1", current_policy.paths.owner_package, {
                current_policy.paths.target_default,
                current_policy.paths.guild_chest_storage,
            }),
            mod("NearMatch", "1", "/Mods/NearMatch", {
                current_policy.paths.target_default .. "Extra",
                current_policy.paths.guild_chest_storage .. "Extra",
            }),
            mod("Foreign", "1", "/Mods/Foreign", {
                current_policy.paths.guild_chest_storage,
                current_policy.paths.target_default,
            }),
        }, {}, { container(54) })

        a.equal(true, result.blocking)
        a.equal(false, result.apply_authorized)
        a.deep_equal({
            "CGCE-CONFLICT-STORAGE-COLLISION",
            "CGCE-CONFLICT-TARGET-DEFAULT-COLLISION",
        }, finding_codes(result))
        for _, finding in ipairs(result.findings) do
            a.equal("BLOCKING", finding.severity)
            a.equal(false, finding.forced_noop)
            a.equal(nil, finding.detail:find("/Mods/Foreign", 1, true))
        end
    end)

    it("blocks only an exact foreign hook collision", function()
        local current_policy = policy(true)
        local result = conflict_detector.scan(current_policy, {}, {
            hook(current_policy.paths.container_resizer_hook, current_policy.paths.owner_package),
            hook(current_policy.paths.container_resizer_hook .. "Candidate", "/Mods/NearMatch"),
            hook(current_policy.paths.container_resizer_hook, "/Mods/Foreign"),
        }, { container(54) })

        a.equal(true, result.blocking)
        a.deep_equal({ "CGCE-CONFLICT-HOOK-COLLISION" }, finding_codes(result))
        a.equal("hooks[2].function_path", result.findings[1].field)
    end)

    it("blocks exact container-class and slot-type replacement evidence", function()
        local replaced_class = container(54)
        replaced_class.class_type_signature = "class(/Script/Foreign.ReplacedContainer)"
        local replaced_slot = container(54)
        replaced_slot.slot_type_path = "/Script/Foreign.ReplacedSlot"

        local result = conflict_detector.scan(policy(true), {}, {}, {
            replaced_class,
            replaced_slot,
        })

        a.equal(true, result.blocking)
        a.deep_equal({
            "CGCE-CONFLICT-CONTAINER-TYPE-REPLACED",
            "CGCE-CONFLICT-SLOT-TYPE-REPLACED",
        }, finding_codes(result))
        a.equal("containers[2].class_type_signature", result.findings[1].field)
        a.equal("containers[1].slot_type_path", result.findings[2].field)
    end)

    it("blocks an unknown count below target and forces no-op for one above target", function()
        local result = conflict_detector.scan(policy(true), {}, {}, {
            container(54),
            container(100),
            container(400),
        })

        a.equal(true, result.blocking)
        a.equal(true, result.forced_noop)
        a.deep_equal({
            "CGCE-CONFLICT-UNKNOWN-COUNT-ABOVE-TARGET",
            "CGCE-CONFLICT-UNKNOWN-COUNT-BELOW-TARGET",
        }, finding_codes(result))
        a.equal("WARNING", result.findings[1].severity)
        a.equal(true, result.findings[1].forced_noop)
        a.equal("BLOCKING", result.findings[2].severity)
        a.equal(false, result.findings[2].forced_noop)
    end)

    it("requires a verified strict plain-table policy and strict record keys", function()
        local unverified = policy(true)
        unverified.verified = false
        expect_error("CGCE-CONFLICT-POLICY-UNVERIFIED", "policy.verified", function()
            conflict_detector.scan(unverified, {}, {}, {})
        end)

        local unknown = policy(true)
        unknown.z_unknown = true
        unknown.a_unknown = true
        expect_error("CGCE-CONFLICT-UNKNOWN-KEY", "policy.a_unknown", function()
            conflict_detector.scan(unknown, {}, {}, {})
        end)

        local metatable_policy = setmetatable(policy(true), {})
        expect_error("CGCE-CONFLICT-TYPE", "policy", function()
            conflict_detector.scan(metatable_policy, {}, {}, {})
        end)

        local malformed_mod = mod("Foreign", "1", "/Mods/Foreign")
        malformed_mod.approval_token = "do-not-leak-this-value"
        local err = expect_error("CGCE-CONFLICT-UNKNOWN-KEY", "mods[1].approval_token", function()
            conflict_detector.scan(policy(true), { malformed_mod }, {}, {})
        end)
        a.equal(nil, err.detail:find("do-not-leak-this-value", 1, true))

        local non_string_key = policy(true)
        non_string_key[{}] = true
        expect_error("CGCE-CONFLICT-UNKNOWN-KEY", "policy[invalid-key]", function()
            conflict_detector.scan(non_string_key, {}, {}, {})
        end)
    end)

    it("rejects fuzzy paths, fuzzy type signatures, and sparse input arrays", function()
        local fuzzy_path = policy(true)
        fuzzy_path.paths.guild_chest_storage = "/Save/Exact/*"
        expect_error("CGCE-CONFLICT-PATH-NOT-EXACT", "policy.paths.guild_chest_storage", function()
            conflict_detector.scan(fuzzy_path, {}, {}, {})
        end)

        local fuzzy_type = policy(true)
        fuzzy_type.types.slot.type_signature = "struct(*)"
        expect_error("CGCE-CONFLICT-TYPE-NOT-EXACT", "policy.types.slot.type_signature", function()
            conflict_detector.scan(fuzzy_type, {}, {}, {})
        end)

        local ellipsis_path = policy(true)
        ellipsis_path.paths.guild_chest_storage = "/Save/Exact/..."
        expect_error("CGCE-CONFLICT-PATH-NOT-EXACT", "policy.paths.guild_chest_storage", function()
            conflict_detector.scan(ellipsis_path, {}, {}, {})
        end)

        local ellipsis_type = policy(true)
        ellipsis_type.types.slot.type_signature = "struct(...)"
        expect_error("CGCE-CONFLICT-TYPE-NOT-EXACT", "policy.types.slot.type_signature", function()
            conflict_detector.scan(ellipsis_type, {}, {}, {})
        end)

        local sparse_mods = {
            [1] = mod("One", "1", "/Mods/One"),
            [3] = mod("Three", "1", "/Mods/Three"),
        }
        expect_error("CGCE-CONFLICT-TYPE", "mods", function()
            conflict_detector.scan(policy(true), sparse_mods, {}, {})
        end)
    end)

    it("rejects invalid UTF-8 before strings can enter canonical diagnostics", function()
        local malformed_mod = mod("Foreign\255", "1", "/Mods/Foreign")
        expect_error("CGCE-CONFLICT-VALUE", "mods[1].package_name", function()
            conflict_detector.scan(policy(true), { malformed_mod }, {}, {})
        end)

        local malformed_policy = policy(true)
        malformed_policy.types.slot.type_signature = "struct(\255)"
        expect_error("CGCE-CONFLICT-VALUE", "policy.types.slot.type_signature", function()
            conflict_detector.scan(malformed_policy, {}, {}, {})
        end)
    end)

    it("treats a pointer marker inside an otherwise exact reflected signature as literal", function()
        local pointer_policy = policy(true)
        pointer_policy.types.container_class.type_signature = "class(UObject*)"
        local matching = container(54)
        matching.class_type_signature = "class(UObject*)"

        local result = conflict_detector.scan(pointer_policy, {}, {}, { matching })
        a.equal(false, result.blocking)
        a.deep_equal({}, result.findings)
    end)

    it("captures canonical JSON helpers before public sibling slots can be shadowed", function()
        local original_encode = json.encode
        local original_array = json.array
        json.encode = function()
            error("shadowed json.encode must not be reached")
        end
        json.array = function()
            return { shadowed = true }
        end

        local ok, result = pcall(conflict_detector.scan, policy(true), {}, {}, { container(54) })
        json.encode = original_encode
        json.array = original_array

        a.equal(true, ok)
        a.equal("[]", original_encode(result.findings))
        a.equal("[]", original_encode(result.mod_inventory))
    end)

    it("canonicalizes detached mods and claimed paths before deriving finding indexes", function()
        local current_policy = policy(true)
        local first_claims = {
            current_policy.paths.target_default,
            current_policy.paths.guild_chest_storage,
        }
        local first = mod("Zulu", "2", "/Mods/Zulu", first_claims)
        local duplicate_one = mod("Alpha", "1", "/Mods/Alpha", {
            current_policy.paths.guild_chest_storage,
        })
        local duplicate_two = mod("Alpha", "1", "/Mods/Alpha", {
            current_policy.paths.guild_chest_storage,
        })
        local original_claims = json.encode(first_claims)

        local forward = conflict_detector.scan(current_policy, {
            first,
            duplicate_one,
            duplicate_two,
        }, {}, { container(54) })
        a.equal(original_claims, json.encode(first_claims))

        local reverse = conflict_detector.scan(current_policy, {
            mod("Alpha", "1", "/Mods/Alpha", {
                current_policy.paths.guild_chest_storage,
            }),
            mod("Zulu", "2", "/Mods/Zulu", {
                current_policy.paths.guild_chest_storage,
                current_policy.paths.target_default,
            }),
            mod("Alpha", "1", "/Mods/Alpha", {
                current_policy.paths.guild_chest_storage,
            }),
        }, {}, { container(54) })

        a.equal(json.encode(forward), json.encode(reverse))
    end)

    it("canonicalizes detached hooks before deriving finding indexes", function()
        local current_policy = policy(true)
        local near = hook(current_policy.paths.container_resizer_hook .. "Candidate", "/Mods/Near")
        local owner = hook(current_policy.paths.container_resizer_hook, current_policy.paths.owner_package)
        local foreign_one = hook(current_policy.paths.container_resizer_hook, "/Mods/Foreign")
        local foreign_two = hook(current_policy.paths.container_resizer_hook, "/Mods/Foreign")
        local forward_input = { near, foreign_one, owner, foreign_two }

        local forward = conflict_detector.scan(current_policy, {}, forward_input, { container(54) })
        a.equal(near, forward_input[1])
        a.equal(foreign_one, forward_input[2])

        local reverse = conflict_detector.scan(current_policy, {}, {
            hook(current_policy.paths.container_resizer_hook, "/Mods/Foreign"),
            hook(current_policy.paths.container_resizer_hook, current_policy.paths.owner_package),
            hook(current_policy.paths.container_resizer_hook, "/Mods/Foreign"),
            hook(current_policy.paths.container_resizer_hook .. "Candidate", "/Mods/Near"),
        }, { container(54) })

        a.equal(json.encode(forward), json.encode(reverse))
    end)

    it("canonicalizes detached containers before deriving finding indexes", function()
        local current_policy = policy(true)
        local class_replaced = container(54)
        class_replaced.class_type_signature = "class(/Script/Foreign.ReplacedContainer)"
        local slot_replaced = container(54)
        slot_replaced.slot_type_path = "/Script/Foreign.ReplacedSlot"
        local below = container(100)
        local above_one = container(400)
        local above_two = container(400)
        local forward_input = {
            class_replaced,
            above_one,
            slot_replaced,
            below,
            above_two,
        }

        local forward = conflict_detector.scan(current_policy, {}, {}, forward_input)
        a.equal(class_replaced, forward_input[1])
        a.equal(above_one, forward_input[2])

        local reverse_class = container(54)
        reverse_class.class_type_signature = "class(/Script/Foreign.ReplacedContainer)"
        local reverse_slot = container(54)
        reverse_slot.slot_type_path = "/Script/Foreign.ReplacedSlot"
        local reverse = conflict_detector.scan(current_policy, {}, {}, {
            container(400),
            container(100),
            reverse_slot,
            container(400),
            reverse_class,
        })

        a.equal(json.encode(forward), json.encode(reverse))
        for _, finding in ipairs(forward.findings) do
            a.equal(nil, finding.detail:find("/Script/", 1, true))
            a.equal(nil, finding.detail:find("/Save/", 1, true))
            a.equal(nil, finding.detail:find("/Mods/", 1, true))
        end
    end)
end)
