local a = require("tests.support.assertions")

local function read(path)
    local file = assert(io.open(path, "rb"))
    local content = file:read("*a")
    file:close()
    return content
end

describe("Windows discovery handoff", function()
    it("keeps the inventory probe isolated to the two UE4SS dumpers", function()
        local source = read(
            "tools/windows-discovery/probe/"
                .. "CGCEDiscoveryInventory/scripts/main.lua"
        )
        local expected = [[local function run_dumper(name, fn)
    local ok = pcall(fn)
    if not ok then
        print("CGCE_INVENTORY_BLOCKED " .. name)
        return false
    end
    print("CGCE_INVENTORY_COMPLETE " .. name)
    return true
end

local objects_ok = run_dumper("OBJECTS", function()
    DumpAllObjects()
end)
local sdk_ok = run_dumper("CXX_HEADERS", function()
    GenerateSDK()
end)

if objects_ok and sdk_ok then
    print("CGCE_INVENTORY_COMPLETE ALL")
else
    print("CGCE_INVENTORY_BLOCKED ALL")
end
]]

        a.equal(expected, source)
        a.equal(true, source:find("DumpAllObjects()", 1, true) ~= nil)
        a.equal(true, source:find("GenerateSDK()", 1, true) ~= nil)

        for _, forbidden in ipairs({
            "require",
            "StaticFindObject",
            "FindAllOf",
            "RegisterHook",
            "ExecuteInGameThread",
            "SetPropertyValue",
            "ProcessConsoleExec",
            "TArray",
            "resize",
            "append",
        }) do
            a.equal(nil, source:find(forbidden, 1, true))
        end
    end)
end)
