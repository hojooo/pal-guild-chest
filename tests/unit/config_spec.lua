local a = require("tests.support.assertions")
local config = require("CrossplayGuildChestExpander.Scripts.config")
local constants = require("CrossplayGuildChestExpander.Scripts.constants")
local json = require("CrossplayGuildChestExpander.Scripts.json")

local function read_file(path)
    local file = assert(io.open(path, "rb"))
    local text = assert(file:read("*a"))
    file:close()
    return text
end

local function valid_config(overrides)
    local empty_array = json.decode("[]")
    local value = {
        config_version = "1.1",
        deployment_profile = "windows-dedicated-ps5-macos-required",
        mode = "audit",
        requested_target_slots = 54,
        certified_target_slots = { 54 },
        certification_mode = false,
        required_clients = { "SteamWindows", "PS5", "Mac" },
        optional_clients = { "Xbox" },
        expand_only = true,
        require_operator_approval = true,
        approval_token = "",
        fail_fast = true,
        include_guild_ids = empty_array,
        exclude_guild_ids = json.decode("[]"),
        new_guild_hook_enabled = true,
        fallback_rescan_enabled = true,
        fallback_rescan_seconds = 60,
        verify_on_startup = true,
        write_migration_ledger = true,
        log_level = "INFO",
        structured_log = true,
    }

    for key, item in pairs(overrides or {}) do
        value[key] = item
    end
    return value
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

describe("config.parse", function()
    it("parses the exact safe default", function()
        local text = read_file("CrossplayGuildChestExpander/config/config.default.json")
        local parsed = config.parse(text)

        a.deep_equal(valid_config(), parsed)
        a.equal("audit", parsed.mode)
        a.deep_equal({ "SteamWindows", "PS5", "Mac" }, parsed.required_clients)
        a.deep_equal({ 54 }, parsed.certified_target_slots)
    end)

    it("defines immutable product constants without a Discovery Build certification pin", function()
        a.deep_equal({ config = "1.1", manifest = "1.0", certification = "1.0" }, constants.versions)
        a.equal("windows-dedicated-ps5-macos-required", constants.deployment_profile)
        a.deep_equal({ "SteamWindows", "PS5", "Mac" }, constants.required_clients)
        a.deep_equal({ "Xbox" }, constants.optional_clients)
        a.deep_equal({ 54, 120, 256, 358 }, constants.target_slot_candidates)
        a.equal(nil, constants.release_certification_checksum)
    end)

    it("rejects unknown and missing keys", function()
        local unknown = valid_config({ oops = 1 })
        expect_error("CGCE-CFG-UNKNOWN-KEY", "oops", function()
            config.parse(json.encode(unknown))
        end)

        local missing = valid_config()
        missing.structured_log = nil
        expect_error("CGCE-CFG-MISSING-KEY", "structured_log", function()
            config.parse(json.encode(missing))
        end)
    end)

    it("requires an object root and preserves object-versus-array types", function()
        expect_error("CGCE-CFG-TYPE", nil, function()
            config.parse("[]")
        end)
        expect_error("CGCE-CFG-TYPE", "include_guild_ids", function()
            config.parse(json.encode(valid_config({ include_guild_ids = {} })))
        end)
    end)

    it("locks the version, deployment profile, and required client order", function()
        expect_error("CGCE-CFG-VERSION", "config_version", function()
            config.parse(json.encode(valid_config({ config_version = 1.1 })))
        end)
        expect_error("CGCE-CFG-PROFILE", "deployment_profile", function()
            config.parse(json.encode(valid_config({ deployment_profile = "other" })))
        end)
        expect_error("CGCE-CFG-REQUIRED-CLIENTS", "required_clients", function()
            config.parse(json.encode(valid_config({ required_clients = { "PS5", "SteamWindows", "Mac" } })))
        end)
        expect_error("CGCE-CFG-REQUIRED-CLIENTS", "required_clients", function()
            config.parse(json.encode(valid_config({ required_clients = { "SteamWindows", "PS5" } })))
        end)
    end)

    it("accepts only a unique optional Xbox subset without coercion", function()
        a.deep_equal({}, config.parse(json.encode(valid_config({ optional_clients = json.decode("[]") }))).optional_clients)
        expect_error("CGCE-CFG-OPTIONAL-CLIENTS", "optional_clients", function()
            config.parse(json.encode(valid_config({ optional_clients = { "Xbox", "Xbox" } })))
        end)
        expect_error("CGCE-CFG-OPTIONAL-CLIENTS", "optional_clients", function()
            config.parse(json.encode(valid_config({ optional_clients = { "SteamWindows" } })))
        end)
        expect_error("CGCE-CFG-TYPE", "fallback_rescan_seconds", function()
            config.parse(json.encode(valid_config({ fallback_rescan_seconds = "60" })))
        end)
    end)

    it("validates opaque non-empty UTF-8 guild IDs and disjoint unique filters", function()
        local parsed = config.parse(json.encode(valid_config({
            include_guild_ids = { "guild/한글", " " },
            exclude_guild_ids = { "Guild-A" },
        })))
        a.deep_equal({ "guild/한글", " " }, parsed.include_guild_ids)

        expect_error("CGCE-CFG-GUILD-ID", "include_guild_ids", function()
            config.parse(json.encode(valid_config({ include_guild_ids = { "" } })))
        end)
        expect_error("CGCE-CFG-DUPLICATE", "include_guild_ids", function()
            config.parse(json.encode(valid_config({ include_guild_ids = { "same", "same" } })))
        end)
        expect_error("CGCE-CFG-GUILD-OVERLAP", "include_guild_ids", function()
            config.parse(json.encode(valid_config({
                include_guild_ids = { "same" },
                exclude_guild_ids = { "same" },
            })))
        end)
    end)

    it("enforces the minimum fallback interval and expand-only lock", function()
        expect_error("CGCE-CFG-RESCAN", "fallback_rescan_seconds", function()
            config.parse(json.encode(valid_config({ fallback_rescan_seconds = 29 })))
        end)
        expect_error("CGCE-CFG-EXPAND-ONLY", "expand_only", function()
            config.parse(json.encode(valid_config({ expand_only = false })))
        end)
    end)

    it("accepts only unique ascending slot candidates and enforces the local production restriction", function()
        local parsed = config.parse(json.encode(valid_config({
            requested_target_slots = 358,
            certified_target_slots = { 54, 358 },
        })))
        a.deep_equal({ 54, 358 }, parsed.certified_target_slots)
        a.equal(nil, parsed.production_authorized_slots)

        expect_error("CGCE-CFG-TARGET-CANDIDATE", "requested_target_slots", function()
            config.parse(json.encode(valid_config({ requested_target_slots = 55 })))
        end)
        expect_error("CGCE-CFG-CERTIFIED-TARGETS", "certified_target_slots", function()
            config.parse(json.encode(valid_config({ certified_target_slots = { 120, 54 } })))
        end)
        expect_error("CGCE-CFG-CERTIFIED-TARGETS", "certified_target_slots", function()
            config.parse(json.encode(valid_config({ certified_target_slots = { 54, 54 } })))
        end)
        expect_error("CGCE-CFG-LOCAL-CERTIFICATION", "requested_target_slots", function()
            config.parse(json.encode(valid_config({ requested_target_slots = 358 })))
        end)
    end)

    it("allows certification-mode candidates but grants no mutation authority", function()
        local parsed = config.parse(json.encode(valid_config({
            requested_target_slots = 358,
            certification_mode = true,
            approval_token = "test-world-approval",
        })))

        a.equal(358, parsed.requested_target_slots)
        a.equal(true, parsed.certification_mode)
        a.equal(nil, parsed.mutation_authority)
        a.equal(nil, parsed.production_authorized_slots)
    end)

    it("defers an empty apply approval token to audit orchestration without granting authority", function()
        local parsed = config.parse(json.encode(valid_config({
            mode = "apply",
            require_operator_approval = true,
            approval_token = "",
        })))

        a.equal("apply", parsed.mode)
        a.equal("", parsed.approval_token)
        a.equal(nil, parsed.mutation_authority)
        a.equal(nil, parsed.certification_authority)
        a.equal(nil, parsed.production_authorized_slots)
    end)

    it("type-checks approval tokens without copying token values into diagnostics", function()
        expect_error("CGCE-CFG-TYPE", "approval_token", function()
            config.parse(json.encode(valid_config({ mode = "apply", approval_token = 42 })))
        end)

        local ok, mode_err = pcall(config.parse, json.encode(valid_config({
            mode = "invalid",
            approval_token = "never-copy-this-token",
        })))
        a.equal(false, ok)
        a.equal(false, mode_err.detail:find("never-copy-this-token", 1, true) ~= nil)

        local parsed = config.parse(json.encode(valid_config({ mode = "apply", approval_token = "approval-value" })))
        a.equal("approval-value", parsed.approval_token)
    end)
end)
