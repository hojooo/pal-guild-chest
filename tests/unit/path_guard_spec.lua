local a = require("tests.support.assertions")
local fake_filesystem = require("tests.support.fake_filesystem")
local path_guard = require("CrossplayGuildChestExpander.Scripts.path_guard")

local ROOT = "C:\\PalServer\\Pal\\Binaries\\Win64\\Mods\\CrossplayGuildChestExpander"

local function merge(target, source)
    for key, value in pairs(source or {}) do
        target[key] = value
    end
    return target
end

local function fixture(options)
    options = options or {}
    local entries = {
        [ROOT] = "directory",
        [ROOT .. "\\artifacts"] = "directory",
        [ROOT .. "\\artifacts\\reports"] = "directory",
    }
    merge(entries, options.entries)

    local fs_options = {
        entries = entries,
        capabilities = options.capabilities,
        canonical_overrides = options.canonical_overrides,
        temp_sibling = options.temp_sibling,
    }
    return fake_filesystem.new(fs_options)
end

local function expect_error(code, field, fn)
    local ok, err = pcall(fn)
    a.equal(false, ok)
    a.equal("table", type(err))
    a.equal(code, err.code)
    a.equal(field, err.field)
    a.equal("string", type(err.detail))
    local count = 0
    for key in pairs(err) do
        a.equal(true, key == "code" or key == "field" or key == "detail")
        count = count + 1
    end
    a.equal(3, count)
    return err
end

local function contains(values, expected)
    for _, value in ipairs(values) do
        if value == expected then
            return true
        end
    end
    return false
end

describe("path_guard.resolve", function()
    it("resolves a valid file and canonicalizes root, every parent, target, and temp sibling", function()
        local fs, observed = fixture()
        local result = path_guard.resolve(
            fs,
            "c:/palserver/pal/binaries/win64/mods/crossplayguildchestexpander",
            "artifacts/reports\\audit.json"
        )

        a.deep_equal({
            root = ROOT,
            relative_path = "artifacts\\reports\\audit.json",
            parent = ROOT .. "\\artifacts\\reports",
            target = ROOT .. "\\artifacts\\reports\\audit.json",
            temp_sibling = ROOT .. "\\artifacts\\reports\\audit.json.cgce.tmp",
        }, result)
        a.equal(1, observed.capabilities)
        a.equal(true, contains(
            observed.canonicalize,
            "c:\\palserver\\pal\\binaries\\win64\\mods\\crossplayguildchestexpander"
        ))
        a.equal(true, contains(observed.canonicalize, ROOT .. "\\artifacts"))
        a.equal(true, contains(observed.canonicalize, ROOT .. "\\artifacts\\reports"))
        a.equal(true, contains(observed.canonicalize, ROOT .. "\\artifacts\\reports\\audit.json"))
        a.equal(true, contains(observed.canonicalize, ROOT .. "\\artifacts\\reports\\audit.json.cgce.tmp"))
        a.equal(0, observed.writes)
    end)

    it("requires an explicit complete filesystem safety contract and read-only ports", function()
        local capability_names = { "no_follow", "atomic_replace", "durable_flush" }
        for _, missing in ipairs(capability_names) do
            local capabilities = {
                no_follow = true,
                atomic_replace = true,
                durable_flush = true,
            }
            capabilities[missing] = nil
            local fs = fixture({ capabilities = capabilities })
            expect_error("CGCE-PATH-CAPABILITY", missing, function()
                path_guard.resolve(fs, ROOT, "audit.json")
            end)

            capabilities[missing] = false
            fs = fixture({ capabilities = capabilities })
            expect_error("CGCE-PATH-CAPABILITY", missing, function()
                path_guard.resolve(fs, ROOT, "audit.json")
            end)
        end

        local fs = fixture()
        fs.canonicalize = nil
        expect_error("CGCE-PATH-PORT", "canonicalize", function()
            path_guard.resolve(fs, ROOT, "audit.json")
        end)

        fs = fixture()
        fs.inspect_no_follow = nil
        expect_error("CGCE-PATH-PORT", "inspect_no_follow", function()
            path_guard.resolve(fs, ROOT, "audit.json")
        end)

        fs = fixture()
        fs.propose_temp_sibling = nil
        expect_error("CGCE-PATH-PORT", "propose_temp_sibling", function()
            path_guard.resolve(fs, ROOT, "audit.json")
        end)
    end)

    it("rejects POSIX, Windows, UNC, device, and drive-relative absolute input", function()
        local candidates = {
            "/etc/passwd",
            "\\Windows\\System32\\drivers\\etc\\hosts",
            "C:\\Windows\\system.ini",
            "C:/Windows/system.ini",
            "C:Windows\\system.ini",
            "\\\\server\\share\\audit.json",
            "//server/share/audit.json",
            "\\\\?\\C:\\Windows\\system.ini",
            "\\\\.\\PhysicalDrive0",
            "\\??\\C:\\Windows\\system.ini",
        }

        for _, candidate in ipairs(candidates) do
            local fs = fixture()
            expect_error("CGCE-PATH-ABSOLUTE", "relative_path", function()
                path_guard.resolve(fs, ROOT, candidate)
            end)
        end
    end)

    it("rejects traversal, empty or dot components, controls, ADS, and trailing aliases", function()
        local scenarios = {
            { path = "", code = "CGCE-PATH-RELATIVE", field = "relative_path" },
            { path = "artifacts//audit.json", code = "CGCE-PATH-COMPONENT", field = "relative_path[2]" },
            { path = "artifacts\\\\audit.json", code = "CGCE-PATH-COMPONENT", field = "relative_path[2]" },
            { path = "artifacts/", code = "CGCE-PATH-COMPONENT", field = "relative_path[2]" },
            { path = ".", code = "CGCE-PATH-COMPONENT", field = "relative_path[1]" },
            { path = "artifacts/./audit.json", code = "CGCE-PATH-COMPONENT", field = "relative_path[2]" },
            { path = "../audit.json", code = "CGCE-PATH-TRAVERSAL", field = "relative_path[1]" },
            { path = "artifacts\\..\\audit.json", code = "CGCE-PATH-TRAVERSAL", field = "relative_path[2]" },
            { path = "artifacts/..\\audit.json", code = "CGCE-PATH-TRAVERSAL", field = "relative_path[2]" },
            { path = "artifacts/audit" .. string.char(0) .. ".json", code = "CGCE-PATH-CONTROL", field = "relative_path[2]" },
            { path = "artifacts/audit\n.json", code = "CGCE-PATH-CONTROL", field = "relative_path[2]" },
            { path = "artifacts/audit.json:stream", code = "CGCE-PATH-COLON", field = "relative_path[2]" },
            { path = "artifacts/audit.json.", code = "CGCE-PATH-TRAILING", field = "relative_path[2]" },
            { path = "artifacts/audit.json ", code = "CGCE-PATH-TRAILING", field = "relative_path[2]" },
        }

        for _, scenario in ipairs(scenarios) do
            local fs = fixture()
            expect_error(scenario.code, scenario.field, function()
                path_guard.resolve(fs, ROOT, scenario.path)
            end)
        end
    end)

    it("rejects Windows reserved device names including names with extensions", function()
        local reserved = {
            "CON",
            "con.json",
            "PRN.audit.json",
            "AUX",
            "nul.txt",
            "COM1",
            "com9.log",
            "LPT1",
            "lpt9.out",
            "CONIN$",
            "conin$.json",
            "CONOUT$",
            "conout$.log",
            "CLOCK$",
            "clock$.txt",
            "CON .txt",
        }
        for _, name in ipairs(reserved) do
            local fs = fixture()
            expect_error("CGCE-PATH-RESERVED", "relative_path[2]", function()
                path_guard.resolve(fs, ROOT, "artifacts/" .. name)
            end)
        end

        for _, name in ipairs({ "COM10.json", "LPT0.log", "console.json", ".hidden" }) do
            local fs = fixture()
            local result = path_guard.resolve(fs, ROOT, name)
            a.equal(ROOT .. "\\" .. name, result.target)
        end
    end)

    it("rejects reparse points at the root, parent, target, or temp sibling", function()
        local scenarios = {
            {
                entries = { [ROOT] = { kind = "directory", reparse_point = true } },
                path = "audit.json",
                field = "root",
            },
            {
                entries = { [ROOT .. "\\artifacts"] = { kind = "directory", reparse_point = true } },
                path = "artifacts/audit.json",
                field = "relative_path[1]",
            },
            {
                entries = { [ROOT .. "\\artifacts\\audit.json"] = { kind = "file", reparse_point = true } },
                path = "artifacts/audit.json",
                field = "relative_path[2]",
            },
            {
                entries = { [ROOT .. "\\artifacts\\audit.json.cgce.tmp"] = { kind = "file", reparse_point = true } },
                path = "artifacts/audit.json",
                field = "temp_sibling",
            },
        }

        for _, scenario in ipairs(scenarios) do
            local fs = fixture({ entries = scenario.entries })
            expect_error("CGCE-PATH-REPARSE", scenario.field, function()
                path_guard.resolve(fs, ROOT, scenario.path)
            end)
        end
    end)

    it("requires every parent to exist as a directory and the target to be a file or missing", function()
        local fs = fixture({
            entries = { [ROOT .. "\\artifacts"] = { kind = "missing" } },
        })
        expect_error("CGCE-PATH-MISSING", "relative_path[1]", function()
            path_guard.resolve(fs, ROOT, "artifacts/audit.json")
        end)

        fs = fixture({ entries = { [ROOT .. "\\artifacts"] = "file" } })
        expect_error("CGCE-PATH-NOT-DIRECTORY", "relative_path[1]", function()
            path_guard.resolve(fs, ROOT, "artifacts/audit.json")
        end)

        fs = fixture({ entries = { [ROOT .. "\\artifacts\\audit.json"] = "directory" } })
        expect_error("CGCE-PATH-TARGET-TYPE", "relative_path[2]", function()
            path_guard.resolve(fs, ROOT, "artifacts/audit.json")
        end)

        fs = fixture({ entries = { [ROOT .. "\\artifacts\\audit.json"] = "file" } })
        a.equal(ROOT .. "\\artifacts\\audit.json", path_guard.resolve(
            fs,
            ROOT,
            "artifacts/audit.json"
        ).target)
    end)

    it("uses component-boundary containment instead of sibling string prefixes", function()
        local sibling = ROOT .. "Evil"
        local scenarios = {
            {
                overrides = { [ROOT .. "\\artifacts"] = sibling .. "\\artifacts" },
                path = "artifacts/audit.json",
                field = "relative_path[1]",
            },
            {
                overrides = { [ROOT .. "\\artifacts\\audit.json"] = sibling .. "\\audit.json" },
                path = "artifacts/audit.json",
                field = "relative_path[2]",
            },
            {
                overrides = { [ROOT .. "\\artifacts\\audit.json.cgce.tmp"] = sibling .. "\\audit.json.cgce.tmp" },
                path = "artifacts/audit.json",
                field = "temp_sibling",
            },
        }

        for _, scenario in ipairs(scenarios) do
            local fs = fixture({ canonical_overrides = scenario.overrides })
            expect_error("CGCE-PATH-ESCAPE", scenario.field, function()
                path_guard.resolve(fs, ROOT, scenario.path)
            end)
        end
    end)

    it("requires a distinct missing temp candidate in the target's exact canonical directory", function()
        local randomized = ROOT .. "\\artifacts\\audit.json.cgce.7f3a9b.tmp"
        local fs = fixture({ temp_sibling = randomized })
        a.equal(randomized, path_guard.resolve(fs, ROOT, "artifacts/audit.json").temp_sibling)

        fs = fixture({
            temp_sibling = ROOT .. "\\artifacts\\reports\\other.tmp",
        })
        expect_error("CGCE-PATH-TEMP", "temp_sibling", function()
            path_guard.resolve(fs, ROOT, "artifacts/audit.json")
        end)

        fs = fixture({ temp_sibling = ROOT .. "\\artifacts\\audit.json" })
        expect_error("CGCE-PATH-TEMP", "temp_sibling", function()
            path_guard.resolve(fs, ROOT, "artifacts/audit.json")
        end)

        fs = fixture({
            entries = { [ROOT .. "\\artifacts\\audit.json.cgce.tmp"] = "file" },
        })
        expect_error("CGCE-PATH-TEMP", "temp_sibling", function()
            path_guard.resolve(fs, ROOT, "artifacts/audit.json")
        end)
    end)

    it("revalidates reserved device names in every filesystem-provided canonical path", function()
        local scenarios = {
            {
                overrides = { [ROOT] = "C:\\CON" },
                path = "audit.json",
                field = "canonicalize",
            },
            {
                overrides = { [ROOT] = "\\\\server\\CON" },
                path = "audit.json",
                field = "canonicalize",
            },
            {
                overrides = { [ROOT .. "\\artifacts"] = ROOT .. "\\CON.txt" },
                path = "artifacts/audit.json",
                field = "canonicalize",
            },
            {
                overrides = { [ROOT .. "\\artifacts\\audit.json"] = ROOT .. "\\artifacts\\CONIN$.json" },
                path = "artifacts/audit.json",
                field = "canonicalize",
            },
            {
                temp_sibling = ROOT .. "\\artifacts\\CONOUT$.tmp",
                path = "artifacts/audit.json",
                field = "propose_temp_sibling",
            },
            {
                overrides = {
                    [ROOT .. "\\artifacts\\audit.json.cgce.tmp"] = ROOT .. "\\artifacts\\CLOCK$.tmp",
                },
                path = "artifacts/audit.json",
                field = "canonicalize",
            },
        }

        for _, scenario in ipairs(scenarios) do
            local fs = fixture({
                canonical_overrides = scenario.overrides,
                temp_sibling = scenario.temp_sibling,
            })
            expect_error("CGCE-PATH-FS-ERROR", scenario.field, function()
                path_guard.resolve(fs, ROOT, scenario.path)
            end)
        end
    end)

    it("fails closed when a parent, target, or temp canonicalizes to a drive root", function()
        local drive_root = "D:\\"
        local scenarios = {
            {
                path = "reports/audit.json",
                overrides = { ["D:\\reports"] = drive_root },
                code = "CGCE-PATH-ESCAPE",
                field = "relative_path[1]",
            },
            {
                path = "audit.json",
                overrides = { ["D:\\audit.json"] = drive_root },
                code = "CGCE-PATH-ESCAPE",
                field = "relative_path[1]",
            },
            {
                path = "audit.json",
                temp_sibling = drive_root,
                code = "CGCE-PATH-TEMP",
                field = "temp_sibling",
            },
            {
                path = "audit.json",
                overrides = { ["D:\\audit.json.cgce.tmp"] = drive_root },
                code = "CGCE-PATH-TEMP",
                field = "temp_sibling",
            },
        }

        for _, scenario in ipairs(scenarios) do
            local fs = fake_filesystem.new({
                entries = {
                    [drive_root] = "directory",
                    ["D:\\reports"] = "directory",
                },
                canonical_overrides = scenario.overrides,
                temp_sibling = scenario.temp_sibling,
            })
            expect_error(scenario.code, scenario.field, function()
                path_guard.resolve(fs, drive_root, scenario.path)
            end)
        end
    end)

    it("fails closed on malformed or throwing filesystem responses", function()
        local fs = fixture()
        fs.capabilities = function()
            error("secret port failure")
        end
        local err = expect_error("CGCE-PATH-FS-ERROR", "capabilities", function()
            path_guard.resolve(fs, ROOT, "audit.json")
        end)
        a.equal(false, err.detail:find("secret", 1, true) ~= nil)

        fs = fixture()
        fs.canonicalize = function()
            return "relative\\escape"
        end
        expect_error("CGCE-PATH-FS-ERROR", "canonicalize", function()
            path_guard.resolve(fs, ROOT, "audit.json")
        end)

        fs = fixture()
        fs.inspect_no_follow = function()
            return { kind = "unknown", reparse_point = false }
        end
        expect_error("CGCE-PATH-FS-ERROR", "inspect_no_follow", function()
            path_guard.resolve(fs, ROOT, "audit.json")
        end)

        fs = fixture()
        fs.propose_temp_sibling = function()
            return nil, "secret port failure"
        end
        err = expect_error("CGCE-PATH-FS-ERROR", "propose_temp_sibling", function()
            path_guard.resolve(fs, ROOT, "audit.json")
        end)
        a.equal(false, err.detail:find("secret", 1, true) ~= nil)
    end)
end)
