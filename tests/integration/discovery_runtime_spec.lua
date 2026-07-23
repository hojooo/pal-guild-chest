local a = require("tests.support.assertions")
local approval = require("CrossplayGuildChestExpander.Scripts.approval")
local fake_adapter = require("tests.support.fake_adapter")
local fake_filesystem = require("tests.support.fake_filesystem")
local json = require("CrossplayGuildChestExpander.Scripts.json")
local report = require("CrossplayGuildChestExpander.Scripts.report")
local revision_guard = require("CrossplayGuildChestExpander.Scripts.revision_guard")
local runtime_binding_fixture = require("tests.support.runtime_binding_fixture")
local snapshot = require("CrossplayGuildChestExpander.Scripts.snapshot")
local cgce = require("CrossplayGuildChestExpander.Scripts.cgce")
local ue4ss_adapter = require("CrossplayGuildChestExpander.Scripts.ue4ss_adapter")

local ROOT = "C:\\PalServer\\Pal\\Binaries\\Win64\\Mods\\CrossplayGuildChestExpander"
local CONFIG_PATH = "config\\config.default.json"
local BINDINGS_DIRECTORY = "Scripts\\bindings"
local REPORT_PATH = "artifacts\\audit-report.json"
local LEDGER_PATH = "data\\migration-ledger.json"

local function read(path)
    local file = assert(io.open(path, "rb"))
    local bytes = assert(file:read("*a"))
    file:close()
    return bytes
end

local default_config = read("CrossplayGuildChestExpander/config/config.default.json")

local function capture_live_snapshot(container, adapter, binding)
    local function descriptor(name)
        return revision_guard.descriptor(binding, name)
    end
    local function property(object, name)
        return ue4ss_adapter.read_property(adapter, object, descriptor(name))
    end
    return snapshot.capture({
        container_id = function(value)
            return property(value, "container_id_property")
        end,
        owner_guild_id = function(value)
            return property(value, "container_owner_guild_id_property")
        end,
        slots = function(value)
            return property(value, "slot_array_property")
        end,
        slot_item = function(slot)
            local occupied = property(slot, "slot_occupancy_discriminator_property")
            if occupied == false then
                return nil
            end
            if occupied ~= true then
                error("slot occupancy discriminator must be an exact boolean")
            end
            return {
                static_id = property(slot, "item_static_id_property"),
                dynamic_guid = property(slot, "item_dynamic_guid_property"),
                quantity = property(slot, "item_quantity_property"),
                durability = property(slot, "item_durability_property"),
                instance_metadata_hash = property(slot, "item_metadata_hash_inputs_property"),
            }
        end,
    }, container)
end

local forbidden_counters = {
    "function_invoke",
    "raw_property_write",
    "tarray_write",
    "element_set",
    "array_empty",
    "array_index_write",
    "constructor",
}

local function assert_no_mutation(runtime)
    local counters = runtime.fake.counters()
    for _, name in ipairs(forbidden_counters) do
        a.equal(0, counters[name])
    end
end

local function find_finding(built, code, field)
    for _, finding in ipairs(built.findings or {}) do
        if finding.code == code and (field == nil or finding.field == field) then
            return finding
        end
    end
    return nil
end

local function expect_problem(code, field, operation)
    local ok, err = pcall(operation)
    a.equal(false, ok)
    a.equal("table", type(err))
    a.equal(code, err.code)
    a.equal(field, err.field)
    a.equal("string", type(err.detail))
    a.equal(nil, err.detail:find("0x", 1, true))
    return err
end

local function timers()
    local value = { scheduled = 0, cancelled = 0, records = {} }

    function value.schedule(delay, callback)
        a.equal(1, delay)
        value.scheduled = value.scheduled + 1
        local token = function() end
        value.records[#value.records + 1] = {
            token = token,
            callback = callback,
            cancelled = false,
            fired = false,
        }
        return token
    end

    function value.cancel(token)
        value.cancelled = value.cancelled + 1
        for _, record in ipairs(value.records) do
            if record.token == token then
                record.cancelled = true
                return true
            end
        end
        return false
    end

    function value:fire_next()
        for _, record in ipairs(self.records) do
            if not record.cancelled and not record.fired then
                record.fired = true
                record.callback()
                return true
            end
        end
        return false
    end

    function value:fire_late(index)
        self.records[index].callback()
    end

    return value
end

local function platform_inputs()
    return {
        args = {
            "PalServer.exe",
            "-publiclobby",
            "-port=8211",
            "-publicport=8211",
        },
        option_settings = table.concat({
            "OptionSettings=(CrossplayPlatforms=(Steam,PS5,Mac)",
            ",bAllowClientMod=False",
            ",PublicPort=8211",
            ",LogFormatType=Json)",
        }),
    }
end

local function conflict_inventory(target, gate_a_accepted)
    return {
        policy = {
            policy_version = "1.0",
            verified = true,
            gate_a_accepted = gate_a_accepted == true,
            target_slots = target,
            known_slot_counts = { 54, 120, 256, 358 },
            paths = {
                owner_package = "/CGCE/Server",
                target_default = "/Game/Exact/GuildChestDefault",
                container_resizer_hook = "/Script/Exact.Container:Resize",
                guild_chest_storage = "/Save/Exact/GuildChestStorage",
            },
            types = {
                container_class = {
                    path = "/Script/Exact.GuildChestContainer",
                    type_signature = "class(/Script/Exact.GuildChestContainer)",
                },
                slot = {
                    path = "/Script/Exact.GuildChestSlot",
                    type_signature = "struct(/Script/Exact.GuildChestSlot)",
                },
            },
        },
        mods = {},
        hooks = {},
        containers = {},
    }
end

local function read_only_filesystem(fs, observations, options, context)
    return {
        capabilities = fs.capabilities,
        canonicalize = function(path)
            if options.canonicalize ~= nil then
                return options.canonicalize(context, path, fs.canonicalize)
            end
            return fs.canonicalize(path)
        end,
        inspect_no_follow = fs.inspect_no_follow,
        propose_temp_sibling = fs.propose_temp_sibling,
        read_all_no_follow = function(path)
            if path == ROOT .. "\\config\\config.default.json" then
                observations.config_reads = observations.config_reads + 1
                if options.on_config_read ~= nil then
                    options.on_config_read(context)
                end
            elseif path == ROOT .. "\\Scripts\\bindings\\123456.json" then
                observations.manifest_reads = observations.manifest_reads + 1
            elseif path == ROOT .. "\\data\\migration-ledger.json" then
                observations.ledger_reads = observations.ledger_reads + 1
                if options.on_ledger_read ~= nil then
                    options.on_ledger_read(context)
                end
            elseif path == ROOT .. "\\artifacts\\audit-report.json" then
                observations.report_reads = observations.report_reads + 1
                if options.on_report_read ~= nil then
                    options.on_report_read(context)
                end
                if options.report_read_override ~= nil then
                    return options.report_read_override(context, path)
                end
            end
            return fs.read_all_no_follow(path)
        end,
    }
end

local function fixture(options)
    options = options or {}
    local runtime = runtime_binding_fixture.new({ ready = options.ready })
    local live_slots
    local live_chest
    if options.with_guild then
        live_slots = {}
        for index = 1, 54 do
            live_slots[index] = runtime:add_slot(
                options.slot_items and options.slot_items[index] or nil
            )
        end
        runtime:add_guild("guild/alpha", "Alpha", "container/alpha")
        live_chest = runtime:add_guild_chest("container/alpha", "guild/alpha", {
            slots = live_slots,
        })
    end
    local timer = timers()
    local observations = {
        config_reads = 0,
        manifest_reads = 0,
        ledger_reads = 0,
        revision_reads = 0,
        platform_reads = 0,
        conflict_reads = 0,
        snapshot_reads = 0,
        persists = 0,
        report_reads = 0,
    }
    local entries = {
        [ROOT] = "directory",
        [ROOT .. "\\config"] = "directory",
        [ROOT .. "\\Scripts"] = "directory",
        [ROOT .. "\\Scripts\\bindings"] = "directory",
        [ROOT .. "\\data"] = "directory",
        [ROOT .. "\\config\\config.default.json"] = {
            kind = "file",
            content = options.config_text or default_config,
        },
    }
    if options.missing_report_parent ~= true then
        entries[ROOT .. "\\artifacts"] = "directory"
    end
    if options.manifest_missing ~= true then
        entries[ROOT .. "\\Scripts\\bindings\\123456.json"] = {
            kind = "file",
            content = options.manifest_text or json.encode(runtime.manifest),
        }
    end
    if options.ledger_text ~= nil then
        entries[ROOT .. "\\data\\migration-ledger.json"] = {
            kind = "file",
            content = options.ledger_text,
        }
    end
    for path, descriptor in pairs(options.extra_entries or {}) do
        entries[path] = descriptor
    end
    local fs = fake_filesystem.new({
        entries = entries,
        canonical_overrides = options.canonical_overrides,
    })
    local context = {
        runtime = runtime,
        timers = timer,
        observations = observations,
        fs = fs,
        live_chest = live_chest,
        live_slots = live_slots,
    }
    local dependencies = {
        package_root = ROOT,
        config_relative_path = CONFIG_PATH,
        bindings_relative_directory = BINDINGS_DIRECTORY,
        report_relative_path = REPORT_PATH,
        ledger_relative_path = LEDGER_PATH,
        mod_version = "1.1.0-discovery",
        filesystem_read = read_only_filesystem(fs, observations, options, context),
        persist_operational_report = function(built)
            observations.persists = observations.persists + 1
            if options.persist ~= nil then
                return options.persist(context, built)
            end
            if options.on_persist ~= nil then
                options.on_persist(context, built)
            end
            return report.persist(fs, ROOT, REPORT_PATH, built)
        end,
        ue4ss_port = runtime.port,
        read_live_revision = function()
            observations.revision_reads = observations.revision_reads + 1
            a.equal(1, observations.config_reads)
            if options.on_revision_read ~= nil then
                options.on_revision_read(context)
            end
            return 123456
        end,
        read_platform_inputs = function()
            observations.platform_reads = observations.platform_reads + 1
            if options.platform_port ~= nil then
                return options.platform_port(context)
            end
            if options.platform_inputs ~= nil then
                return options.platform_inputs
            end
            return platform_inputs()
        end,
        read_conflict_inventory = function(_, _, _, target)
            observations.conflict_reads = observations.conflict_reads + 1
            if options.on_conflict_read ~= nil then
                options.on_conflict_read(context)
            end
            if type(options.conflict_inventory) == "function" then
                return options.conflict_inventory(target)
            end
            if options.conflict_inventory ~= nil then
                return options.conflict_inventory
            end
            return conflict_inventory(target, options.gate_a_accepted)
        end,
        capture_container_snapshot = function(container, adapter, binding, _)
            observations.snapshot_reads = observations.snapshot_reads + 1
            if not options.with_guild then
                error("empty guild inventory must not request a snapshot")
            end
            if options.capture_container_snapshot ~= nil then
                return options.capture_container_snapshot(container, adapter, binding)
            end
            a.equal("function", type(container))
            return capture_live_snapshot(container, adapter, binding)
        end,
        schedule = timer.schedule,
        cancel = timer.cancel,
    }
    context.dependencies = dependencies
    return context
end

describe("discovery runtime orchestration", function()
    it("accepts only the exact dependency surface and rejects write-capable additions", function()
        local top = fixture()
        top.dependencies.unexpected = function() end
        expect_problem("CGCE-RUNTIME-DEPENDENCIES", "unexpected", function()
            cgce.new(top.dependencies)
        end)

        local fs = fixture()
        fs.dependencies.filesystem_read.write_all = function() return true end
        expect_problem("CGCE-RUNTIME-DEPENDENCIES", "filesystem_read.write_all", function()
            cgce.new(fs.dependencies)
        end)

        local ue4ss = fixture()
        ue4ss.dependencies.ue4ss_port.set_property_value = function() return true end
        expect_problem("CGCE-UE4SS-PORT-UNKNOWN", "set_property_value", function()
            cgce.new(ue4ss.dependencies)
        end)
    end)

    it("rejects every command before start and after shutdown without touching command ports", function()
        local value = fixture()
        local app = cgce.new(value.dependencies)
        local before_start = value.runtime.fake.counters()

        local early, early_error = app:handle_command("cgce apply")

        a.equal(nil, early)
        a.equal("CGCE-RUNTIME-LIFECYCLE", early_error.code)
        a.deep_equal(before_start, value.runtime.fake.counters())

        a.equal("AUDIT_COMPLETE", assert(app:start()).state)
        a.equal(true, app:shutdown())
        local after_shutdown = value.runtime.fake.counters()

        local late, late_error = app:handle_command("cgce status")

        a.equal(nil, late)
        a.equal("CGCE-RUNTIME-LIFECYCLE", late_error.code)
        a.deep_equal(after_shutdown, value.runtime.fake.counters())
    end)

    it("keeps a captured module cleanup entrypoint usable if an app table is raw-shadowed", function()
        local value = fixture({ ready = false })
        local app = cgce.new(value.dependencies)
        a.equal("WAITING", assert(cgce.start(app)).state)
        rawset(app, "shutdown", function()
            error("shadowed app cleanup must not be trusted")
        end)

        local closed, errors = cgce.shutdown(app)

        a.equal(true, closed)
        a.deep_equal({}, errors)
        a.equal(1, value.runtime.fake.counters().unregister_hook)
    end)

    it("runs immediate readiness through one fresh audit and persists before terminal transition", function()
        local value
        value = fixture({
            on_persist = function(context, built)
                a.equal("AUDIT_COMPLETE", built.state)
                local status, err = context.app:handle_command("cgce status")
                a.equal(nil, err)
                a.equal("AUDIT", status.state)
            end,
        })
        value.app = cgce.new(value.dependencies)

        local result, err = value.app:start()

        a.equal(nil, err)
        a.deep_equal({
            state = "AUDIT_COMPLETE",
            pending = false,
            terminal = true,
            report_persisted = true,
            errors = {},
        }, result)
        a.equal(1, value.observations.revision_reads)
        a.equal(1, value.observations.manifest_reads)
        a.equal(1, value.observations.platform_reads)
        a.equal(1, value.observations.conflict_reads)
        a.equal(1, value.observations.ledger_reads)
        a.equal(0, value.observations.snapshot_reads)
        a.equal(1, value.observations.persists)

        local exported = assert(value.app:handle_command("cgce export-report"))
        a.equal(ROOT .. "\\artifacts\\audit-report.json", exported.payload.path)
        local audited = assert(value.app:handle_command("cgce audit"))
        a.equal("cgce.audit.v1", audited.payload.schema)
        local guilds = assert(value.app:handle_command("cgce guilds"))
        a.deep_equal({}, guilds.payload)
        local verified = assert(value.app:handle_command("cgce verify"))
        a.equal("MISSING", verified.payload.status)
        a.equal(1, value.observations.persists)
        local apply, apply_error = value.app:handle_command("cgce apply")
        a.equal(nil, apply)
        a.equal("MUTATION_BUILD_UNAVAILABLE", apply_error.code)

        local duplicate, duplicate_error = value.app:start()
        a.equal(nil, duplicate)
        a.equal("CGCE-RUNTIME-LIFECYCLE", duplicate_error.code)
        local closed, close_errors = value.app:shutdown()
        a.equal(true, closed)
        a.deep_equal({}, close_errors)
        local closed_again, close_errors_again = value.app:shutdown()
        a.equal(true, closed_again)
        a.deep_equal({}, close_errors_again)
        assert_no_mutation(value.runtime)
    end)

    it("projects the exact resolved live container through an epoch-bound snapshot bridge", function()
        local built_report
        local value = fixture({
            with_guild = true,
            on_persist = function(_, built)
                built_report = built
            end,
        })
        value.runtime:set_slot_item(value.live_slots[1], fake_adapter.item({
            static_id = "PalItem/LiveStone",
            dynamic_guid = "guid/live-slot-1",
            quantity = 7,
            durability = "87.500000",
            instance_metadata_hash = string.rep("b", 64),
        }))
        local app = cgce.new(value.dependencies)

        local result = assert(app:start())

        a.equal("AUDIT_COMPLETE", result.state)
        a.equal(1, value.observations.snapshot_reads)
        a.equal(1, #built_report.audit.guilds)
        a.equal("eligible_noop", built_report.audit.guilds[1].status)
        a.equal(54, built_report.audit.guilds[1].snapshot.slot_count)
        a.equal(1, built_report.audit.guilds[1].snapshot.occupied_slot_count)
        a.equal(7, built_report.audit.guilds[1].snapshot.total_item_quantity)
        a.equal("PalItem/LiveStone", built_report.audit.guilds[1].snapshot.slots[1].static_id)
        a.equal(true, app:shutdown())
    end)

    it("continues a pending world exactly once and fences late callbacks on shutdown", function()
        local value = fixture({ ready = false })
        value.app = cgce.new(value.dependencies)

        local waiting, err = value.app:start()
        a.equal(nil, err)
        a.equal("WAITING", waiting.state)
        a.equal(true, waiting.pending)
        a.equal(false, waiting.terminal)
        a.equal(false, waiting.report_persisted)
        a.equal(0, value.observations.persists)
        a.equal(1, value.runtime.fake.counters().register_hook)
        local audit_before_ready, audit_error = value.app:handle_command("cgce audit")
        a.equal(nil, audit_before_ready)
        a.equal("CGCE-CMD-PORT-FAILED", audit_error.code)

        value.runtime:set_ready(true)
        value.runtime:fire_world_ready()

        local status = assert(value.app:handle_command("cgce status"))
        a.equal("AUDIT_COMPLETE", status.state)
        a.equal(1, value.observations.persists)

        local closed = value.app:shutdown()
        a.equal(true, closed)
        value.runtime:fire_world_ready_late()
        value.timers:fire_late(1)
        a.equal(1, value.observations.persists)
        assert_no_mutation(value.runtime)
    end)

    it("holds one runtime lease until successful cleanup and then permits a fresh epoch", function()
        local first = fixture({ ready = false })
        local first_app = cgce.new(first.dependencies)
        a.equal("WAITING", assert(first_app:start()).state)

        local duplicate = fixture({ ready = false })
        local duplicate_before = duplicate.runtime.fake.counters()
        expect_problem("CGCE-RUNTIME-LIFECYCLE", "lifecycle", function()
            cgce.new(duplicate.dependencies)
        end)
        a.deep_equal(duplicate_before, duplicate.runtime.fake.counters())
        a.equal(1, first.runtime.fake.counters().register_hook)

        a.equal(true, first_app:shutdown())
        local reloaded = fixture()
        local reloaded_app = cgce.new(reloaded.dependencies)
        a.equal("AUDIT_COMPLETE", assert(reloaded_app:start()).state)
        a.equal(true, reloaded_app:shutdown())
    end)

    it("holds the lease through reentrant cleanup callbacks and releases it only at outer completion", function()
        local value = fixture({ ready = false })
        local duplicate = fixture()
        local original_cancel = value.dependencies.cancel
        local callback_count = 0
        local armed = false
        value.dependencies.cancel = function(token)
            if not armed then
                return original_cancel(token)
            end
            callback_count = callback_count + 1
            local nested, nested_errors = value.app:shutdown()
            a.equal(false, nested)
            a.equal("CGCE-RUNTIME-LIFECYCLE", nested_errors[1].code)
            expect_problem("CGCE-RUNTIME-LIFECYCLE", "lifecycle", function()
                cgce.new(duplicate.dependencies)
            end)
            return original_cancel(token)
        end
        value.app = cgce.new(value.dependencies)
        a.equal("WAITING", assert(value.app:start()).state)
        armed = true

        a.equal(true, value.app:shutdown())
        a.equal(1, callback_count)

        local reloaded = fixture()
        local reloaded_app = cgce.new(reloaded.dependencies)
        a.equal("AUDIT_COMPLETE", assert(reloaded_app:start()).state)
        a.equal(true, reloaded_app:shutdown())
    end)

    it("maps bounded readiness exhaustion to one terminal block without auditing", function()
        local value = fixture({ ready = false })
        local app = cgce.new(value.dependencies)
        a.equal("WAITING", assert(app:start()).state)

        while value.timers:fire_next() do
        end

        local status = assert(app:handle_command("cgce status"))
        a.equal("BLOCKED", status.state)
        a.equal(0, value.observations.conflict_reads)
        a.equal(0, value.observations.ledger_reads)
        a.equal(0, value.observations.persists)
        a.equal(true, app:shutdown())
    end)

    it("classifies a missing exact manifest as unsupported and stops before platform reads", function()
        local value = fixture({ manifest_missing = true })
        local app = cgce.new(value.dependencies)

        local result, err = app:start()

        a.equal(nil, err)
        a.equal("UNSUPPORTED", result.state)
        a.equal(true, result.terminal)
        a.equal(false, result.report_persisted)
        a.equal(1, value.observations.revision_reads)
        a.equal(1, value.observations.manifest_reads)
        a.equal(0, value.observations.platform_reads)
        a.equal(0, value.observations.conflict_reads)
        a.equal(0, value.observations.persists)
        a.equal(true, app:shutdown())

        local malformed = fixture({ manifest_text = "{not-json" })
        local malformed_app = cgce.new(malformed.dependencies)
        local blocked = assert(malformed_app:start())
        a.equal("BLOCKED", blocked.state)
        a.equal(1, malformed.observations.revision_reads)
        a.equal(0, malformed.observations.platform_reads)
        a.equal(0, malformed.observations.persists)
        a.equal(true, malformed_app:shutdown())
    end)

    it("blocks an invalid path or config before reading the live revision", function()
        local bindings = fixture()
        bindings.dependencies.bindings_relative_directory = "..\\outside-bindings"
        local bindings_app = cgce.new(bindings.dependencies)
        local bindings_result = assert(bindings_app:start())
        a.equal("BLOCKED", bindings_result.state)
        a.equal(0, bindings.observations.config_reads)
        a.equal(0, bindings.observations.revision_reads)
        a.equal(true, bindings_app:shutdown())

        local escaped = fixture()
        escaped.dependencies.config_relative_path = "..\\outside.json"
        local escaped_app = cgce.new(escaped.dependencies)
        local escaped_result = assert(escaped_app:start())
        a.equal("BLOCKED", escaped_result.state)
        a.equal(0, escaped.observations.config_reads)
        a.equal(0, escaped.observations.revision_reads)
        a.equal(true, escaped_app:shutdown())

        local malformed = fixture({ config_text = "{not-json" })
        local malformed_app = cgce.new(malformed.dependencies)
        local malformed_result = assert(malformed_app:start())
        a.equal("BLOCKED", malformed_result.state)
        a.equal(1, malformed.observations.config_reads)
        a.equal(0, malformed.observations.revision_reads)
        a.equal(true, malformed_app:shutdown())

        local missing_report = fixture({ missing_report_parent = true })
        local missing_report_app = cgce.new(missing_report.dependencies)
        local missing_report_result = assert(missing_report_app:start())
        a.equal("BLOCKED", missing_report_result.state)
        a.equal(0, missing_report.observations.config_reads)
        a.equal(0, missing_report.observations.revision_reads)
        a.equal(0, missing_report.observations.platform_reads)
        a.equal(0, missing_report.observations.conflict_reads)
        a.equal(0, missing_report.observations.persists)
        a.equal(true, missing_report_app:shutdown())
    end)

    it("binds the exact manifest to the preflighted bindings directory", function()
        local bindings_canonicalizations = 0
        local other_bindings = ROOT .. "\\Scripts\\other-bindings"
        local value = fixture({
            extra_entries = { [other_bindings] = "directory" },
            canonicalize = function(_, path, fallback)
                if path:gsub("/", "\\"):lower()
                    == (ROOT .. "\\Scripts\\bindings"):lower() then
                    bindings_canonicalizations = bindings_canonicalizations + 1
                    if bindings_canonicalizations > 1 then
                        return other_bindings
                    end
                end
                return fallback(path)
            end,
        })
        local app = cgce.new(value.dependencies)

        local result = assert(app:start())

        a.equal("BLOCKED", result.state)
        a.equal(1, value.observations.revision_reads)
        a.equal(0, value.observations.manifest_reads)
        a.equal(0, value.observations.platform_reads)
        a.equal(0, value.observations.conflict_reads)
        a.equal(0, value.observations.persists)
        a.equal(true, app:shutdown())
    end)

    it("keeps the operational report in a dedicated non-input namespace", function()
        for _, report_path in ipairs({
            CONFIG_PATH,
            LEDGER_PATH,
            "Scripts\\bindings\\123456.json",
            "Scripts\\main.lua",
        }) do
            local value = fixture()
            value.dependencies.report_relative_path = report_path
            local app = cgce.new(value.dependencies)

            local result = assert(app:start())

            a.equal("BLOCKED", result.state)
            a.equal("CGCE-RUNTIME-PATH-ROLE", result.errors[1].code)
            a.equal(0, value.observations.config_reads)
            a.equal(0, value.observations.revision_reads)
            a.equal(0, value.observations.manifest_reads)
            a.equal(0, value.observations.platform_reads)
            a.equal(0, value.observations.conflict_reads)
            a.equal(0, value.observations.persists)
            a.equal(true, app:shutdown())
        end

        local canonical_alias = fixture({
            canonicalize = function(_, path, fallback)
                if path:gsub("/", "\\"):lower()
                    == (ROOT .. "\\artifacts"):lower() then
                    return ROOT .. "\\Scripts"
                end
                return fallback(path)
            end,
        })
        local canonical_alias_app = cgce.new(canonical_alias.dependencies)
        local canonical_alias_result = assert(canonical_alias_app:start())
        a.equal("BLOCKED", canonical_alias_result.state)
        a.equal("CGCE-RUNTIME-PATH-ROLE", canonical_alias_result.errors[1].code)
        a.equal(0, canonical_alias.observations.config_reads)
        a.equal(0, canonical_alias.observations.persists)
        a.equal(true, canonical_alias_app:shutdown())
    end)

    it("rejects excess values from a strict external read port", function()
        local value = fixture({
            platform_port = function()
                return platform_inputs(), nil, nil
            end,
        })
        local app = cgce.new(value.dependencies)

        local result = assert(app:start())

        a.equal("BLOCKED", result.state)
        a.equal(1, value.observations.platform_reads)
        a.equal(0, value.observations.conflict_reads)
        a.equal(0, value.observations.persists)
        a.equal(true, app:shutdown())
    end)

    it("defers reentrant shutdown until startup unwinds and preserves a fresh reload", function()
        local value
        local callback_count = 0
        value = fixture({
            on_config_read = function(context)
                callback_count = callback_count + 1
                local closed, errors = context.app:shutdown()
                a.equal(false, closed)
                a.equal("CGCE-RUNTIME-LIFECYCLE", errors[1].code)
                local duplicate = fixture()
                expect_problem("CGCE-RUNTIME-LIFECYCLE", "lifecycle", function()
                    cgce.new(duplicate.dependencies)
                end)
            end,
        })
        value.app = cgce.new(value.dependencies)

        local result, err = value.app:start()

        a.equal(nil, result)
        a.equal("CGCE-RUNTIME-LIFECYCLE", err.code)
        a.equal(1, callback_count)
        a.equal(0, value.observations.revision_reads)
        local fresh = fixture()
        local fresh_app = cgce.new(fresh.dependencies)
        a.equal("AUDIT_COMPLETE", assert(fresh_app:start()).state)
        a.equal("AUDIT_COMPLETE", assert(fresh_app:handle_command("cgce status")).state)
        a.equal(true, fresh_app:shutdown())
    end)

    it("stops revision validation immediately after a reentrant shutdown", function()
        local deferred
        local value = fixture({
            on_revision_read = function(context)
                deferred = context.app:shutdown()
            end,
        })
        value.app = cgce.new(value.dependencies)

        local result, err = value.app:start()

        a.equal(nil, result)
        a.equal("CGCE-RUNTIME-LIFECYCLE", err.code)
        a.equal(false, deferred)
        a.equal(1, value.observations.config_reads)
        a.equal(1, value.observations.revision_reads)
        a.equal(0, value.observations.manifest_reads)
        a.equal(0, value.observations.platform_reads)
        a.equal(0, value.observations.conflict_reads)
        a.equal(0, value.observations.persists)
    end)

    it("keeps platform and malformed-ledger diagnostics warning-only in audit but blocking in apply", function()
        local scenarios = {
            {
                code = "CGCE-PF-REQUIRED-PLATFORM-MISSING",
                configure = function(options)
                    options.platform_inputs = {
                        args = platform_inputs().args,
                        option_settings = table.concat({
                            "OptionSettings=(CrossplayPlatforms=(Steam,PS5)",
                            ",bAllowClientMod=False",
                            ",PublicPort=8211",
                            ",LogFormatType=Json)",
                        }),
                    }
                end,
            },
            {
                code = "CGCE-LEDGER-MALFORMED",
                configure = function(options)
                    options.ledger_text = "{not-json"
                end,
            },
        }

        for _, scenario in ipairs(scenarios) do
            for _, mode in ipairs({ "audit", "apply" }) do
                local configured = json.decode(default_config)
                configured.mode = mode
                local built
                local options = {
                    config_text = json.encode(configured),
                    gate_a_accepted = true,
                    on_persist = function(_, value)
                        built = value
                    end,
                }
                scenario.configure(options)
                local value = fixture(options)
                local app = cgce.new(value.dependencies)

                local result = assert(app:start())

                a.equal(mode == "audit" and "AUDIT_COMPLETE" or "BLOCKED", result.state)
                a.equal(true, result.report_persisted)
                a.equal(1, value.observations.conflict_reads)
                a.equal(1, value.observations.ledger_reads)
                a.equal(1, value.observations.persists)
                local finding = assert(find_finding(built, scenario.code))
                a.equal(mode == "audit" and "WARNING" or "BLOCKING", finding.severity)
                a.equal(true, app:shutdown())
            end
        end
    end)

    it("never lets disabled safety-intent flags skip audit, ledger, approval, or reporting", function()
        for _, field in ipairs({
            "require_operator_approval",
            "verify_on_startup",
            "write_migration_ledger",
            "fail_fast",
        }) do
            for _, mode in ipairs({ "audit", "apply" }) do
                local configured = json.decode(default_config)
                configured.mode = mode
                configured[field] = false
                local built
                local value = fixture({
                    config_text = json.encode(configured),
                    gate_a_accepted = true,
                    on_persist = function(_, report_value)
                        built = report_value
                    end,
                })
                local app = cgce.new(value.dependencies)

                local result = assert(app:start())

                a.equal(mode == "audit" and "AUDIT_COMPLETE" or "BLOCKED", result.state)
                a.equal(true, result.report_persisted)
                a.equal(1, value.observations.ledger_reads)
                a.equal(1, value.observations.conflict_reads)
                local finding = assert(find_finding(
                    built,
                    "CGCE-RUNTIME-SAFETY-INTENT-DISABLED",
                    "config." .. field
                ))
                a.equal(mode == "audit" and "WARNING" or "BLOCKING", finding.severity)
                local approval_finding = find_finding(
                    built,
                    "CGCE-RUNTIME-APPROVAL-REQUIRED"
                )
                if mode == "apply" then
                    a.equal("INFO", assert(approval_finding).severity)
                else
                    a.equal(nil, approval_finding)
                end
                a.equal(true, app:shutdown())
            end
        end
    end)

    it("blocks exact conflict collisions in both modes and preserves sorted report evidence", function()
        for _, mode in ipairs({ "audit", "apply" }) do
            local configured = json.decode(default_config)
            configured.mode = mode
            local built
            local value = fixture({
                config_text = json.encode(configured),
                gate_a_accepted = true,
                conflict_inventory = function(target)
                    local inventory = conflict_inventory(target, true)
                    inventory.mods = {
                        {
                            package_name = "ForeignStorageMod",
                            package_version = "9.9.9",
                            package_path = "/Foreign/StorageMod",
                            claimed_paths = { "/Save/Exact/GuildChestStorage" },
                        },
                    }
                    return inventory
                end,
                on_persist = function(_, report_value)
                    built = report_value
                end,
            })
            local app = cgce.new(value.dependencies)

            local result = assert(app:start())

            a.equal("BLOCKED", result.state)
            a.equal(true, result.report_persisted)
            a.equal(true, built.conflict_summary.blocking)
            local finding = assert(find_finding(built, "CGCE-CONFLICT-STORAGE-COLLISION"))
            a.equal("BLOCKING", finding.severity)
            for index = 2, #built.findings do
                local previous = built.findings[index - 1]
                local current = built.findings[index]
                a.equal(true, previous.code < current.code
                    or (previous.code == current.code and previous.field <= current.field))
            end
            a.equal(true, app:shutdown())
        end
    end)

    it("keeps snapshot blockers terminal and does not let a valid approval bypass them", function()
        local audit_report
        local audit_config = json.decode(default_config)
        audit_config.fail_fast = false
        local audit_value = fixture({
            with_guild = true,
            gate_a_accepted = true,
            config_text = json.encode(audit_config),
            capture_container_snapshot = function()
                error("live snapshot unavailable")
            end,
            on_persist = function(_, built)
                audit_report = built
            end,
        })
        local audit_app = cgce.new(audit_value.dependencies)
        a.equal("BLOCKED", assert(audit_app:start()).state)
        a.equal(true, audit_app:shutdown())

        local configured = json.decode(default_config)
        configured.mode = "apply"
        configured.fail_fast = false
        configured.approval_token = approval.token({
            world_id = audit_report.world_id,
            game_revision = audit_report.game_revision,
            audit_checksum = audit_report.audit_checksum,
            requested_target_slots = audit_report.target_slots,
            deployment_profile = audit_report.deployment_profile,
        })
        local apply_report
        local apply_value = fixture({
            with_guild = true,
            gate_a_accepted = true,
            config_text = json.encode(configured),
            capture_container_snapshot = function()
                error("live snapshot unavailable")
            end,
            on_persist = function(_, built)
                apply_report = built
            end,
        })
        local apply_app = cgce.new(apply_value.dependencies)

        local result = assert(apply_app:start())

        a.equal("BLOCKED", result.state)
        a.equal(true, result.report_persisted)
        a.equal(nil, find_finding(apply_report, "CGCE-RUNTIME-APPROVAL-REQUIRED"))
        a.equal("CGCE-AUD-SNAPSHOT", apply_report.audit.blocking_errors[1].code)
        a.equal("BLOCKING", assert(find_finding(
            apply_report,
            "CGCE-RUNTIME-SAFETY-INTENT-DISABLED",
            "config.fail_fast"
        )).severity)
        a.equal(true, apply_app:shutdown())
    end)

    it("keeps apply mode awaiting approval only after complete pre-Gate checks", function()
        local configured = json.decode(default_config)
        configured.mode = "apply"

        local partial = fixture({ config_text = json.encode(configured) })
        local partial_app = cgce.new(partial.dependencies)
        local partial_result = assert(partial_app:start())
        a.equal("BLOCKED", partial_result.state)
        a.equal(true, partial_result.report_persisted)
        a.equal(true, partial_app:shutdown())

        local value = fixture({
            config_text = json.encode(configured),
            gate_a_accepted = true,
        })
        local app = cgce.new(value.dependencies)

        local result = assert(app:start())

        a.equal("AWAITING_APPROVAL", result.state)
        a.equal(true, result.report_persisted)
        a.equal(1, value.observations.persists)
        a.equal(true, app:shutdown())
    end)

    it("retains partial conflict coverage as warning in audit and blocking in apply", function()
        for _, mode in ipairs({ "audit", "apply" }) do
            local configured = json.decode(default_config)
            configured.mode = mode
            local built
            local value = fixture({
                config_text = json.encode(configured),
                on_persist = function(_, report_value)
                    built = report_value
                end,
            })
            local app = cgce.new(value.dependencies)

            local result = assert(app:start())

            a.equal(mode == "audit" and "AUDIT_COMPLETE" or "BLOCKED", result.state)
            a.equal("partial", built.conflict_summary.coverage)
            a.equal(
                "WARNING",
                assert(find_finding(built, "CGCE-CONFLICT-COVERAGE-PARTIAL")).severity
            )
            local runtime_finding = find_finding(
                built,
                "CGCE-RUNTIME-CONFLICT-COVERAGE-PARTIAL"
            )
            if mode == "apply" then
                a.equal("BLOCKING", assert(runtime_finding).severity)
            else
                a.equal(nil, runtime_finding)
            end
            a.equal(true, app:shutdown())
        end
    end)

    it("ends valid fresh-audit approval at audit complete without mutation authority", function()
        local first_report
        local first = fixture({
            gate_a_accepted = true,
            on_persist = function(_, built)
                first_report = built
            end,
        })
        local first_app = cgce.new(first.dependencies)
        a.equal("AUDIT_COMPLETE", assert(first_app:start()).state)
        a.equal(true, first_app:shutdown())

        local configured = json.decode(default_config)
        configured.mode = "apply"
        configured.approval_token = approval.token({
            world_id = first_report.world_id,
            game_revision = first_report.game_revision,
            audit_checksum = first_report.audit_checksum,
            requested_target_slots = first_report.target_slots,
            deployment_profile = first_report.deployment_profile,
        })
        local approved = fixture({
            config_text = json.encode(configured),
            gate_a_accepted = true,
        })
        local approved_app = cgce.new(approved.dependencies)

        local result = assert(approved_app:start())

        a.equal("AUDIT_COMPLETE", result.state)
        a.equal(true, result.report_persisted)
        local apply, apply_error = approved_app:handle_command("cgce apply")
        a.equal(nil, apply)
        a.equal("MUTATION_BUILD_UNAVAILABLE", apply_error.code)
        a.equal(true, approved_app:shutdown())
    end)

    it("blocks when the persistence receipt does not prove the exact report", function()
        local value = fixture({
            persist = function(_, built)
                return {
                    path = ROOT .. "\\artifacts\\different.json",
                    relative_path = REPORT_PATH,
                    report_checksum = built.checksum,
                    audit_checksum = built.audit_checksum,
                    byte_length = #json.encode(built),
                    durable = true,
                    read_back_verified = true,
                }
            end,
        })
        local app = cgce.new(value.dependencies)

        local result = assert(app:start())

        a.equal("BLOCKED", result.state)
        a.equal(false, result.report_persisted)
        a.equal("CGCE-RUNTIME-RECEIPT", result.errors[1].code)
        local exported, export_error = app:handle_command("cgce export-report")
        a.equal(nil, exported)
        a.equal("CGCE-CMD-PORT-FAILED", export_error.code)
        a.equal(true, app:shutdown())
    end)

    it("blocks if the persistence port mutates the report while fabricating a receipt", function()
        local value = fixture({
            persist = function(_, built)
                local original_checksum = built.checksum
                local original_audit_checksum = built.audit_checksum
                local original_length = #json.encode(built)
                built.state = "BLOCKED"
                return {
                    path = ROOT .. "\\artifacts\\audit-report.json",
                    relative_path = REPORT_PATH,
                    report_checksum = original_checksum,
                    audit_checksum = original_audit_checksum,
                    byte_length = original_length,
                    durable = true,
                    read_back_verified = true,
                }
            end,
        })
        local app = cgce.new(value.dependencies)

        local result = assert(app:start())

        a.equal("BLOCKED", result.state)
        a.equal(false, result.report_persisted)
        a.equal("CGCE-RUNTIME-REPORT-MUTATED", result.errors[1].code)
        a.equal(true, app:shutdown())
    end)

    it("rejects an exact-looking receipt when no report bytes were written", function()
        local value = fixture({
            persist = function(_, built)
                return {
                    path = ROOT .. "\\artifacts\\audit-report.json",
                    relative_path = REPORT_PATH,
                    report_checksum = built.checksum,
                    audit_checksum = built.audit_checksum,
                    byte_length = #json.encode(built),
                    durable = true,
                    read_back_verified = true,
                }
            end,
        })
        local app = cgce.new(value.dependencies)

        local result = assert(app:start())

        a.equal("BLOCKED", result.state)
        a.equal(false, result.report_persisted)
        a.equal("CGCE-RUNTIME-REPORT-READBACK", result.errors[1].code)
        a.equal(1, value.observations.report_reads)
        a.equal(true, app:shutdown())
    end)

    it("rejects a durable receipt when independent read-back bytes differ", function()
        local value = fixture({
            report_read_override = function()
                return "{}"
            end,
        })
        local app = cgce.new(value.dependencies)

        local result = assert(app:start())

        a.equal("BLOCKED", result.state)
        a.equal(false, result.report_persisted)
        a.equal("CGCE-RUNTIME-REPORT-READBACK", result.errors[1].code)
        a.equal(true, app:shutdown())
    end)

    it("sanitizes thrown and tuple persistence failures without publishing a receipt", function()
        for _, persist in ipairs({
            function()
                error({
                    code = "LEAKED-PORT-CODE",
                    field = "approval_token",
                    detail = "secret-token at 0xDEADBEEF",
                }, 0)
            end,
            function()
                return nil, "secret-token at 0xDEADBEEF"
            end,
        }) do
            local value = fixture({ persist = persist })
            local app = cgce.new(value.dependencies)

            local result = assert(app:start())

            a.equal("BLOCKED", result.state)
            a.equal(false, result.report_persisted)
            a.equal("CGCE-RUNTIME-REPORT-PERSIST", result.errors[1].code)
            a.equal(nil, result.errors[1].detail:find("secret-token", 1, true))
            a.equal(nil, result.errors[1].detail:find("0x", 1, true))
            a.equal(true, app:shutdown())
        end
    end)

    it("blocks when the world epoch changes during persistence or final read-back", function()
        for _, hook in ipairs({ "on_persist", "on_report_read" }) do
            local options = { ready = false }
            options[hook] = function(context)
                context.runtime:fire_world_ready()
            end
            local value = fixture(options)
            local app = cgce.new(value.dependencies)
            a.equal("WAITING", assert(app:start()).state)

            value.runtime:set_ready(true)
            value.runtime:fire_world_ready()

            local status = assert(app:handle_command("cgce status"))
            a.equal("BLOCKED", status.state)
            local exported, export_error = app:handle_command("cgce export-report")
            a.equal(nil, exported)
            a.equal("CGCE-CMD-PORT-FAILED", export_error.code)
            a.equal(true, app:shutdown())
        end
    end)

    it("fences epoch changes immediately after conflict inventory and ledger reads", function()
        for _, hook in ipairs({ "on_conflict_read", "on_ledger_read" }) do
            local options = { ready = false }
            options[hook] = function(context)
                context.runtime:fire_world_ready()
            end
            local value = fixture(options)
            local app = cgce.new(value.dependencies)
            a.equal("WAITING", assert(app:start()).state)

            value.runtime:set_ready(true)
            value.runtime:fire_world_ready()

            local status = assert(app:handle_command("cgce status"))
            a.equal("BLOCKED", status.state)
            a.equal(0, value.observations.persists)
            if hook == "on_conflict_read" then
                a.equal(0, value.observations.ledger_reads)
            else
                a.equal(1, value.observations.ledger_reads)
            end
            a.equal(true, app:shutdown())
        end
    end)

    it("revokes a completed report when its world epoch becomes stale", function()
        local value = fixture()
        local app = cgce.new(value.dependencies)
        a.equal("AUDIT_COMPLETE", assert(app:start()).state)

        value.runtime:fire_world_ready()

        local runtime_status = assert(cgce.status(app))
        a.equal("BLOCKED", runtime_status.state)
        a.equal(false, runtime_status.report_persisted)
        a.equal("CGCE-RUNTIME-EPOCH", runtime_status.errors[1].code)
        local status = assert(app:handle_command("cgce status"))
        a.equal("BLOCKED", status.state)
        local exported, export_error = app:handle_command("cgce export-report")
        a.equal(nil, exported)
        a.equal("CGCE-CMD-PORT-FAILED", export_error.code)
        a.equal(true, app:shutdown())
    end)

    it("does not return stale command verification after a ledger read invalidates the epoch", function()
        local armed = false
        local value = fixture({
            on_ledger_read = function(context)
                if armed then
                    context.runtime:fire_world_ready()
                end
            end,
        })
        local app = cgce.new(value.dependencies)
        a.equal("AUDIT_COMPLETE", assert(app:start()).state)
        armed = true

        local verified, verify_error = app:handle_command("cgce verify")

        a.equal(nil, verified)
        a.equal("CGCE-CMD-PORT-FAILED", verify_error.code)
        local status = assert(cgce.status(app))
        a.equal("BLOCKED", status.state)
        a.equal(false, status.report_persisted)
        a.equal(true, app:shutdown())
    end)

    it("keeps the immediate-ready epoch observed throughout report persistence", function()
        local value = fixture({
            on_persist = function(context)
                context.runtime:fire_world_ready()
            end,
        })
        local app = cgce.new(value.dependencies)

        local result = assert(app:start())

        a.equal("BLOCKED", result.state)
        a.equal(false, result.report_persisted)
        a.equal(1, value.runtime.fake.counters().register_hook)
        a.equal(1, value.runtime.fake.counters().unregister_hook)
        a.equal(true, app:shutdown())
    end)

    it("returns a lifecycle failure when a persistence callback shuts startup down", function()
        local deferred
        local shutdown_error
        local value = fixture({
            on_report_read = function(context)
                local closed, errors = context.app:shutdown()
                deferred = closed
                shutdown_error = errors[1]
            end,
        })
        value.app = cgce.new(value.dependencies)

        local result, err = value.app:start()

        a.equal(nil, result)
        a.equal("CGCE-RUNTIME-LIFECYCLE", err.code)
        a.equal(false, deferred)
        a.equal("CGCE-RUNTIME-LIFECYCLE", shutdown_error.code)
        local command, command_error = value.app:handle_command("cgce status")
        a.equal(nil, command)
        a.equal("CGCE-RUNTIME-LIFECYCLE", command_error.code)
    end)

    it("boots through main without guessing or widening runtime dependencies", function()
        local main = require("CrossplayGuildChestExpander.Scripts.main")
        local value = fixture()

        local app, result, err = main.start(value.dependencies)

        a.equal(nil, err)
        a.equal("AUDIT_COMPLETE", result.state)
        a.equal("table", type(app))
        a.equal(true, app:shutdown())
    end)

    it("releases the loader bootstrap record after a successful shutdown", function()
        local main = require("CrossplayGuildChestExpander.Scripts.main")
        local first = fixture()
        local second = fixture()

        local first_app, first_result = main.bootstrap(first.dependencies)
        a.equal("AUDIT_COMPLETE", first_result.state)
        a.equal(true, main.shutdown())
        a.equal(nil, main.status())

        local second_app, second_result = main.bootstrap(second.dependencies)
        a.equal("AUDIT_COMPLETE", second_result.state)
        a.equal(false, first_app == second_app)
        a.equal(true, main.shutdown())
        a.equal(nil, main.status())
    end)

    it("refreshes a pending loader bootstrap from the live runtime", function()
        local main = require("CrossplayGuildChestExpander.Scripts.main")
        local value = fixture({ ready = false })

        local _, waiting = main.bootstrap(value.dependencies)
        a.equal("WAITING", waiting.state)
        a.equal("WAITING", assert(main.status()).state)

        value.runtime:set_ready(true)
        value.runtime:fire_world_ready()

        local completed = assert(main.status())
        a.equal("AUDIT_COMPLETE", completed.state)
        a.equal(true, completed.report_persisted)
        a.equal(true, main.shutdown())
    end)

    it("never returns a cached loader result after its app is closed directly", function()
        local main = require("CrossplayGuildChestExpander.Scripts.main")
        local value = fixture({ ready = false })

        local app, waiting = main.bootstrap(value.dependencies)
        a.equal("WAITING", waiting.state)
        a.equal(true, app:shutdown())

        local status, status_error = main.status()
        a.equal(nil, status)
        a.equal("CGCE-RUNTIME-LIFECYCLE", status_error.code)
        local cached_app, cached_result, cached_error = main.bootstrap(value.dependencies)
        a.equal(app, cached_app)
        a.equal(nil, cached_result)
        a.equal("CGCE-RUNTIME-LIFECYCLE", cached_error.code)
        a.equal(true, main.shutdown())
        a.equal(nil, main.status())
    end)

    it("executes once under constrained loader paths and fails closed honestly", function()
        local cases = {
            {
                mode = "relative-source",
                detail = "verified production read-only ports are not packaged yet",
            },
            {
                mode = "debugless-search-path",
                detail = "verified production read-only ports are not packaged yet",
            },
            {
                mode = "unresolved-root",
                detail = "the installed package root could not be verified",
            },
        }
        for _, case in ipairs(cases) do
            local command = table.concat({
                "third_party/lua-5.4.8/src/lua",
                "tests/support/main_loader_smoke.lua",
                case.mode,
            }, " ")
            local pipe = assert(io.popen(command))
            local output = assert(pipe:read("*a"))
            local ok, _, code = pipe:close()

            a.equal(true, ok)
            a.equal(0, code)
            a.equal(
                "CGCE-LOADER-COMPOSITION-UNAVAILABLE: " .. case.detail .. "\n",
                output
            )
        end
    end)

    it("continues cleanup after timer and hook failures, fences late work, and retains the lease", function()
        local isolated_cgce = assert(loadfile(
            "CrossplayGuildChestExpander/Scripts/cgce.lua"
        ))()
        local value = fixture({ ready = false })
        local original_cancel = value.dependencies.cancel
        local cancel_failures = 0
        local armed = false
        value.dependencies.cancel = function(token)
            if not armed then
                return original_cancel(token)
            end
            cancel_failures = cancel_failures + 1
            error("cancel failed with secret-token at 0xDEADBEEF")
        end
        local app = isolated_cgce.new(value.dependencies)
        a.equal("WAITING", assert(app:start()).state)
        armed = true
        value.runtime:fail_world_ready_unregister()

        local closed, errors = app:shutdown()
        local counters_after_first = value.runtime.fake.counters()
        value.runtime:fire_world_ready_late()
        value.timers:fire_late(#value.timers.records)
        local closed_again, errors_again = app:shutdown()

        a.equal(false, closed)
        a.equal(false, closed_again)
        a.equal(1, cancel_failures)
        a.equal(1, counters_after_first.unregister_hook)
        a.equal(0, value.observations.persists)
        a.equal(3, #errors)
        a.equal("CGCE-WORLD-TIMER-CLEANUP", errors[1].code)
        a.equal("CGCE-WORLD-HOOK-CLEANUP", errors[2].code)
        a.equal("CGCE-UE4SS-OBSERVER-UNREGISTER", errors[3].code)
        for _, err in ipairs(errors) do
            a.equal(nil, err.detail:find("secret-token", 1, true))
            a.equal(nil, err.detail:find("0x", 1, true))
        end
        a.deep_equal(errors, errors_again)
        a.deep_equal(counters_after_first, value.runtime.fake.counters())
        local duplicate = fixture()
        expect_problem("CGCE-RUNTIME-LIFECYCLE", "lifecycle", function()
            isolated_cgce.new(duplicate.dependencies)
        end)
    end)
end)
