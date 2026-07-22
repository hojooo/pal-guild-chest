local a = require("tests.support.assertions")
local certification = require("CrossplayGuildChestExpander.Scripts.certification")
local config = require("CrossplayGuildChestExpander.Scripts.config")
local json = require("CrossplayGuildChestExpander.Scripts.json")
local sha256 = require("CrossplayGuildChestExpander.Scripts.sha256")

local REVISION = 123456
local PROFILE = "windows-dedicated-ps5-macos-required"

local function common_evidence()
    return {
        ui_access = true,
        last_slot_access = true,
        restart_reconnect = true,
        cross_platform_consistency = true,
    }
end

local function slot_evidence(target_slots)
    local ps5 = common_evidence()
    ps5.community_server_list = true
    ps5.dualsense_last_slot = true
    return {
        target_slots = target_slots,
        evidence = {
            SteamWindows = common_evidence(),
            PS5 = ps5,
            Mac = common_evidence(),
        },
    }
end

local function artifact(slots)
    local value = {
        certification_version = "1.0",
        game_revision = REVISION,
        deployment_profile = PROFILE,
        binding_manifest_checksum = string.rep("a", 64),
        gate_a_checksum = string.rep("b", 64),
        release_report_checksum = string.rep("c", 64),
        required_clients = { "SteamWindows", "PS5", "Mac" },
        slots = {},
    }
    for index, target_slots in ipairs(slots or { 54 }) do
        value.slots[index] = slot_evidence(target_slots)
    end
    value.checksum = sha256.hex(json.encode(value))
    return value
end

local function refresh_checksum(value)
    value.checksum = nil
    value.checksum = sha256.hex(json.encode(value))
    return value
end

local function expect_error(code, field, fn)
    local ok, err = pcall(fn)
    a.equal(false, ok)
    a.equal("table", type(err))
    a.equal(code, err.code)
    a.equal(field, err.field)
    a.equal("string", type(err.detail))
end

describe("certification.verify", function()
    it("returns only slots authorized by an exactly pinned release artifact", function()
        local release_artifact = artifact({ 54, 120, 358 })
        local certified = certification.verify(release_artifact, release_artifact.checksum, REVISION, PROFILE)
        a.deep_equal({ 54, 120, 358 }, certified)
    end)

    it("binds authorization to exact live revision and deployment profile", function()
        local release_artifact = artifact()
        expect_error("CGCE-CERT-REVISION", "game_revision", function()
            certification.verify(release_artifact, release_artifact.checksum, REVISION + 1, PROFILE)
        end)
        expect_error("CGCE-CERT-PROFILE", "deployment_profile", function()
            certification.verify(release_artifact, release_artifact.checksum, REVISION, "other-profile")
        end)
    end)

    it("requires exact binding, Gate A, and release report checksum bindings", function()
        for _, field in ipairs({ "binding_manifest_checksum", "gate_a_checksum", "release_report_checksum" }) do
            local release_artifact = artifact()
            release_artifact[field] = "not-a-checksum"
            refresh_checksum(release_artifact)
            expect_error("CGCE-CERT-BOUND-CHECKSUM", field, function()
                certification.verify(release_artifact, release_artifact.checksum, REVISION, PROFILE)
            end)
        end
    end)

    it("requires the canonical ordered Steam Windows, PS5, and Mac client set", function()
        local release_artifact = artifact()
        release_artifact.required_clients = { "SteamWindows", "Mac", "PS5" }
        refresh_checksum(release_artifact)
        expect_error("CGCE-CERT-REQUIRED-CLIENTS", "required_clients", function()
            certification.verify(release_artifact, release_artifact.checksum, REVISION, PROFILE)
        end)
    end)

    it("requires exactly one all-true evidence record for every required client", function()
        local missing_mac = artifact()
        missing_mac.slots[1].evidence.Mac = nil
        refresh_checksum(missing_mac)
        expect_error("CGCE-CERT-CLIENT-EVIDENCE", "slots[1].evidence.Mac", function()
            certification.verify(missing_mac, missing_mac.checksum, REVISION, PROFILE)
        end)

        local failed_check = artifact()
        failed_check.slots[1].evidence.SteamWindows.restart_reconnect = false
        refresh_checksum(failed_check)
        expect_error("CGCE-CERT-EVIDENCE-NOT-PASSED", "slots[1].evidence.SteamWindows.restart_reconnect", function()
            certification.verify(failed_check, failed_check.checksum, REVISION, PROFILE)
        end)

        local missing_check = artifact()
        missing_check.slots[1].evidence.Mac.last_slot_access = nil
        refresh_checksum(missing_check)
        expect_error("CGCE-CERT-EVIDENCE-MISSING", "slots[1].evidence.Mac.last_slot_access", function()
            certification.verify(missing_check, missing_check.checksum, REVISION, PROFILE)
        end)

        local unknown_check = artifact()
        unknown_check.slots[1].evidence.Mac.unreviewed_claim = true
        refresh_checksum(unknown_check)
        expect_error("CGCE-CERT-EVIDENCE-UNKNOWN", "slots[1].evidence.Mac.unreviewed_claim", function()
            certification.verify(unknown_check, unknown_check.checksum, REVISION, PROFILE)
        end)

        local unexpected_client = artifact()
        unexpected_client.slots[1].evidence.Xbox = common_evidence()
        refresh_checksum(unexpected_client)
        expect_error("CGCE-CERT-CLIENT-EVIDENCE", "slots[1].evidence.Xbox", function()
            certification.verify(unexpected_client, unexpected_client.checksum, REVISION, PROFILE)
        end)
    end)

    it("requires PS5 Community Server list and DualSense last-slot evidence", function()
        local no_community = artifact()
        no_community.slots[1].evidence.PS5.community_server_list = nil
        refresh_checksum(no_community)
        expect_error("CGCE-CERT-PS5-COMMUNITY", "slots[1].evidence.PS5.community_server_list", function()
            certification.verify(no_community, no_community.checksum, REVISION, PROFILE)
        end)

        local no_dualsense = artifact()
        no_dualsense.slots[1].evidence.PS5.dualsense_last_slot = false
        refresh_checksum(no_dualsense)
        expect_error("CGCE-CERT-PS5-DUALSENSE", "slots[1].evidence.PS5.dualsense_last_slot", function()
            certification.verify(no_dualsense, no_dualsense.checksum, REVISION, PROFILE)
        end)
    end)

    it("rejects absent or different release-build checksum pins", function()
        local release_artifact = artifact()
        expect_error("CGCE-CERT-PIN", "checksum", function()
            certification.verify(release_artifact, nil, REVISION, PROFILE)
        end)
        expect_error("CGCE-CERT-PIN", "checksum", function()
            certification.verify(release_artifact, string.rep("d", 64), REVISION, PROFILE)
        end)
    end)

    it("rejects artifact drift using its canonical self-checksum", function()
        local release_artifact = artifact()
        local pinned_checksum = release_artifact.checksum
        release_artifact.slots[1].evidence.Mac.ui_access = false

        expect_error("CGCE-CERT-CHECKSUM", "checksum", function()
            certification.verify(release_artifact, pinned_checksum, REVISION, PROFILE)
        end)
    end)

    it("does not let config-only slot escalation authorize production", function()
        local configured = {
            config_version = "1.1",
            deployment_profile = PROFILE,
            mode = "audit",
            requested_target_slots = 358,
            certified_target_slots = { 54, 358 },
            certification_mode = false,
            required_clients = { "SteamWindows", "PS5", "Mac" },
            optional_clients = { "Xbox" },
            expand_only = true,
            require_operator_approval = true,
            approval_token = "",
            fail_fast = true,
            include_guild_ids = json.decode("[]"),
            exclude_guild_ids = json.decode("[]"),
            new_guild_hook_enabled = true,
            fallback_rescan_enabled = true,
            fallback_rescan_seconds = 60,
            verify_on_startup = true,
            write_migration_ledger = true,
            log_level = "INFO",
            structured_log = true,
        }
        local parsed_config = config.parse(json.encode(configured))
        a.deep_equal({ 54, 358 }, parsed_config.certified_target_slots)

        local release_artifact = artifact({ 54 })
        local certified = certification.verify(release_artifact, release_artifact.checksum, REVISION, PROFILE)
        a.deep_equal({ 54 }, certified)
    end)

    it("rejects unknown authorization fields including MinRevision", function()
        local release_artifact = artifact()
        release_artifact.MinRevision = 1
        refresh_checksum(release_artifact)
        expect_error("CGCE-CERT-UNKNOWN-KEY", "MinRevision", function()
            certification.verify(release_artifact, release_artifact.checksum, REVISION, PROFILE)
        end)
    end)
end)
