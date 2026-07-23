local a = require("tests.support.assertions")
local fingerprint = require("CrossplayGuildChestExpander.Scripts.fingerprint")
local json = require("CrossplayGuildChestExpander.Scripts.json")
local sha256 = require("CrossplayGuildChestExpander.Scripts.sha256")

describe("fingerprint.compute", function()
    it("captures canonical JSON and SHA dependencies at module load", function()
        local occupied = {
            {
                index = 1,
                empty = false,
                static_id = "Synthetic\nItem",
                dynamic_guid = "synthetic\tguid",
                quantity = 2,
                durability = "12.500000",
                instance_metadata_hash = string.rep("a", 64),
            },
        }
        local compute = fingerprint.compute
        local expected = compute(occupied)
        local original_array = json.array
        local original_encode = json.encode
        local original_sha = sha256.hex

        json.array = function() error("public json.array slot was used") end
        json.encode = function() error("public json.encode slot was used") end
        sha256.hex = function() error("public sha256.hex slot was used") end

        local ok, actual = pcall(compute, occupied)

        json.array = original_array
        json.encode = original_encode
        sha256.hex = original_sha

        if not ok then
            error(actual)
        end
        a.equal(expected, actual)
    end)
end)
