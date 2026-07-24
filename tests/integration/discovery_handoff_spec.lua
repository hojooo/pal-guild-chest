local a = require("tests.support.assertions")
local json = require("CrossplayGuildChestExpander.Scripts.json")

local function read(path)
    local file = assert(io.open(path, "rb"))
    local content = file:read("*a")
    file:close()
    return content
end

local function assert_fixed_length(value, length, pattern)
    a.equal(length, value.minLength)
    a.equal(length, value.maxLength)
    a.equal(pattern, value.pattern)
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
            "Assert-CgceBootstrapTree",
            "Assert-CgceBootstrapLeaf",
            "Import-CgceVerifiedBootstrapModule",
            "$state.source_manifest_checksum = $sourceManifestChecksum",
            "Initialize-CgceRunLayout",
            "Assert-CgceDiscoveryDiskCapacity",
            "Write-CgceActiveRunMarker",
            "Block-CgceRunState",
            "Enable-CgceInventoryProbe",
            "Invoke-CgceSafeBlockAttempt",
            "Close-CgcePrepareLock",
            "Assert-CgceNoReparseInPath -Path $ServerExecutable",
            "Assert-CgceNoReparseInPath -Path $paths.ue4ss_dll",
            "'^r-[0-9a-f]{32}\\z'",
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

        local files = read(
            "tools/windows-discovery/modules/CgceDiscovery.Files.psm1"
        )
        for _, required in ipairs({
            ".cgce-stage-layout-",
            '"before-claim"',
            "Assert-CgceExactPublishedRunLayout",
        }) do
            a.equal(true, files:find(required, 1, true) ~= nil)
        end

        local contract = read(
            "tools/windows-discovery/modules/CgceDiscovery.Contract.psm1"
        )
        for _, required in ipairs({
            "Assert-CgceGenesisState",
            "Test-CgceRecoverySourceEvidence",
            "Assert-CgceRecoveryCheckpointEvidence",
            "'^[0-9a-f]{64}\\z'",
        }) do
            a.equal(true, contract:find(required, 1, true) ~= nil)
        end

        a.equal(
            true,
            files:find("'^[0-9a-f]{64}\\z'", 1, true) ~= nil
        )
        local runtime = read(
            "tools/windows-discovery/modules/CgceDiscovery.Runtime.psm1"
        )
        a.equal(
            true,
            runtime:find("'^[0-9a-f]{64}\\z'", 1, true) ~= nil
        )

        local state_schema_text = read(
            "tools/windows-discovery/schemas/run-state.schema.json"
        )
        for _, required in ipairs({
            '"recoverySourceCreatedEvidence"',
            '"recoverySourceBackupEvidence"',
            '"recoverySourceRunningEvidence"',
            '"recoverySourceCapturedEvidence"',
        }) do
            a.equal(
                true,
                state_schema_text:find(required, 1, true) ~= nil
            )
        end

        local state_schema = json.decode(state_schema_text)
        assert_fixed_length(
            state_schema.properties.run_id,
            34,
            "^r-[0-9a-f]{32}$"
        )
        assert_fixed_length(
            state_schema.properties.maintenance_id,
            34,
            "^m-[0-9a-f]{32}$"
        )
        a.equal(
            "#/definitions/checksum",
            state_schema.properties.source_manifest_checksum["$ref"]
        )
        assert_fixed_length(
            state_schema.definitions.checksum,
            64,
            "^[0-9a-f]{64}$"
        )
        assert_fixed_length(
            state_schema.definitions.strictUtc,
            20,
            "^[0-9]{4}-[0-9]{2}-[0-9]{2}T"
                .. "[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"
        )
        local error_code = state_schema.properties.errors
            .items.properties.code
        a.equal(10, error_code.minLength)
        a.equal("^CGCE-OPS-[A-Z0-9-]+$", error_code.pattern)
        a.equal("[\\r\\n]", error_code["not"].pattern)

        local control_schema = json.decode(read(
            "tools/windows-discovery/schemas/control-evidence.schema.json"
        ))
        assert_fixed_length(
            control_schema.properties.maintenance_id,
            34,
            "^m-[0-9a-f]{32}$"
        )
        assert_fixed_length(
            control_schema.properties.run_id,
            34,
            "^r-[0-9a-f]{32}$"
        )
        for _, name in ipairs({
            "ue4ss_dll_sha256",
            "bundle_checksum",
        }) do
            assert_fixed_length(
                control_schema.properties[name],
                64,
                "^[0-9a-f]{64}$"
            )
        end
        for _, name in ipairs({
            "verified_at_utc",
            "valid_until_utc",
        }) do
            assert_fixed_length(
                control_schema.properties[name],
                20,
                "^[0-9]{4}-[0-9]{2}-[0-9]{2}T"
                    .. "[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"
            )
        end

        local lifecycle = read("tests/windows/Lifecycle.Tests.ps1")
        a.equal(
            true,
            lifecycle:find(
                "preloaded module from a different canonical path",
                1,
                true
            ) ~= nil
        )
    end)

    it("keeps recovery persistence behind fixed-purpose authority", function()
        local contract = read(
            "tools/windows-discovery/modules/CgceDiscovery.Contract.psm1"
        )
        a.equal(
            nil,
            contract:find('CAPTURED = "RESTORING"', 1, true)
        )
        a.equal(
            nil,
            contract:find('RESTORING = "RESTORED"', 1, true)
        )
        a.equal(
            true,
            contract:find('RESTORED = "EXPORTED"', 1, true) ~= nil
        )
        a.equal(
            nil,
            contract:find("ExpectedExistingSha256", 1, true)
        )
        a.equal(
            true,
            contract:find(
                "function Replace-CgceRunStateJson",
                1,
                true
            ) ~= nil
        )
        a.equal(
            nil,
            contract:find('"Replace-CgceRunStateJson"', 1, true)
        )
        for _, required in ipairs({
            '$ExpectedPhase -cne "RESTORING"',
            '$state.phase -ceq "RESTORING"',
        }) do
            a.equal(true, contract:find(required, 1, true) ~= nil)
        end

        local plan = read(
            "docs/superpowers/plans/"
                .. "2026-07-23-cgce-windows-discovery-operator.md"
        )
        for _, required in ipairs({
            "public create-only JSON writer",
            "Contract-private run-state CAS",
            "only the `RESTORED` branch may use `-AllowCompleted`",
            "revision + 2",
            "Block-CgceRecoveryRunState -StatePath <string>",
            "-RecoveryIntentPath <string> -Code <string> -> void",
            "immediately before every filesystem mutation",
            "$lock = $null\n$statePath = $null\n"
                .. "$recoveryIntentPath = $null\ntry {",
        }) do
            a.equal(true, plan:find(required, 1, true) ~= nil)
        end
        for _, forbidden in ipairs({
            "CAPTURED -> RESTORING",
            "RESTORING -> RESTORED",
            "ExpectedExistingSha256",
        }) do
            a.equal(nil, plan:find(forbidden, 1, true))
        end
    end)

    it("defines Task 6 fixed-purpose recovery exports and restore entry point", function()
        local contract = read(
            "tools/windows-discovery/modules/CgceDiscovery.Contract.psm1"
        )
        for _, required in ipairs({
            '"Get-CgceInventoryTreeSha256"',
            '"Write-CgceRecoveryRunState"',
            '"Block-CgceRecoveryRunState"',
            '"Complete-CgceRecoveryRunState"',
        }) do
            a.equal(true, contract:find(required, 1, true) ~= nil)
        end

        local restore = read(
            "tools/windows-discovery/Restore-CgceProduction.ps1"
        )
        for _, required in ipairs({
            "Write-OrResume-CgceRestoredInventory",
            "Complete-CgceRecoveryJournal",
            "Complete-CgceRunMarker",
            "CGCE_WINDOWS_DISCOVERY_OK",
            "CGCE_WINDOWS_DISCOVERY_BLOCKED",
        }) do
            a.equal(true, restore:find(required, 1, true) ~= nil)
        end
    end)

    it("binds invoke bootstrap to immutable source-manifest authority", function()
        local contract = read(
            "tools/windows-discovery/modules/CgceDiscovery.Contract.psm1"
        )
        for _, required in ipairs({
            "[string]$ExpectedManifestChecksum",
            "source_manifest_checksum",
            "source manifest authority drift",
        }) do
            a.equal(true, contract:find(required, 1, true) ~= nil)
        end

        local spec = read(
            "docs/superpowers/specs/"
                .. "2026-07-23-cgce-windows-discovery-operator-stage-design.md"
        )
        local plan = read(
            "docs/superpowers/plans/"
                .. "2026-07-23-cgce-windows-discovery-operator.md"
        )
        for _, document in ipairs({ spec, plan }) do
            for _, required in ipairs({
                "source_manifest_checksum",
                "run-state.genesis.json",
                "before importing any handoff module",
                "same verified bytes may be relocated",
                "handoff tree and RunRoot must not overlap",
                "no module side effect",
            }) do
                a.equal(true, document:find(required, 1, true) ~= nil)
            end
        end
        for _, required in ipairs({
            "Get-CgceInvokeBootstrap",
            "$PSScriptRoot",
            "UTF8Encoding",
            "source_manifest_checksum",
            "Assert-CgceHandoffSource",
            "-ExpectedManifestChecksum",
            "re-signed",
        }) do
            a.equal(true, plan:find(required, 1, true) ~= nil)
        end

        local invoke = read(
            "tools/windows-discovery/Invoke-CgceDiscovery.ps1"
        )
        for _, required in ipairs({
            "function Read-CgceInvokeGenesisManifestChecksum",
            "function Read-CgceInvokeBootstrapManifest",
            "function Get-CgceInvokeBootstrap",
            "New-Object System.Text.UTF8Encoding($false, $true)",
            "$length -lt 1 -or $length -gt $MaxBytes",
            "$stream.ReadByte() -ne -1",
            "Get-CgceInvokeBootstrapSha256 `\n"
                .. "        -Path $manifestPath `\n"
                .. "        -MaxBytes 1048576",
            '"source_manifest_checksum"\\s*:',
            "source manifest authority drift",
            "-ExpectedManifestChecksum $bootstrap.manifest_checksum",
            "-ExpectedManifestChecksum $state.source_manifest_checksum",
        }) do
            a.equal(true, invoke:find(required, 1, true) ~= nil)
        end
        a.equal(
            nil,
            invoke:find(
                "[System.IO.File]::ReadAllBytes($Path)",
                1,
                true
            )
        )
        local bootstrap_call = assert(invoke:find(
            "$bootstrap = Get-CgceInvokeBootstrap",
            1,
            true
        ))
        local first_import = assert(invoke:find(
            "Import-CgceInvokeVerifiedModule `",
            bootstrap_call,
            true
        ))
        a.equal(true, bootstrap_call < first_import)

        local lifecycle = read("tests/windows/Lifecycle.Tests.ps1")
        for _, required in ipairs({
            "invoke rejects a re-signed handoff before importing its changed module",
            "drifted-module-loaded.txt",
            "Assert-CgceEqual $false (Test-Path -LiteralPath $sentinel)",
        }) do
            a.equal(true, lifecycle:find(required, 1, true) ~= nil)
        end
    end)
end)
