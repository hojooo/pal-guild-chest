local a = require("tests.support.assertions")
local approval = require("CrossplayGuildChestExpander.Scripts.approval")
local sha256 = require("CrossplayGuildChestExpander.Scripts.sha256")

local FIXED_PROFILE = "windows-dedicated-ps5-macos-required"
local FIXED_TOKEN = "36a4cf7f20cb58e92ba1072b95a4b9c9986cd6f746ac580d77a44199e1b9ab76"

local function fields(overrides)
    local value = {
        world_id = "world/alpha",
        game_revision = 12345,
        audit_checksum = string.rep("a", 64),
        requested_target_slots = 358,
        deployment_profile = FIXED_PROFILE,
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

describe("approval", function()
    it("matches the independently verified canonical fixed vector", function()
        a.equal(FIXED_TOKEN, approval.token(fields()))
        a.equal(true, approval.verify(fields(), FIXED_TOKEN))
    end)

    it("binds the token to every exact canonical field", function()
        local changes = {
            { world_id = "world/beta" },
            { game_revision = 12346 },
            { audit_checksum = string.rep("b", 64) },
            { requested_target_slots = 256 },
            { deployment_profile = "other-profile" },
        }

        for _, change in ipairs(changes) do
            a.equal(false, approval.verify(fields(change), FIXED_TOKEN))
        end

        a.equal(false, approval.verify(fields({
            audit_checksum = string.rep("c", 64),
        }), FIXED_TOKEN))
        a.equal(false, approval.verify(fields({
            timestamp = "2026-07-22T00:00:00Z",
        }), FIXED_TOKEN))
        a.equal(false, approval.verify(fields({
            require_operator_approval = false,
        }), FIXED_TOKEN))
    end)

    it("accepts exactly the five validated approval fields", function()
        local missing = fields()
        missing.world_id = nil
        expect_error("CGCE-APP-MISSING-FIELD", "world_id", function()
            approval.token(missing)
        end)

        local unknown = fields({ approval_token = "never-echo-this-token" })
        local err = expect_error("CGCE-APP-UNKNOWN-FIELD", "approval_token", function()
            approval.token(unknown)
        end)
        a.equal(false, err.detail:find("never-echo-this-token", 1, true) ~= nil)

        expect_error("CGCE-APP-WORLD-ID", "world_id", function()
            approval.token(fields({ world_id = "" }))
        end)
        expect_error("CGCE-APP-WORLD-ID", "world_id", function()
            approval.token(fields({ world_id = string.char(0xC0, 0xAF) }))
        end)
        expect_error("CGCE-APP-REVISION", "game_revision", function()
            approval.token(fields({ game_revision = 0 }))
        end)
        expect_error("CGCE-APP-REVISION", "game_revision", function()
            approval.token(fields({ game_revision = 1.5 }))
        end)
        expect_error("CGCE-APP-REVISION", "game_revision", function()
            approval.token(fields({ game_revision = "12345" }))
        end)
        expect_error("CGCE-APP-AUDIT-CHECKSUM", "audit_checksum", function()
            approval.token(fields({ audit_checksum = string.rep("A", 64) }))
        end)
        expect_error("CGCE-APP-AUDIT-CHECKSUM", "audit_checksum", function()
            approval.token(fields({ audit_checksum = string.rep("a", 63) }))
        end)
        expect_error("CGCE-APP-TARGET", "requested_target_slots", function()
            approval.token(fields({ requested_target_slots = 55 }))
        end)
        expect_error("CGCE-APP-TARGET", "requested_target_slots", function()
            approval.token(fields({ requested_target_slots = "358" }))
        end)
        expect_error("CGCE-APP-PROFILE", "deployment_profile", function()
            approval.token(fields({ deployment_profile = "other-profile" }))
        end)
    end)

    it("reports unknown fields deterministically without rendering non-string keys", function()
        expect_error("CGCE-APP-UNKNOWN-FIELD", "a_unknown", function()
            approval.token(fields({
                z_unknown = true,
                a_unknown = true,
            }))
        end)

        local non_string = fields({ z_unknown = true })
        non_string[{}] = true
        local err = expect_error("CGCE-APP-UNKNOWN-FIELD", "<non-string>", function()
            approval.token(non_string)
        end)
        a.equal(false, err.detail:find("table:", 1, true) ~= nil)
    end)

    it("returns false for malformed candidates without exposing them", function()
        local malformed = {
            false,
            123,
            "",
            string.rep("a", 63),
            string.rep("A", 64),
            string.rep("g", 64),
            string.rep("0", 64),
        }

        for _, candidate in ipairs(malformed) do
            local ok, result = pcall(approval.verify, fields(), candidate)
            a.equal(true, ok)
            a.equal(false, result)
        end

        a.equal(false, approval.verify(fields({ world_id = "" }), FIXED_TOKEN))
    end)

    it("keeps verification independent from mutable public module slots", function()
        local original_approval_token = approval.token
        local original_sha256_hex = sha256.hex
        approval.token = function()
            return FIXED_TOKEN
        end
        sha256.hex = function()
            return FIXED_TOKEN
        end

        local changed_result = approval.verify(fields({ world_id = "world/beta" }), FIXED_TOKEN)
        local original_result = approval.verify(fields(), FIXED_TOKEN)

        approval.token = original_approval_token
        sha256.hex = original_sha256_hex

        a.equal(false, changed_result)
        a.equal(true, original_result)
    end)
end)
