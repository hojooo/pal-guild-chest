local a = require("tests.support.assertions")
local json = require("CrossplayGuildChestExpander.Scripts.json")
local platform_preflight = require("CrossplayGuildChestExpander.Scripts.platform_preflight")

local function argv(overrides)
    local value = {
        "PalServer.exe",
        "-useperfthreads",
        "-publiclobby",
        "-port=8211",
        "-publicport=8211",
        "-publicip=198.51.100.9",
    }
    for index, item in pairs(overrides or {}) do
        value[index] = item
    end
    return value
end

local function realistic_options(platforms)
    return table.concat({
        "OptionSettings=(Difficulty=None",
        ',ServerName="Guild, (crossplay) = ready"',
        ',AdminPassword="fixture-secret,with=(punctuation)"',
        ',NestedSetting=(Alpha=(1,2),Label="x,y")',
        ",CrossplayPlatforms=" .. (platforms or "(Steam,Xbox,PS5,Mac)"),
        ",bAllowClientMod=False",
        ",PublicPort=8211",
        ",LogFormatType=Json",
        ",AllowConnectPlatform=Steam",
        ",IsServer=true)",
    })
end

local function finding_codes(report)
    local result = {}
    for _, finding in ipairs(report.findings) do
        result[#result + 1] = finding.code
    end
    return result
end

local function contains(values, expected)
    for _, value in ipairs(values) do
        if value == expected then
            return true
        end
    end
    return false
end

local function assert_safe_report(report)
    local encoded = json.encode(report)
    for _, secret in ipairs({
        "fixture-secret",
        "198.51.100.9",
        "AdminPassword",
        "PalServer.exe",
    }) do
        a.equal(false, encoded:find(secret, 1, true) ~= nil)
    end
end

describe("platform_preflight.check", function()
    it("passes the required Steam, PS5, and Mac diagnostic without claiming certification", function()
        local report = platform_preflight.check(argv(), realistic_options())

        a.equal(true, report.preflight_ok)
        a.equal("CONNECTIVITY_PREFLIGHT_OK", report.state)
        a.equal("UNPROVEN", report.certification)
        a.equal(true, report.diagnostic_only)
        a.deep_equal({}, report.findings)
        a.equal("[]", json.encode(report.findings))
        a.equal(true, report.evidence.public_lobby)
        a.equal(8211, report.evidence.game_port)
        a.equal(8211, report.evidence.public_port)
        a.equal(8211, report.evidence.ini_public_port)
        a.deep_equal({ Steam = true, PS5 = true, Mac = true }, report.evidence.required_platforms)
        a.equal(true, report.evidence.xbox)
        a.equal(false, report.evidence.client_mod_allowed)
        a.equal("Json", report.evidence.log_format)
        assert_safe_report(report)
    end)

    it("accepts a tuple RHS and quoted commas, escapes, equals signs, and nested tuples", function()
        local rhs = table.concat({
            "(ServerName=\"quoted \\\"name\\\", x=y\"",
            ",Nested=(One=(Two=\"a,b\"),Three=(4,5))",
            ",CrossplayPlatforms=(Mac,Steam,PS5)",
            ",bAllowClientMod=False,PublicPort=8211,LogFormatType=Json)",
        })
        local report = platform_preflight.check(argv(), rhs)

        a.equal(true, report.preflight_ok)
        a.equal(false, report.evidence.xbox)
        a.deep_equal({ Steam = true, PS5 = true, Mac = true }, report.evidence.required_platforms)
    end)

    it("accepts surrounding spaces without rewriting or exposing invalid raw evidence", function()
        local settings = "  " .. realistic_options()
            :gsub("bAllowClientMod=False", "bAllowClientMod=MaybeSecret", 1)
            :gsub("LogFormatType=Json", "LogFormatType=never-expose-this", 1) .. "  "
        local report = platform_preflight.check(argv(), settings)
        local encoded = json.encode(report)

        a.equal(false, report.preflight_ok)
        a.equal(nil, report.evidence.client_mod_allowed)
        a.equal("INVALID", report.evidence.log_format)
        a.equal(false, encoded:find("MaybeSecret", 1, true) ~= nil)
        a.equal(false, encoded:find("never-expose-this", 1, true) ~= nil)
    end)

    it("requires public lobby, three matching ports, required platforms, vanilla clients, and JSON logs", function()
        local no_lobby = argv({ [3] = "-NoAsyncLoadingThread" })
        local report = platform_preflight.check(no_lobby, realistic_options("(Steam,Xbox)"))
        local codes = finding_codes(report)
        a.equal(false, report.preflight_ok)
        a.equal("PS5_CONNECTIVITY_MISCONFIGURED", report.state)
        a.equal("UNPROVEN", report.certification)
        a.equal(true, contains(codes, "CGCE-PF-PUBLIC-LOBBY-REQUIRED"))
        a.equal(true, contains(codes, "CGCE-PF-REQUIRED-PLATFORM-MISSING"))

        report = platform_preflight.check(
            argv({ [5] = "-publicport=9000" }),
            realistic_options():gsub("PublicPort=8211", "PublicPort=7777", 1)
                :gsub("bAllowClientMod=False", "bAllowClientMod=True", 1)
                :gsub("LogFormatType=Json", "LogFormatType=Text", 1)
        )
        codes = finding_codes(report)
        a.equal(true, contains(codes, "CGCE-PF-PUBLIC-PORT-MISMATCH"))
        a.equal(true, contains(codes, "CGCE-PF-CLIENT-MOD-MUST-BE-FALSE"))
        a.equal(true, contains(codes, "CGCE-PF-LOG-FORMAT-MUST-BE-JSON"))
    end)

    it("never treats AllowConnectPlatform or IsServer as compatibility evidence", function()
        local settings = table.concat({
            "OptionSettings=(AllowConnectPlatform=Steam,IsServer=true",
            ",PublicPort=8211,bAllowClientMod=False,LogFormatType=Json)",
        })
        local report = platform_preflight.check(argv(), settings)
        local codes = finding_codes(report)

        a.equal(false, report.preflight_ok)
        a.equal(true, contains(codes, "CGCE-PF-REQUIRED-PLATFORM-MISSING"))
        a.deep_equal({ Steam = false, PS5 = false, Mac = false }, report.evidence.required_platforms)
    end)

    it("fails closed on sparse argv, duplicates, controls, and malformed known CLI values", function()
        local sparse = argv()
        sparse[3] = nil
        local duplicate = argv()
        duplicate[#duplicate + 1] = "-port=8211"

        for _, scenario in ipairs({
            { args = sparse, expected = "CGCE-PF-ARGV-MALFORMED" },
            { args = duplicate, expected = "CGCE-PF-DUPLICATE-CLI-KEY" },
            { args = argv({ [4] = "-port=not-a-port" }), expected = "CGCE-PF-GAME-PORT-INVALID" },
            { args = argv({ [2] = "-publicip=secret\nvalue" }), expected = "CGCE-PF-ARGV-MALFORMED" },
        }) do
            local report = platform_preflight.check(scenario.args, realistic_options())
            a.equal(false, report.preflight_ok)
            a.equal(scenario.expected, report.findings[1].code)
            assert_safe_report(report)
        end
    end)

    it("fails closed on duplicate INI keys, malformed quotes or tuples, controls, and unknown platforms", function()
        local scenarios = {
            {
                settings = realistic_options():gsub(
                    "PublicPort=8211",
                    "PublicPort=8211,publicport=8211",
                    1
                ),
                expected = "CGCE-PF-DUPLICATE-OPTION-KEY",
            },
            { settings = 'OptionSettings=(ServerName="unterminated)', expected = "CGCE-PF-OPTION-SETTINGS-MALFORMED" },
            { settings = "OptionSettings=(Nested=(1,2),PublicPort=8211", expected = "CGCE-PF-OPTION-SETTINGS-MALFORMED" },
            { settings = "OptionSettings=(ServerName=bad\nvalue)", expected = "CGCE-PF-OPTION-SETTINGS-MALFORMED" },
            { settings = realistic_options("(Steam,PS5,Mac,Switch)"), expected = "CGCE-PF-UNKNOWN-CROSSPLAY-PLATFORM" },
        }

        for _, scenario in ipairs(scenarios) do
            local report = platform_preflight.check(argv(), scenario.settings)
            a.equal(false, report.preflight_ok)
            a.equal(scenario.expected, report.findings[1].code)
            assert_safe_report(report)
        end
    end)
end)

describe("platform_preflight.merge_option_settings", function()
    it("updates four known values in place while preserving unrelated and secret bytes", function()
        local original = realistic_options()
            :gsub("bAllowClientMod=False", "bAllowClientMod=True", 1)
            :gsub("PublicPort=8211", "PublicPort=9000", 1)
            :gsub("LogFormatType=Json", "LogFormatType=Text", 1)
        local merged, err = platform_preflight.merge_option_settings(original, {
            public_port = 8211,
            include_xbox = false,
        })
        local expected = original
            :gsub("bAllowClientMod=True", "bAllowClientMod=False", 1)
            :gsub("PublicPort=9000", "PublicPort=8211", 1)
            :gsub("LogFormatType=Text", "LogFormatType=Json", 1)

        a.equal(nil, err)
        a.equal(expected, merged)
        a.equal(true, merged:find('AdminPassword="fixture-secret,with=(punctuation)"', 1, true) ~= nil)
        a.equal(true, merged:find('NestedSetting=(Alpha=(1,2),Label="x,y")', 1, true) ~= nil)
        a.equal(true, merged:find("CrossplayPlatforms=(Steam,Xbox,PS5,Mac)", 1, true) ~= nil)
        a.equal(true, merged:find("bAllowClientMod=False", 1, true) ~= nil)
        a.equal(true, merged:find("PublicPort=8211", 1, true) ~= nil)
        a.equal(true, merged:find("LogFormatType=Json", 1, true) ~= nil)

        local second = assert(platform_preflight.merge_option_settings(merged, {
            public_port = 8211,
            include_xbox = false,
        }))
        a.equal(merged, second)
    end)

    it("appends missing known keys deterministically and can add optional Xbox", function()
        local original = '(ServerName="preserve,exact",SecretValue="x=y")'
        local merged, err = platform_preflight.merge_option_settings(original, {
            public_port = 8211,
            include_xbox = true,
        })

        a.equal(nil, err)
        a.equal(
            '(ServerName="preserve,exact",SecretValue="x=y",CrossplayPlatforms=(Steam,Xbox,PS5,Mac),bAllowClientMod=False,PublicPort=8211,LogFormatType=Json)',
            merged
        )
        a.equal(merged, assert(platform_preflight.merge_option_settings(merged, {
            public_port = 8211,
            include_xbox = true,
        })))
    end)

    it("preserves existing Xbox but rejects unknown existing or requested platforms", function()
        local without_xbox = realistic_options("(Steam,PS5,Mac)")
        local preserved = assert(platform_preflight.merge_option_settings(realistic_options(), {
            public_port = 8211,
            include_xbox = false,
        }))
        a.equal(true, preserved:find("(Steam,Xbox,PS5,Mac)", 1, true) ~= nil)

        local added = assert(platform_preflight.merge_option_settings(without_xbox, {
            public_port = 8211,
            include_xbox = true,
        }))
        a.equal(true, added:find("(Steam,Xbox,PS5,Mac)", 1, true) ~= nil)

        local merged, err = platform_preflight.merge_option_settings(
            realistic_options("(Steam,PS5,Mac,Switch)"),
            { public_port = 8211, include_xbox = false }
        )
        a.equal(nil, merged)
        a.equal("CGCE-PF-UNKNOWN-CROSSPLAY-PLATFORM", err.code)

        merged, err = platform_preflight.merge_option_settings(without_xbox, {
            public_port = 8211,
            include_xbox = false,
            platforms = { "Switch" },
        })
        a.equal(nil, merged)
        a.equal("CGCE-PF-MERGE-POLICY-INVALID", err.code)
    end)
end)
