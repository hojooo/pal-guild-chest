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

    it("requires Task 6 to invoke Task 3 restoration unconditionally", function()
        local plan = read(
            "docs/superpowers/plans/"
                .. "2026-07-23-cgce-windows-discovery-operator.md"
        )
        local conditional = "if (Test-Path -LiteralPath "
            .. "$state.paths.probe_intent -PathType Leaf)"
        a.equal(nil, plan:find(conditional, 1, true))
        a.equal(
            true,
            plan:find(
                "Restore-CgceInventoryProbe @probeRestore",
                1,
                true
            ) ~= nil
        )
        a.equal(
            true,
            plan:find(
                "proving that no Task 3 residue exists",
                1,
                true
            ) ~= nil
        )
    end)

    it("defines a fail-closed Windows prepare entry point", function()
        local source = read(
            "tools/windows-discovery/Prepare-CgceDiscovery.ps1"
        )
        for _, required in ipairs({
            "#Requires -Version 5.1",
            "#Requires -RunAsAdministrator",
            "Initialize-CgceRunLayout",
            "Assert-CgceDiscoveryDiskCapacity",
            "Write-CgceActiveRunMarker",
            "Block-CgceRunState",
            "Enable-CgceInventoryProbe",
            "'^\\s*(CGCE-OPS-[A-Z0-9-]+)(?![A-Za-z0-9-])'",
            "return $match.Groups[1].Value",
            "CGCE_WINDOWS_DISCOVERY_OK",
            "CGCE_WINDOWS_DISCOVERY_BLOCKED",
        }) do
            a.equal(true, source:find(required, 1, true) ~= nil)
        end
        for _, forbidden in ipairs({
            "ExecuteInGameThread",
            "SetPropertyValue",
            "ProcessConsoleExec",
            "TArray",
            "(?<![A-Za-z0-9-])CGCE-OPS-",
        }) do
            a.equal(nil, source:find(forbidden, 1, true))
        end
    end)
end)
