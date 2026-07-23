local json = require("CrossplayGuildChestExpander.Scripts.json")
local sha256 = require("CrossplayGuildChestExpander.Scripts.sha256")

local fingerprint = {}
local json_array = json.array
local json_encode = json.encode
local sha256_hex = sha256.hex

function fingerprint.compute(occupied_records)
    return sha256_hex(json_encode({
        schema = "cgce.item-fingerprint.v1",
        items = json_array(occupied_records),
    }))
end

return fingerprint
