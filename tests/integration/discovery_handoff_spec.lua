local a = require("tests.support.assertions")
local json = require("CrossplayGuildChestExpander.Scripts.json")

local function read(path)
    local file = assert(io.open(path, "rb"))
    local content = file:read("*a")
    file:close()
    return content
end

local function shell_quote(value)
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function run(command)
    local pipe = assert(io.popen(command .. " 2>&1"))
    local output = pipe:read("*a")
    local ok, _, code = pipe:close()
    return ok == true and code == 0, output
end

local function must_run(command)
    local ok, output = run(command)
    if not ok then
        error(output, 0)
    end
end

local function temporary_path(suffix)
    local path = os.tmpname() .. suffix
    os.remove(path)
    return path
end

local function remove_tree(path)
    must_run("find " .. shell_quote(path) .. " -depth -delete")
end

local function archive_entries(path)
    local ok, output = run("unzip -Z1 " .. shell_quote(path))
    a.equal(true, ok)
    local entries = {}
    for line in output:gmatch("[^\r\n]+") do
        entries[#entries + 1] = line
    end
    table.sort(entries)
    return entries
end

local function archive_text(path, entry)
    local ok, output = run(
        "unzip -p "
            .. shell_quote(path)
            .. " "
            .. shell_quote(entry)
    )
    a.equal(true, ok)
    return output
end

local handoff_paths = {
    "tests/windows/Contract.Tests.ps1",
    "tests/windows/Files.Tests.ps1",
    "tests/windows/fixtures/FakePalServer.cmd",
    "tests/windows/Lifecycle.Tests.ps1",
    "tests/windows/Run-CgceDiscoveryTests.ps1",
    "tests/windows/Runtime.Tests.ps1",
    "tests/windows/TestHarness.ps1",
    "tools/windows-discovery/CgceDiscovery.Common.psm1",
    "tools/windows-discovery/Export-CgceDiscoveryEvidence.ps1",
    "tools/windows-discovery/Invoke-CgceDiscovery.ps1",
    "tools/windows-discovery/modules/CgceDiscovery.Contract.psm1",
    "tools/windows-discovery/modules/CgceDiscovery.Files.psm1",
    "tools/windows-discovery/modules/CgceDiscovery.Runtime.psm1",
    "tools/windows-discovery/Prepare-CgceDiscovery.ps1",
    "tools/windows-discovery/probe/CGCEDiscoveryInventory/scripts/main.lua",
    "tools/windows-discovery/README.md",
    "tools/windows-discovery/Restore-CgceProduction.ps1",
    "tools/windows-discovery/schemas/control-evidence.schema.json",
    "tools/windows-discovery/schemas/export-manifest.schema.json",
    "tools/windows-discovery/schemas/run-state.schema.json",
}

local function stage_handoff_repository()
    local root = temporary_path("-cgce-handoff-fixture")
    must_run("mkdir -p " .. shell_quote(root .. "/scripts"))
    must_run(
        "mkdir -p "
            .. shell_quote(root .. "/third_party/lua-5.4.8/src")
    )
    must_run("mkdir -p " .. shell_quote(root .. "/tests"))
    must_run(
        "cp -R CrossplayGuildChestExpander "
            .. shell_quote(root .. "/CrossplayGuildChestExpander")
    )
    must_run(
        "cp -R tools " .. shell_quote(root .. "/tools")
    )
    must_run(
        "cp -R tests/windows " .. shell_quote(root .. "/tests/windows")
    )
    must_run(table.concat({
        "cp scripts/verify-package.sh",
        "scripts/verify-discovery-handoff.sh",
        "scripts/build-discovery-handoff.sh",
        shell_quote(root .. "/scripts/"),
    }, " "))
    must_run(table.concat({
        "cp third_party/lua-5.4.8/src/lua",
        shell_quote(root .. "/third_party/lua-5.4.8/src/lua"),
    }, " "))
    must_run("chmod +x " .. shell_quote(root .. "/scripts/") .. "*.sh")
    must_run(table.concat({
        "git -C", shell_quote(root), "init -q",
        "&& git -C", shell_quote(root),
        "config user.email cgce-test@example.invalid",
        "&& git -C", shell_quote(root),
        "config user.name CGCE-Test",
        "&& git -C", shell_quote(root), "add .",
        "&& git -C", shell_quote(root),
        "commit -q -m fixture",
    }, " "))
    return root
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

    it("defines Task 6 Contract and Files public recovery surfaces", function()
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

        local files = read(
            "tools/windows-discovery/modules/CgceDiscovery.Files.psm1"
        )
        a.equal(
            true,
            files:find('"Assert-CgceRecoveryMatrix"', 1, true) ~= nil
        )
    end)

    it("defines the Task 6 restore entry point surface", function()
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

    it("defines the strict private evidence export surface", function()
        local exporter = read(
            "tools/windows-discovery/Export-CgceDiscoveryEvidence.ps1"
        )
        for _, required in ipairs({
            "#Requires -Version 5.1",
            "#Requires -RunAsAdministrator",
            "[switch]$Resume",
            "CGCE-OPS-EXPORT-PHASE",
            "CGCE-OPS-EXPORT-ALLOWLIST",
            "CGCE-OPS-EXPORT-SENSITIVE",
            "CGCE-OPS-EXPORT-EXISTS",
            "Enter-CgceExclusiveLock",
            "Assert-CgceRunMarker -State $state -AllowCompleted",
            "Assert-CgceControlEvidence",
            "Assert-CgceExportPayloadMatchesExpected",
            "-ExpectedPayload $authority.expected_payload",
            '"apikey"',
            "Set-CgceRunPhase",
            "CGCE_WINDOWS_DISCOVERY_OK",
            "CGCE_WINDOWS_DISCOVERY_BLOCKED",
        }) do
            a.equal(true, exporter:find(required, 1, true) ~= nil)
        end
        for _, forbidden in ipairs({
            "Invoke-WebRequest",
            "Invoke-RestMethod",
            "Start-BitsTransfer",
            "Enter-PSSession",
            "Invoke-Command",
            "New-PSSession",
        }) do
            a.equal(nil, exporter:find(forbidden, 1, true))
        end

        local schema = json.decode(read(
            "tools/windows-discovery/schemas/export-manifest.schema.json"
        ))
        a.equal("object", schema.type)
        a.equal(false, schema.additionalProperties)
        a.equal(
            "cgce_windows_discovery_export_manifest",
            schema.properties.kind.const
        )
        assert_fixed_length(
            schema.properties.run_id,
            34,
            "^r-[0-9a-f]{32}$"
        )
        assert_fixed_length(
            schema.definitions.checksum,
            64,
            "^[0-9a-f]{64}$"
        )
    end)

    it("builds only the exact tracked Windows handoff deterministically", function()
        for _, path in ipairs({
            "scripts/verify-discovery-handoff.sh",
            "scripts/build-discovery-handoff.sh",
            "tools/windows-discovery/README.md",
        }) do
            a.equal(true, #read(path) > 0)
        end
        local verifier = read("scripts/verify-discovery-handoff.sh")
        for _, required in ipairs({
            "scripts/verify-package.sh",
            "git ls-files --error-unmatch",
            "WINDOWS_DISCOVERY_HANDOFF_VERIFIED",
            "ExecuteInGameThread",
            "New-NetFirewallRule",
        }) do
            a.equal(true, verifier:find(required, 1, true) ~= nil)
        end
        local builder = read("scripts/build-discovery-handoff.sh")
        for _, required in ipairs({
            "source-manifest.sha256",
            "git -C \"$repository_root\" status --porcelain=v1",
            "touch -t 198001010000",
            "zip -X -q",
            "shasum -a 256",
        }) do
            a.equal(true, builder:find(required, 1, true) ~= nil)
        end

        local root = stage_handoff_repository()
        local first = root .. "/first/handoff.zip"
        local second = root .. "/second/handoff.zip"
        local verifier_command = shell_quote(
            root .. "/scripts/verify-discovery-handoff.sh"
        )
        local builder_command = shell_quote(
            root .. "/scripts/build-discovery-handoff.sh"
        )
        local ok, output = run(verifier_command)
        a.equal(true, ok)
        a.equal(
            true,
            output:find(
                "WINDOWS_DISCOVERY_HANDOFF_VERIFIED",
                1,
                true
            ) ~= nil
        )
        must_run(builder_command .. " " .. shell_quote(first))
        must_run(builder_command .. " " .. shell_quote(second))
        a.equal(read(first), read(second))
        a.equal(read(first .. ".sha256"), read(second .. ".sha256"))

        local expected = {
            "CGCE-Windows-Discovery-Handoff/source-manifest.sha256",
        }
        for _, path in ipairs(handoff_paths) do
            expected[#expected + 1] =
                "CGCE-Windows-Discovery-Handoff/" .. path
        end
        table.sort(expected)
        a.deep_equal(expected, archive_entries(first))
        local manifest = archive_text(
            first,
            "CGCE-Windows-Discovery-Handoff/source-manifest.sha256"
        )
        a.equal(nil, manifest:find("\r", 1, true))
        a.equal("\n", manifest:sub(-1))
        local manifest_paths = {}
        local previous
        for line in manifest:gmatch("[^\n]+") do
            local checksum, relative = line:match(
                "^([0-9a-f][0-9a-f]+)  ([A-Za-z0-9._/-]+)$"
            )
            a.equal(64, checksum and #checksum or 0)
            a.equal(true, previous == nil or previous < relative)
            manifest_paths[#manifest_paths + 1] = relative
            previous = relative
        end
        local sorted_handoff_paths = {}
        for index, path in ipairs(handoff_paths) do
            sorted_handoff_paths[index] = path
        end
        table.sort(sorted_handoff_paths)
        a.deep_equal(sorted_handoff_paths, manifest_paths)
        a.equal(
            true,
            read(first .. ".sha256"):match(
                "^[0-9a-f]+  handoff%.zip\n$"
            ) ~= nil
        )

        local rogue = root .. "/tools/windows-discovery/rogue.dll"
        local file = assert(io.open(rogue, "wb"))
        assert(file:write("synthetic binary"))
        assert(file:close())
        local rogue_ok, rogue_output = run(verifier_command)
        a.equal(false, rogue_ok)
        a.equal(
            true,
            rogue_output:find(
                "CGCE-HANDOFF-ALLOWLIST",
                1,
                true
            ) ~= nil
        )
        os.remove(rogue)

        local readme = root .. "/tools/windows-discovery/README.md"
        local dirty = assert(io.open(readme, "ab"))
        assert(dirty:write("\n"))
        assert(dirty:close())
        local dirty_ok, dirty_output = run(
            builder_command
                .. " "
                .. shell_quote(root .. "/dirty/handoff.zip")
        )
        a.equal(false, dirty_ok)
        a.equal(
            true,
            dirty_output:find("CGCE-HANDOFF-DIRTY", 1, true) ~= nil
        )
        remove_tree(root)
    end)
end)
