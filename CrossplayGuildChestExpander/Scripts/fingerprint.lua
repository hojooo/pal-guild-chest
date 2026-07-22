local json = require("CrossplayGuildChestExpander.Scripts.json")
local sha256 = require("CrossplayGuildChestExpander.Scripts.sha256")

local fingerprint = {}

function fingerprint.compute(occupied_records)
    return sha256.hex(json.encode({
        schema = "cgce.item-fingerprint.v1",
        items = json.array(occupied_records),
    }))
end

return fingerprint
