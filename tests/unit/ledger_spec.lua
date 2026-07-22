local a = require("tests.support.assertions")
local audit = require("CrossplayGuildChestExpander.Scripts.audit")
local fake_adapter = require("tests.support.fake_adapter")
local fake_filesystem = require("tests.support.fake_filesystem")
local json = require("CrossplayGuildChestExpander.Scripts.json")
local ledger = require("CrossplayGuildChestExpander.Scripts.ledger")
local sha256 = require("CrossplayGuildChestExpander.Scripts.sha256")
local snapshot = require("CrossplayGuildChestExpander.Scripts.snapshot")

local ROOT = "C:\\PalServer\\Pal\\Binaries\\Win64\\Mods\\CrossplayGuildChestExpander"
local LEDGER_PATH = "artifacts\\migration-ledger.json"
local TARGET_PATH = ROOT .. "\\artifacts\\migration-ledger.json"
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

local function slots(count, item)
    local result = {}
    for index = 1, count do
        result[index] = fake_adapter.slot(index == 1 and item or nil)
    end
    return result
end

local function audit_fixture(options)
    options = options or {}
    local list_calls = options.list_calls or { count = 0 }
    local resolve_calls = options.resolve_calls or {}
    local snapshot_calls = options.snapshot_calls or {}
    local guilds = options.guilds or {
        { guild_id = "guild/beta", guild_name = "Beta", chest_container_id = "container/beta" },
        { guild_id = "guild/alpha", guild_name = "Alpha", chest_container_id = "container/alpha" },
    }
    local alpha_container_id = options.alpha_container_id or "container/alpha"
    local beta_container_id = options.beta_container_id or "container/beta"
    local containers = options.containers or {
        [alpha_container_id] = fake_adapter.container({
            container_id = alpha_container_id,
            owner_guild_id = options.alpha_owner or "guild/alpha",
            slots = slots(options.alpha_slots or 54, options.alpha_item),
        }),
        [beta_container_id] = fake_adapter.container({
            container_id = beta_container_id,
            owner_guild_id = options.beta_owner or "guild/beta",
            slots = slots(options.beta_slots or 54, options.beta_item),
        }),
    }

    local context = {
        world_id = options.world_id or "world/alpha",
        game_revision = options.game_revision or 12345,
        deployment_profile = options.deployment_profile or PROFILE,
        target_slots = options.target_slots or 358,
        include_guild_ids = options.include_guild_ids or {},
        exclude_guild_ids = options.exclude_guild_ids or {},
        list_guilds = function()
            list_calls.count = list_calls.count + 1
            return guilds
        end,
        resolve_guild_chest = function(_, container_id)
            resolve_calls[#resolve_calls + 1] = container_id
            local container = containers[container_id]
            if container == nil then
                return nil
            end
            return {
                container_id = container_id,
                owner_guild_id = container.owner_guild_id,
                is_guild_chest = true,
                container = container,
            }
        end,
        snapshot_container = function(container)
            snapshot_calls[#snapshot_calls + 1] = container.container_id
            return snapshot.capture(readonly_adapter, container)
        end,
    }
    return context, list_calls, resolve_calls, snapshot_calls
end

local function find_audit_guild(handle, guild_id)
    for _, record in ipairs(audit.to_table(handle).guilds) do
        if record.guild_id == guild_id then
            return record
        end
    end
    error("missing audit guild " .. guild_id)
end

local function build_ledger(status)
    status = status or "VALIDATING_RESTART_REQUIRED"
    local source_handle = audit.capture(audit_fixture())
    local alpha = find_audit_guild(source_handle, "guild/alpha")
    local beta = find_audit_guild(source_handle, "guild/beta")
    return ledger.build({
        audit = source_handle,
        mod_version = "1.0.0",
        guilds = {
            {
                guild_id = "guild/beta",
                container_id = beta.snapshot.container_id,
                owner_guild_id = beta.snapshot.owner_guild_id,
                after_slots = 358,
                after_occupied_slot_count = beta.snapshot.occupied_slot_count,
                after_total_item_quantity = beta.snapshot.total_item_quantity,
                after_fingerprint = beta.snapshot.item_fingerprint,
                status = status,
                restart_required = status == "VALIDATING_RESTART_REQUIRED",
            },
            {
                guild_id = "guild/alpha",
                container_id = alpha.snapshot.container_id,
                owner_guild_id = alpha.snapshot.owner_guild_id,
                after_slots = 358,
                after_occupied_slot_count = alpha.snapshot.occupied_slot_count,
                after_total_item_quantity = alpha.snapshot.total_item_quantity,
                after_fingerprint = alpha.snapshot.item_fingerprint,
                status = status,
                restart_required = status == "VALIDATING_RESTART_REQUIRED",
            },
        },
    })
end

local function filesystem_with(optional_ledger)
    local entries = {
        [ROOT] = "directory",
        [ROOT .. "\\artifacts"] = "directory",
    }
    if optional_ledger ~= nil then
        local content = type(optional_ledger) == "string"
            and optional_ledger
            or json.encode(optional_ledger)
        entries[TARGET_PATH] = { kind = "file", content = content }
    end
    return fake_filesystem.new({ entries = entries })
end

local function finding_codes(result)
    local codes = {}
    for index, finding in ipairs(result.findings) do
        codes[index] = finding.code
    end
    return codes
end

local function has_code(result, expected)
    for _, code in ipairs(finding_codes(result)) do
        if code == expected then
            return true
        end
    end
    return false
end

describe("migration ledger", function()
    it("derives the source identity and before snapshots from a trusted Task 5 audit", function()
        local value = build_ledger()

        a.equal("1.0", value.ledger_version)
        a.equal("world/alpha", value.world_id)
        a.equal(12345, value.game_revision)
        a.equal(PROFILE, value.deployment_profile)
        a.equal(358, value.target_slots)
        a.equal(64, #value.source_audit_checksum)
        a.equal("guild/alpha", value.guilds[1].guild_id)
        a.equal("guild/beta", value.guilds[2].guild_id)
        for _, guild in ipairs(value.guilds) do
            a.equal(54, guild.before_slots)
            a.equal(358, guild.after_slots)
            a.equal(0, guild.before_occupied_slot_count)
            a.equal(0, guild.after_occupied_slot_count)
            a.equal(guild.before_fingerprint, guild.after_fingerprint)
            a.equal(true, guild.restart_required)
        end

        local detached = json.decode(json.encode(value))
        detached.checksum = nil
        a.equal(sha256.hex(json.encode(detached)), value.checksum)
        a.equal(nil, json.encode(value):find("dynamic_guid", 1, true))
        a.equal(nil, json.encode(value):find('"slots"', 1, true))
        a.equal(nil, json.encode(value):find("approval_token", 1, true))
    end)

    it("cross-validates ledger identity and invariants against the source audit", function()
        local source_handle = audit.capture(audit_fixture())
        local base = {
            audit = source_handle,
            mod_version = "1.0.0",
            guilds = {
                {
                    guild_id = "guild/alpha",
                    container_id = "container/alpha",
                    owner_guild_id = "guild/alpha",
                    after_slots = 358,
                    after_occupied_slot_count = 0,
                    after_total_item_quantity = 0,
                    after_fingerprint = find_audit_guild(source_handle, "guild/alpha").snapshot.item_fingerprint,
                    status = "VALIDATING_RESTART_REQUIRED",
                    restart_required = true,
                },
            },
        }

        local bad_owner = json.decode(json.encode(base.guilds[1]))
        bad_owner.owner_guild_id = "guild/other"
        expect_error("CGCE-LEDGER-AUDIT-MISMATCH", "guilds[1].owner_guild_id", function()
            ledger.build({ audit = source_handle, mod_version = "1.0.0", guilds = { bad_owner } })
        end)

        local bad_count = json.decode(json.encode(base.guilds[1]))
        bad_count.after_occupied_slot_count = 1
        expect_error("CGCE-LEDGER-INVARIANT", "guilds[1].after_occupied_slot_count", function()
            ledger.build({ audit = source_handle, mod_version = "1.0.0", guilds = { bad_count } })
        end)

        local bad_status = json.decode(json.encode(base.guilds[1]))
        bad_status.restart_required = false
        expect_error("CGCE-LEDGER-STATUS", "guilds[1].restart_required", function()
            ledger.build({ audit = source_handle, mod_version = "1.0.0", guilds = { bad_status } })
        end)

        local secret = json.decode(json.encode(base.guilds[1]))
        secret.private_key = "do-not-render"
        local err = expect_error("CGCE-LEDGER-SECRET-KEY", "guilds[1].private_key", function()
            ledger.build({ audit = source_handle, mod_version = "1.0.0", guilds = { secret } })
        end)
        a.equal(nil, err.detail:find("do-not-render", 1, true))
    end)

    it("loads missing, malformed, read-failed, and valid ledgers distinctly", function()
        local fs = filesystem_with()
        a.deep_equal({ status = "MISSING" }, ledger.load(fs, ROOT, LEDGER_PATH))

        fs = filesystem_with("{not-json")
        local malformed = ledger.load(fs, ROOT, LEDGER_PATH)
        a.equal("MALFORMED", malformed.status)
        a.equal("CGCE-LEDGER-MALFORMED", malformed.error.code)

        fs = filesystem_with(build_ledger())
        fs.read_all_no_follow = function()
            error("approval_token=do-not-render")
        end
        local failed = ledger.load(fs, ROOT, LEDGER_PATH)
        a.equal("READ_FAILED", failed.status)
        a.equal("CGCE-LEDGER-READ-FAILED", failed.error.code)
        a.equal(nil, failed.error.detail:find("do-not-render", 1, true))

        local value = build_ledger()
        fs = filesystem_with(value)
        local loaded = ledger.load(fs, ROOT, LEDGER_PATH)
        a.equal("LOADED", loaded.status)
        a.deep_equal(value, loaded.ledger)
        a.equal(false, value == loaded.ledger)

        fs = filesystem_with(value)
        fs.read_all_no_follow = function()
            return nil, "permission denied: approval_token=do-not-render"
        end
        failed = ledger.load(fs, ROOT, LEDGER_PATH)
        a.equal("READ_FAILED", failed.status)
        a.equal("CGCE-LEDGER-READ-FAILED", failed.error.code)
        a.equal(nil, failed.error.detail:find("do-not-render", 1, true))
    end)

    it("saves with the same exclusive durable atomic guarantees", function()
        local value = build_ledger()
        local fs, observed = filesystem_with()
        local receipt = ledger.save(fs, ROOT, LEDGER_PATH, value)

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
            path = TARGET_PATH,
            relative_path = LEDGER_PATH,
            ledger_checksum = value.checksum,
            source_audit_checksum = value.source_audit_checksum,
            byte_length = #json.encode(value),
            durable = true,
            read_back_verified = true,
        }, receipt)
        a.equal(1, observed.writes)
        a.equal(1, observed.atomic_replaces)
        a.equal(0, observed.host_io)
    end)

    it("saves only the unchanged table returned by this process ledger.build", function()
        local built = build_ledger()
        local decoded = json.decode(json.encode(built))
        local fs, observed = filesystem_with()
        expect_error("CGCE-LEDGER-PROVENANCE", "ledger", function()
            ledger.save(fs, ROOT, LEDGER_PATH, decoded)
        end)
        a.equal(0, observed.writes)

        built.mod_version = "1.0.1-forged"
        local unsigned = json.decode(json.encode(built))
        unsigned.checksum = nil
        built.checksum = sha256.hex(json.encode(unsigned))
        fs, observed = filesystem_with()
        expect_error("CGCE-LEDGER-PROVENANCE", "ledger", function()
            ledger.save(fs, ROOT, LEDGER_PATH, built)
        end)
        a.equal(0, observed.writes)
    end)

    it("closes an opaque temp handle returned with a secondary create failure", function()
        local value = build_ledger()
        local fs, observed = filesystem_with()
        local create_exclusive = fs.create_exclusive
        fs.create_exclusive = function(path)
            local handle = create_exclusive(path)
            return handle, "secondary approval_token=do-not-render"
        end
        local err = expect_error("CGCE-LEDGER-SAVE", "create_exclusive", function()
            ledger.save(fs, ROOT, LEDGER_PATH, value)
        end)

        a.equal(nil, err.detail:find("do-not-render", 1, true))
        a.deep_equal({ "create_exclusive", "close_file" }, observed.persistence_sequence)
        a.equal(1, observed.closes)
        a.equal(0, observed.atomic_replaces)
    end)

    it("best-effort closes a non-nil invalid create result exactly once", function()
        local value = build_ledger()
        local fs, observed = filesystem_with()
        local invalid_handle = { forged = true }
        local close_calls = 0
        fs.create_exclusive = function()
            return invalid_handle
        end
        fs.close_file = function(actual)
            close_calls = close_calls + 1
            a.equal(invalid_handle, actual)
            error("approval_token=do-not-render")
        end

        local err = expect_error("CGCE-LEDGER-SAVE", "create_exclusive", function()
            ledger.save(fs, ROOT, LEDGER_PATH, value)
        end)

        a.equal(1, close_calls)
        a.equal(nil, err.detail:find("do-not-render", 1, true))
        a.equal(0, observed.writes)
        a.equal(0, observed.atomic_replaces)
    end)

    it("always captures and inspects fresh live state even for a completed matching ledger", function()
        local value = build_ledger("COMPLETE")
        local fs, observed = filesystem_with(value)
        local calls = { count = 0 }
        local live_context, _, resolve_calls, snapshot_calls = audit_fixture({
            alpha_slots = 358,
            beta_slots = 358,
            list_calls = calls,
        })

        local first = ledger.verify(fs, ROOT, LEDGER_PATH, live_context)
        local second = ledger.verify(fs, ROOT, LEDGER_PATH, live_context)

        a.equal(2, calls.count)
        a.equal("MATCH", first.status)
        a.equal("MATCH", second.status)
        a.equal(false, first.can_mark_completed)
        a.equal(false, second.can_mark_completed)
        a.equal(0, observed.writes)
        a.equal(0, observed.atomic_replaces)
        a.deep_equal({
            "container/alpha",
            "container/beta",
            "container/alpha",
            "container/beta",
        }, resolve_calls)
        a.deep_equal(resolve_calls, snapshot_calls)
        a.deep_equal({ "guild/alpha", "guild/beta" }, {
            first.guilds[1].guild_id,
            first.guilds[2].guild_id,
        })
    end)

    it("marks restart-required as completable only after every exact live match", function()
        local value = build_ledger()
        local fs = filesystem_with(value)
        local live_context = audit_fixture({ alpha_slots = 358, beta_slots = 358 })
        local result = ledger.verify(fs, ROOT, LEDGER_PATH, live_context)

        a.equal("MATCH", result.status)
        a.equal(true, result.can_mark_completed)
        a.equal(value.checksum, result.ledger_checksum)
        a.equal(0, #result.findings)

        local reloaded = ledger.load(fs, ROOT, LEDGER_PATH)
        a.equal("VALIDATING_RESTART_REQUIRED", reloaded.ledger.guilds[1].status)
        a.equal(true, reloaded.ledger.guilds[1].restart_required)
    end)

    it("reports revision, target, container, owner, and item drift deterministically", function()
        local value = build_ledger()

        local fs = filesystem_with(value)
        local revision = ledger.verify(fs, ROOT, LEDGER_PATH, audit_fixture({
            game_revision = 12346,
            alpha_slots = 358,
            beta_slots = 358,
        }))
        a.equal("DRIFT", revision.status)
        a.equal(true, has_code(revision, "CGCE-LEDGER-REVISION-DRIFT"))

        fs = filesystem_with(value)
        local target = ledger.verify(fs, ROOT, LEDGER_PATH, audit_fixture({
            target_slots = 256,
            alpha_slots = 358,
            beta_slots = 358,
        }))
        a.equal("DRIFT", target.status)
        a.equal(true, has_code(target, "CGCE-LEDGER-TARGET-DRIFT"))

        fs = filesystem_with(value)
        local container = ledger.verify(fs, ROOT, LEDGER_PATH, audit_fixture({
            guilds = {
                { guild_id = "guild/alpha", guild_name = "Alpha", chest_container_id = "container/changed" },
                { guild_id = "guild/beta", guild_name = "Beta", chest_container_id = "container/beta" },
            },
            alpha_container_id = "container/changed",
            alpha_slots = 358,
            beta_slots = 358,
        }))
        a.equal("DRIFT", container.status)
        a.equal(true, has_code(container, "CGCE-LEDGER-CONTAINER-DRIFT"))

        fs = filesystem_with(value)
        local owner = ledger.verify(fs, ROOT, LEDGER_PATH, audit_fixture({
            alpha_owner = "guild/other",
            alpha_slots = 358,
            beta_slots = 358,
        }))
        a.equal("AUDIT_BLOCKED", owner.status)
        a.equal(true, has_code(owner, "CGCE-LEDGER-OWNER-DRIFT"))

        fs = filesystem_with(value)
        local item = ledger.verify(fs, ROOT, LEDGER_PATH, audit_fixture({
            alpha_slots = 358,
            beta_slots = 358,
            alpha_item = fake_adapter.item({ dynamic_guid = "guid/changed" }),
        }))
        a.equal("DRIFT", item.status)
        a.equal(true, has_code(item, "CGCE-LEDGER-FINGERPRINT-DRIFT"))
        a.equal(false, item.can_mark_completed)
        local sorted = finding_codes(item)
        local resorted = { table.unpack(sorted) }
        table.sort(resorted)
        a.deep_equal(resorted, sorted)
    end)

    it("captures a fresh audit before any load outcome and never uses mutable public audit slots", function()
        local value = build_ledger()
        local fs = filesystem_with("{not-json")
        local calls = { count = 0 }
        local live_context = audit_fixture({
            alpha_slots = 358,
            beta_slots = 358,
            list_calls = calls,
        })
        local original_capture = audit.capture
        local original_to_table = audit.to_table
        local original_checksum = audit.checksum
        audit.capture = function()
            error("mutable public capture slot invoked")
        end
        audit.to_table = audit.capture
        audit.checksum = audit.capture

        local ok, result = pcall(ledger.verify, fs, ROOT, LEDGER_PATH, live_context)

        audit.capture = original_capture
        audit.to_table = original_to_table
        audit.checksum = original_checksum
        a.equal(true, ok)
        a.equal("MALFORMED", result.status)
        a.equal(1, calls.count)

        fs = filesystem_with(value)
        calls.count = 0
        live_context = audit_fixture({
            alpha_slots = 358,
            beta_slots = 358,
            list_calls = calls,
        })
        result = ledger.verify(fs, ROOT, LEDGER_PATH, live_context)
        a.equal("MATCH", result.status)
        a.equal(1, calls.count)
    end)

    it("reports a ledger guild missing from the fresh audit deterministically", function()
        local value = build_ledger()
        local fs = filesystem_with(value)
        local live_context = audit_fixture({
            guilds = {
                { guild_id = "guild/alpha", guild_name = "Alpha", chest_container_id = "container/alpha" },
            },
            alpha_slots = 358,
        })
        local result = ledger.verify(fs, ROOT, LEDGER_PATH, live_context)

        a.equal("DRIFT", result.status)
        a.equal(true, has_code(result, "CGCE-LEDGER-GUILD-MISSING"))
        a.deep_equal({ "guild/alpha", "guild/beta" }, {
            result.guilds[1].guild_id,
            result.guilds[2].guild_id,
        })
        a.equal("MATCH", result.guilds[1].status)
        a.equal("MISSING", result.guilds[2].status)
    end)

    it("reports every live matched, no-chest, excluded, noop, and untracked guild", function()
        local source_context = audit_fixture({
            guilds = {
                { guild_id = "guild/alpha", guild_name = "Alpha", chest_container_id = "container/alpha" },
            },
        })
        local source_handle = audit.capture(source_context)
        local source_alpha = find_audit_guild(source_handle, "guild/alpha").snapshot
        local value = ledger.build({
            audit = source_handle,
            mod_version = "1.0.0",
            guilds = {
                {
                    guild_id = "guild/alpha",
                    container_id = "container/alpha",
                    owner_guild_id = "guild/alpha",
                    after_slots = 358,
                    after_occupied_slot_count = 0,
                    after_total_item_quantity = 0,
                    after_fingerprint = source_alpha.item_fingerprint,
                    status = "COMPLETE",
                    restart_required = false,
                },
            },
        })
        local containers = {
            ["container/alpha"] = fake_adapter.container({
                container_id = "container/alpha",
                owner_guild_id = "guild/alpha",
                slots = slots(358),
            }),
            ["container/gamma"] = fake_adapter.container({
                container_id = "container/gamma",
                owner_guild_id = "guild/gamma",
                slots = slots(54),
            }),
            ["container/delta"] = fake_adapter.container({
                container_id = "container/delta",
                owner_guild_id = "guild/delta",
                slots = slots(400),
            }),
            ["container/epsilon"] = fake_adapter.container({
                container_id = "container/epsilon",
                owner_guild_id = "guild/epsilon",
                slots = slots(54),
            }),
        }
        local live_context, list_calls, resolve_calls, snapshot_calls = audit_fixture({
            guilds = {
                { guild_id = "guild/epsilon", guild_name = "Epsilon", chest_container_id = "container/epsilon" },
                { guild_id = "guild/beta", guild_name = "Beta" },
                { guild_id = "guild/delta", guild_name = "Delta", chest_container_id = "container/delta" },
                { guild_id = "guild/alpha", guild_name = "Alpha", chest_container_id = "container/alpha" },
                { guild_id = "guild/gamma", guild_name = "Gamma", chest_container_id = "container/gamma" },
            },
            containers = containers,
            exclude_guild_ids = { "guild/gamma" },
        })
        local result = ledger.verify(filesystem_with(value), ROOT, LEDGER_PATH, live_context)
        local statuses = {}
        for _, record in ipairs(result.guilds) do
            statuses[record.guild_id] = record.status
        end

        a.equal("DRIFT", result.status)
        a.equal("MATCH", statuses["guild/alpha"])
        a.equal("NOT_INITIALIZED", statuses["guild/beta"])
        a.equal("NOOP_UNTRACKED", statuses["guild/delta"])
        a.equal("UNTRACKED", statuses["guild/epsilon"])
        a.equal("EXCLUDED", statuses["guild/gamma"])
        a.equal(true, has_code(result, "CGCE-LEDGER-GUILD-UNTRACKED"))
        a.equal(1, list_calls.count)
        a.deep_equal({
            "container/alpha",
            "container/delta",
            "container/epsilon",
            "container/gamma",
        }, resolve_calls)
        a.deep_equal(resolve_calls, snapshot_calls)
    end)
end)
