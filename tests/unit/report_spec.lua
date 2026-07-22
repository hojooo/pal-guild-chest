local a = require("tests.support.assertions")
local audit = require("CrossplayGuildChestExpander.Scripts.audit")
local fake_adapter = require("tests.support.fake_adapter")
local fake_filesystem = require("tests.support.fake_filesystem")
local json = require("CrossplayGuildChestExpander.Scripts.json")
local report = require("CrossplayGuildChestExpander.Scripts.report")
local sha256 = require("CrossplayGuildChestExpander.Scripts.sha256")
local snapshot = require("CrossplayGuildChestExpander.Scripts.snapshot")

local ROOT = "C:\\PalServer\\Pal\\Binaries\\Win64\\Mods\\CrossplayGuildChestExpander"
local REPORT_PATH = "artifacts\\audit-report.json"
local PROFILE = "windows-dedicated-ps5-macos-required"
local readonly_adapter = fake_adapter.new()

local function expect_error(code, field, fn)
    local ok, err = pcall(fn)
    a.equal(false, ok)
    a.equal("table", type(err))
    a.equal(code, err.code)
    a.equal(field, err.field)
    a.equal("string", type(err.detail))
    return err
end

local function slots(count)
    local result = {}
    for index = 1, count do
        result[index] = fake_adapter.slot(nil)
    end
    return result
end

local function captured_audit()
    local guilds = {
        { guild_id = "guild/beta", guild_name = "Beta", chest_container_id = "container/beta" },
        { guild_id = "guild/alpha", guild_name = "Alpha", chest_container_id = "container/alpha" },
    }
    local containers = {
        ["container/alpha"] = fake_adapter.container({
            container_id = "container/alpha",
            owner_guild_id = "guild/alpha",
            slots = slots(54),
        }),
        ["container/beta"] = fake_adapter.container({
            container_id = "container/beta",
            owner_guild_id = "guild/beta",
            slots = slots(358),
        }),
    }

    return audit.capture({
        world_id = "world/alpha",
        game_revision = 12345,
        deployment_profile = PROFILE,
        target_slots = 358,
        include_guild_ids = {},
        exclude_guild_ids = {},
        list_guilds = function()
            return guilds
        end,
        resolve_guild_chest = function(container_id)
            local container = containers[container_id]
            return {
                container_id = container_id,
                owner_guild_id = container.owner_guild_id,
                is_guild_chest = true,
                container = container,
            }
        end,
        snapshot_container = function(container)
            return snapshot.capture(readonly_adapter, container)
        end,
    })
end

local function blocked_audit()
    local container = fake_adapter.container({
        container_id = "container/alpha",
        owner_guild_id = "guild/other",
        slots = slots(54),
    })
    return audit.capture({
        world_id = "world/alpha",
        game_revision = 12345,
        deployment_profile = PROFILE,
        target_slots = 358,
        include_guild_ids = {},
        exclude_guild_ids = {},
        list_guilds = function()
            return {
                { guild_id = "guild/alpha", guild_name = "Alpha", chest_container_id = "container/alpha" },
            }
        end,
        resolve_guild_chest = function()
            return {
                container_id = "container/alpha",
                owner_guild_id = "guild/other",
                is_guild_chest = true,
                container = container,
            }
        end,
        snapshot_container = function(value)
            return snapshot.capture(readonly_adapter, value)
        end,
    })
end

local function platform_projection()
    return {
        preflight_ok = true,
        state = "CONNECTIVITY_PREFLIGHT_OK",
        certification = "UNPROVEN",
        diagnostic_only = true,
        evidence = {
            public_lobby = true,
            game_port = 8211,
            public_port = 8211,
            ini_public_port = 8211,
            required_platforms = { Steam = true, PS5 = true, Mac = true },
            xbox = false,
            client_mod_allowed = false,
            log_format = "Json",
        },
    }
end

local function build_context(overrides)
    local value = {
        audit = captured_audit(),
        mode = "audit",
        state = "AUDIT_COMPLETE",
        mod_version = "0.1.0-discovery",
        binding_manifest_checksum = string.rep("b", 64),
        platform_preflight = platform_projection(),
        conflict_summary = {
            coverage = "partial",
            blocking = false,
            forced_noop = false,
        },
        mod_inventory = {
            { package_name = "Zulu", package_version = "2.0.0" },
            { package_name = "Alpha", package_version = "10.0.0" },
            { package_name = "Alpha", package_version = "2.0.0" },
        },
        findings = {
            {
                code = "CGCE-PF-SAMPLE",
                severity = "WARNING",
                field = "platform",
                detail = "platform diagnostic",
                forced_noop = false,
            },
            {
                code = "CGCE-CONFLICT-COVERAGE-PARTIAL",
                severity = "WARNING",
                field = "policy.gate_a_accepted",
                detail = "collision coverage remains partial",
                forced_noop = false,
            },
        },
    }
    for key, item in pairs(overrides or {}) do
        value[key] = item
    end
    return value
end

local function filesystem(entries)
    local all_entries = {
        [ROOT] = "directory",
        [ROOT .. "\\artifacts"] = "directory",
    }
    for path, descriptor in pairs(entries or {}) do
        all_entries[path] = descriptor
    end
    return fake_filesystem.new({ entries = all_entries })
end

local function unsigned_checksum(value)
    local detached = json.decode(json.encode(value))
    detached.checksum = nil
    return sha256.hex(json.encode(detached))
end

describe("operational report", function()
    it("builds a deterministic discovery-only report from a trusted detached audit", function()
        local context = build_context()
        local value = report.build(context)

        a.equal("cgce.operational-report.v1", value.schema)
        a.equal("operational", value.report_kind)
        a.equal("discovery", value.build_kind)
        a.equal(false, value.release_eligible)
        a.equal("world/alpha", value.world_id)
        a.equal(12345, value.game_revision)
        a.equal(PROFILE, value.deployment_profile)
        a.equal(358, value.target_slots)
        a.equal(audit.checksum(context.audit), value.audit_checksum)
        a.equal(value.audit_checksum, value.audit.checksum)
        a.equal(string.rep("b", 64), value.binding_manifest_checksum)
        a.deep_equal({
            { package_name = "Alpha", package_version = "10.0.0" },
            { package_name = "Alpha", package_version = "2.0.0" },
            { package_name = "Zulu", package_version = "2.0.0" },
        }, value.mod_inventory)
        a.equal("CGCE-CONFLICT-COVERAGE-PARTIAL", value.findings[1].code)
        a.equal("CGCE-PF-SAMPLE", value.findings[2].code)
        a.equal("[]", json.encode(report.build(build_context({
            mod_inventory = {},
            findings = {},
        })).findings))
        a.equal(value.checksum, unsigned_checksum(value))
        a.equal(nil, json.encode(value):find("approval_token", 1, true))

        context.mod_inventory[1].package_name = "mutated"
        context.findings[1].detail = "mutated"
        a.equal("Zulu", value.mod_inventory[3].package_name)
        a.equal("platform diagnostic", value.findings[2].detail)
    end)

    it("accepts only post-audit terminal states and exact normalized projections", function()
        a.equal("AUDIT_COMPLETE", report.build(build_context()).state)
        a.equal("AWAITING_APPROVAL", report.build(build_context({
            mode = "apply",
            state = "AWAITING_APPROVAL",
            conflict_summary = {
                coverage = "complete",
                blocking = false,
                forced_noop = false,
            },
        })).state)
        a.equal("BLOCKED", report.build(build_context({
            audit = blocked_audit(),
            state = "BLOCKED",
        })).state)

        expect_error("CGCE-REPORT-STATE", "state", function()
            report.build(build_context({ state = "UNSUPPORTED" }))
        end)
        expect_error("CGCE-REPORT-FINDING", "findings[1].forced_noop", function()
            local findings = build_context().findings
            findings[1].forced_noop = nil
            report.build(build_context({ findings = findings }))
        end)
        local projection = platform_projection()
        projection.raw_args = "PalServer -AdminPassword=do-not-render"
        local err = expect_error(
            "CGCE-REPORT-PREFLIGHT",
            "platform_preflight.raw_args",
            function()
                report.build(build_context({ platform_preflight = projection }))
            end
        )
        a.equal(nil, err.detail:find("do-not-render", 1, true))

        local inconsistent = platform_projection()
        inconsistent.preflight_ok = false
        expect_error("CGCE-REPORT-PREFLIGHT", "platform_preflight.state", function()
            report.build(build_context({ platform_preflight = inconsistent }))
        end)

        local invalid_key = platform_projection()
        invalid_key.evidence.required_platforms[{}] = true
        err = expect_error(
            "CGCE-REPORT-PREFLIGHT",
            "platform_preflight.evidence.required_platforms[invalid-key]",
            function()
                report.build(build_context({ platform_preflight = invalid_key }))
            end
        )
        a.equal(nil, err.field:find("table:", 1, true))

        local forged_green = platform_projection()
        forged_green.evidence.required_platforms.Mac = false
        expect_error(
            "CGCE-REPORT-PREFLIGHT",
            "platform_preflight.evidence.required_platforms.Mac",
            function()
                report.build(build_context({ platform_preflight = forged_green }))
            end
        )

        forged_green = platform_projection()
        forged_green.evidence.game_port = nil
        expect_error(
            "CGCE-REPORT-PREFLIGHT",
            "platform_preflight.evidence.game_port",
            function()
                report.build(build_context({ platform_preflight = forged_green }))
            end
        )
    end)

    it("cross-checks exact conflict summary booleans against conflict findings", function()
        local findings = build_context().findings
        findings[1].code = "CGCE-CONFLICT-EXACT-BLOCKER"
        findings[1].severity = "BLOCKING"
        expect_error("CGCE-REPORT-CONFLICT", "conflict_summary.blocking", function()
            report.build(build_context({ findings = findings }))
        end)

        findings = build_context().findings
        findings[1].code = "CGCE-CONFLICT-EXACT-NOOP"
        findings[1].forced_noop = true
        expect_error("CGCE-REPORT-CONFLICT", "conflict_summary.forced_noop", function()
            report.build(build_context({ findings = findings }))
        end)
    end)

    it("rejects terminal states inconsistent with mode and blocking evidence", function()
        expect_error("CGCE-REPORT-STATE", "state", function()
            report.build(build_context({ mode = "audit", state = "AWAITING_APPROVAL" }))
        end)
        expect_error("CGCE-REPORT-STATE", "state", function()
            report.build(build_context({
                audit = blocked_audit(),
                state = "AUDIT_COMPLETE",
            }))
        end)

        local findings = build_context().findings
        findings[1] = {
            code = "CGCE-CONFLICT-EXACT-BLOCKER",
            severity = "BLOCKING",
            field = "conflict",
            detail = "exact collision",
            forced_noop = false,
        }
        expect_error("CGCE-REPORT-STATE", "state", function()
            report.build(build_context({
                state = "AUDIT_COMPLETE",
                conflict_summary = {
                    coverage = "complete",
                    blocking = true,
                    forced_noop = false,
                },
                findings = findings,
            }))
        end)

        local failed_preflight = platform_projection()
        failed_preflight.preflight_ok = false
        failed_preflight.state = "PS5_CONNECTIVITY_MISCONFIGURED"
        expect_error("CGCE-REPORT-STATE", "state", function()
            report.build(build_context({
                mode = "apply",
                state = "BLOCKED",
                platform_preflight = failed_preflight,
                conflict_summary = {
                    coverage = "complete",
                    blocking = false,
                    forced_noop = false,
                },
            }))
        end)
    end)

    it("rejects secret-bearing keys recursively instead of redacting them", function()
        local context = build_context()
        context.findings[1].API_KEY = "do-not-render"
        local err = expect_error("CGCE-REPORT-SECRET-KEY", "findings[1].API_KEY", function()
            report.build(context)
        end)
        a.equal(nil, err.detail:find("do-not-render", 1, true))

        context = build_context({ approval_token = "do-not-render" })
        err = expect_error("CGCE-REPORT-SECRET-KEY", "approval_token", function()
            report.build(context)
        end)
        a.equal(nil, err.detail:find("do-not-render", 1, true))
    end)

    it("revalidates checksums and returns a detached value", function()
        local value = report.build(build_context())
        local validated = report.validate(value)
        a.deep_equal(value, validated)
        a.equal(false, value == validated)
        a.equal(false, value.audit == validated.audit)

        value.audit.world_id = "world/forged"
        expect_error("CGCE-REPORT-AUDIT", "audit", function()
            report.validate(value)
        end)

        value = report.build(build_context())
        value.checksum = string.rep("0", 64)
        expect_error("CGCE-REPORT-CHECKSUM", "checksum", function()
            report.validate(value)
        end)

        expect_error("CGCE-REPORT-AUDIT", "audit", function()
            report.build(build_context({ audit = function() end }))
        end)
    end)

    it("rejects a caller-forged self-checksummed audit object during validate and persist", function()
        local value = report.build(build_context())
        value.audit.forged_authority = true
        local unsigned_audit = json.decode(json.encode(value.audit))
        unsigned_audit.checksum = nil
        value.audit.checksum = sha256.hex(json.encode(unsigned_audit))
        value.audit_checksum = value.audit.checksum
        local unsigned_report = json.decode(json.encode(value))
        unsigned_report.checksum = nil
        value.checksum = sha256.hex(json.encode(unsigned_report))

        expect_error("CGCE-REPORT-AUDIT", "audit.forged_authority", function()
            report.validate(value)
        end)
        local fs, observed = filesystem()
        expect_error("CGCE-REPORT-PROVENANCE", "report", function()
            report.persist(fs, ROOT, REPORT_PATH, value)
        end)
        a.equal(0, observed.writes)
    end)

    it("uses module-initialization audit accessors instead of mutable public slots", function()
        local handle = captured_audit()
        local originals = {
            to_table = audit.to_table,
            checksum = audit.checksum,
            canonical_json = audit.canonical_json,
        }
        audit.to_table = function()
            error("mutable public slot invoked")
        end
        audit.checksum = audit.to_table
        audit.canonical_json = audit.to_table

        local ok, value = pcall(report.build, build_context({ audit = handle }))

        audit.to_table = originals.to_table
        audit.checksum = originals.checksum
        audit.canonical_json = originals.canonical_json
        a.equal(true, ok)
        a.equal("world/alpha", value.world_id)
    end)

    it("persists only after checksum validation using the exact durable atomic sequence", function()
        local fs, observed = filesystem()
        local value = report.build(build_context())
        local receipt = report.persist(fs, ROOT, REPORT_PATH, value)

        a.deep_equal({
            "create_exclusive",
            "write_all",
            "flush_file",
            "close_file",
            "atomic_replace",
            "flush_directory",
            "read_all_no_follow",
        }, observed.persistence_sequence)
        a.deep_equal({
            path = ROOT .. "\\artifacts\\audit-report.json",
            relative_path = REPORT_PATH,
            report_checksum = value.checksum,
            audit_checksum = value.audit_checksum,
            byte_length = #json.encode(value),
            durable = true,
            read_back_verified = true,
        }, receipt)
        a.equal(1, observed.writes)
        a.equal(1, observed.atomic_replaces)
        a.equal(0, observed.host_io)
    end)

    it("persists only the unchanged table returned by this process report.build", function()
        local built = report.build(build_context())
        local decoded = json.decode(json.encode(built))
        a.deep_equal(built, report.validate(decoded))

        local fs, observed = filesystem()
        expect_error("CGCE-REPORT-PROVENANCE", "report", function()
            report.persist(fs, ROOT, REPORT_PATH, decoded)
        end)
        a.equal(0, observed.writes)

        built.mod_version = "0.1.1-forged"
        local unsigned = json.decode(json.encode(built))
        unsigned.checksum = nil
        built.checksum = sha256.hex(json.encode(unsigned))
        fs, observed = filesystem()
        expect_error("CGCE-REPORT-PROVENANCE", "report", function()
            report.persist(fs, ROOT, REPORT_PATH, built)
        end)
        a.equal(0, observed.writes)
    end)

    it("captures every filesystem function before invoking any caller port", function()
        local value = report.build(build_context())
        local fs, observed = filesystem()
        local capabilities = fs.capabilities
        fs.capabilities = function()
            fs.create_exclusive = function()
                error("late mutable slot")
            end
            fs.write_all = fs.create_exclusive
            fs.atomic_replace = fs.create_exclusive
            fs.read_all_no_follow = fs.create_exclusive
            return capabilities()
        end

        local receipt = report.persist(fs, ROOT, REPORT_PATH, value)
        a.equal(value.checksum, receipt.report_checksum)
        a.equal(1, observed.atomic_replaces)
        a.equal(1, observed.writes)
    end)

    it("blocks partial failures, preserves the original error, and never falls back", function()
        local value = report.build(build_context())
        value.checksum = string.rep("0", 64)
        local fs, observed = filesystem()
        expect_error("CGCE-REPORT-PROVENANCE", "report", function()
            report.persist(fs, ROOT, REPORT_PATH, value)
        end)
        a.equal(0, observed.writes)

        value = report.build(build_context())
        fs, observed = filesystem()
        local create_exclusive = fs.create_exclusive
        fs.create_exclusive = function(path)
            local handle = create_exclusive(path)
            return handle, "secondary approval_token=do-not-render"
        end
        local create_err = expect_error("CGCE-REPORT-PERSIST", "create_exclusive", function()
            report.persist(fs, ROOT, REPORT_PATH, value)
        end)
        a.equal(nil, create_err.detail:find("do-not-render", 1, true))
        a.deep_equal({ "create_exclusive", "close_file" }, observed.persistence_sequence)
        a.equal(1, observed.closes)

        value = report.build(build_context())
        fs, observed = filesystem()
        fs.write_all = function()
            error("approval_token=do-not-render")
        end
        local err = expect_error("CGCE-REPORT-PERSIST", "write_all", function()
            report.persist(fs, ROOT, REPORT_PATH, value)
        end)
        a.equal(nil, err.detail:find("do-not-render", 1, true))
        a.deep_equal({ "create_exclusive", "close_file" }, observed.persistence_sequence)
        a.equal(1, observed.closes)
        a.equal(0, observed.atomic_replaces)

        fs, observed = filesystem()
        fs.read_all_no_follow = function()
            return "different bytes"
        end
        expect_error("CGCE-REPORT-READBACK", "read_all_no_follow", function()
            report.persist(fs, ROOT, REPORT_PATH, value)
        end)
        a.equal(1, observed.atomic_replaces)
        a.equal(1, observed.directory_flushes)
        a.equal(1, observed.closes)
    end)
end)
