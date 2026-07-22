local a = require("tests.support.assertions")
local audit = require("CrossplayGuildChestExpander.Scripts.audit")
local fake_adapter = require("tests.support.fake_adapter")
local json = require("CrossplayGuildChestExpander.Scripts.json")
local sha256 = require("CrossplayGuildChestExpander.Scripts.sha256")
local snapshot = require("CrossplayGuildChestExpander.Scripts.snapshot")

local readonly_adapter = fake_adapter.new()

local function slots(count)
    local result = {}
    for index = 1, count do
        result[index] = fake_adapter.slot(nil)
    end
    return result
end

local function container(container_id, owner_guild_id, slot_count)
    return fake_adapter.container({
        container_id = container_id,
        owner_guild_id = owner_guild_id,
        slots = slots(slot_count),
    })
end

local function guild(guild_id, guild_name, chest_container_id)
    return {
        guild_id = guild_id,
        guild_name = guild_name,
        chest_container_id = chest_container_id,
    }
end

local function fixture(guilds, containers)
    local calls = {
        list = 0,
        resolve = {},
        snapshot = {},
    }
    local context = {
        world_id = "world/test",
        game_revision = 12345,
        deployment_profile = "windows-dedicated-ps5-macos-required",
        target_slots = 358,
        include_guild_ids = {},
        exclude_guild_ids = {},
        list_guilds = function()
            calls.list = calls.list + 1
            return guilds
        end,
        resolve_guild_chest = function(_, container_id)
            calls.resolve[#calls.resolve + 1] = container_id
            local value = containers[container_id]
            if value == nil then
                return nil
            end
            return {
                container_id = container_id,
                owner_guild_id = value.owner_guild_id,
                is_guild_chest = value.is_guild_chest ~= false,
                container = value,
            }
        end,
        snapshot_container = function(value)
            calls.snapshot[#calls.snapshot + 1] = value.container_id
            return snapshot.capture(readonly_adapter, value)
        end,
    }
    return context, calls
end

local function find_error(errors, code, field)
    for _, value in ipairs(errors) do
        if value.code == code and (field == nil or value.field == field) then
            return value
        end
    end
    return nil
end

local function assert_error(errors, code, field)
    local value = find_error(errors, code, field)
    a.equal("table", type(value))
    a.equal("string", type(value.detail))
    return value
end

local function find_guild(result, guild_id)
    for _, value in ipairs(result.guilds) do
        if value.guild_id == guild_id then
            return value
        end
    end
    return nil
end

local function capture_table(context)
    return audit.to_table(audit.capture(context))
end

describe("read-only discovery audit", function()
    it("reports every discovered guild once in opaque ID order", function()
        local containers = {
            ["container/a"] = container("container/a", "guild/a", 54),
            ["container/b"] = container("container/b", "guild/b", 358),
            ["container/c"] = container("container/c", "guild/c", 400),
            ["container/general"] = container("container/general", "guild/a", 12),
        }
        containers["container/general"].is_guild_chest = false
        local context, calls = fixture({
            guild("guild/c", "C", "container/c"),
            guild("guild/uninitialized", "No chest", nil),
            guild("guild/a", "A", "container/a"),
            guild("guild/b", "B", "container/b"),
        }, containers)

        local result = capture_table(context)

        a.equal("cgce.audit.v1", result.schema)
        a.equal("world/test", result.world_id)
        a.equal(12345, result.game_revision)
        a.equal("windows-dedicated-ps5-macos-required", result.deployment_profile)
        a.equal(358, result.target_slots)
        a.deep_equal({}, result.blocking_errors)
        a.deep_equal({ "guild/a", "guild/b", "guild/c", "guild/uninitialized" }, {
            result.guilds[1].guild_id,
            result.guilds[2].guild_id,
            result.guilds[3].guild_id,
            result.guilds[4].guild_id,
        })

        a.equal("eligible_expand", result.guilds[1].status)
        a.equal("expand", result.guilds[1].eligible_action)
        a.equal(54, result.guilds[1].snapshot.slot_count)
        a.equal("eligible_noop", result.guilds[2].status)
        a.equal("noop", result.guilds[2].eligible_action)
        a.equal(358, result.guilds[2].snapshot.slot_count)
        a.equal("eligible_noop", result.guilds[3].status)
        a.equal("noop", result.guilds[3].eligible_action)
        a.equal(400, result.guilds[3].snapshot.slot_count)
        a.equal("not_initialized", result.guilds[4].status)
        a.equal("none", result.guilds[4].eligible_action)
        a.equal(nil, result.guilds[4].snapshot)
        a.equal(nil, result.guilds[4].chest_container_id)

        a.deep_equal({ "container/a", "container/b", "container/c" }, calls.resolve)
        a.deep_equal({ "container/a", "container/b", "container/c" }, calls.snapshot)
        for _, resolved_id in ipairs(calls.resolve) do
            a.equal(false, resolved_id == "container/general")
        end
    end)

    it("passes the exact guild chain and forwards an opaque resolver token only to snapshot", function()
        local opaque_calls = 0
        local opaque_container = function()
            opaque_calls = opaque_calls + 1
        end
        local seen_guild_id
        local seen_container_id
        local context = fixture({
            guild("guild/a", "A", "container/a"),
        }, {})
        context.resolve_guild_chest = function(guild_id, container_id)
            seen_guild_id = guild_id
            seen_container_id = container_id
            return {
                container_id = container_id,
                owner_guild_id = guild_id,
                is_guild_chest = true,
                container = opaque_container,
            }
        end
        context.snapshot_container = function(actual)
            a.equal(opaque_container, actual)
            return snapshot.capture(
                readonly_adapter,
                container("container/a", "guild/a", 54)
            )
        end

        local result = capture_table(context)

        a.equal("guild/a", seen_guild_id)
        a.equal("container/a", seen_container_id)
        a.equal("eligible_expand", result.guilds[1].status)
        a.deep_equal({}, result.blocking_errors)
        a.equal(0, opaque_calls)
    end)

    it("sorts filters and keeps valid non-selected guilds visible", function()
        local context = fixture({
            guild("guild/a", "A", "container/a"),
            guild("guild/b", "B", "container/b"),
            guild("guild/c", "C", "container/c"),
        }, {
            ["container/a"] = container("container/a", "guild/a", 54),
            ["container/b"] = container("container/b", "guild/b", 54),
            ["container/c"] = container("container/c", "guild/c", 54),
        })
        context.include_guild_ids = { "guild/c", "guild/a" }
        context.exclude_guild_ids = { "guild/c" }

        local result = capture_table(context)

        a.deep_equal({ "guild/a", "guild/c" }, result.include_guild_ids)
        a.deep_equal({ "guild/c" }, result.exclude_guild_ids)
        assert_error(result.blocking_errors, "CGCE-AUD-FILTER-OVERLAP", "filters")
        a.equal("blocked", find_guild(result, "guild/a").status)
        a.equal("none", find_guild(result, "guild/a").eligible_action)
        a.equal("excluded_by_filter", find_guild(result, "guild/b").status)
        a.equal("none", find_guild(result, "guild/b").eligible_action)
        a.equal("blocked", find_guild(result, "guild/c").status)
        a.equal("none", find_guild(result, "guild/c").eligible_action)
    end)

    it("applies include and exclude eligibility without hiding audit records", function()
        local context = fixture({
            guild("guild/a", "A", "container/a"),
            guild("guild/b", "B", "container/b"),
            guild("guild/c", "C", "container/c"),
        }, {
            ["container/a"] = container("container/a", "guild/a", 54),
            ["container/b"] = container("container/b", "guild/b", 54),
            ["container/c"] = container("container/c", "guild/c", 54),
        })
        context.include_guild_ids = { "guild/c", "guild/a" }
        context.exclude_guild_ids = { "guild/b" }

        local result = capture_table(context)

        a.equal("eligible_expand", find_guild(result, "guild/a").status)
        a.equal("excluded_by_filter", find_guild(result, "guild/b").status)
        a.equal("eligible_expand", find_guild(result, "guild/c").status)
        a.equal(3, #result.guilds)
    end)

    it("detects duplicate configured container IDs before filtering or resolution", function()
        local context, calls = fixture({
            guild("guild/a", "A", "container/shared"),
            guild("guild/b", "B", "container/shared"),
            guild("guild/c", "C", "container/c"),
        }, {
            ["container/shared"] = container("container/shared", "guild/a", 54),
            ["container/c"] = container("container/c", "guild/c", 54),
        })
        context.include_guild_ids = { "guild/c" }

        local result = capture_table(context)

        for _, guild_id in ipairs({ "guild/a", "guild/b" }) do
            local record = find_guild(result, guild_id)
            a.equal("blocked", record.status)
            a.equal("none", record.eligible_action)
            assert_error(record.errors, "CGCE-AUD-DUPLICATE-CONTAINER", "chest_container_id")
        end
        assert_error(result.blocking_errors, "CGCE-AUD-DUPLICATE-CONTAINER")
        a.deep_equal({ "container/c" }, calls.resolve)
        a.deep_equal({ "container/c" }, calls.snapshot)
    end)

    it("treats excluded owner mismatches as globally blocking", function()
        local context, calls = fixture({
            guild("guild/bad", "Bad", "container/bad"),
            guild("guild/good", "Good", "container/good"),
        }, {
            ["container/bad"] = container("container/bad", "guild/other", 54),
            ["container/good"] = container("container/good", "guild/good", 54),
        })
        context.include_guild_ids = { "guild/good" }

        local result = capture_table(context)
        local bad = find_guild(result, "guild/bad")

        a.equal("blocked", bad.status)
        assert_error(bad.errors, "CGCE-AUD-OWNER-MISMATCH", "owner_guild_id")
        assert_error(result.blocking_errors, "CGCE-AUD-OWNER-MISMATCH")
        a.deep_equal({ "container/good" }, calls.snapshot)
    end)

    it("blocks unresolved and non-guild configured references even when excluded", function()
        local context = fixture({
            guild("guild/missing", "Missing", "container/missing"),
            guild("guild/not-guild", "Wrong type", "container/not-guild"),
            guild("guild/good", "Good", "container/good"),
        }, {
            ["container/not-guild"] = container("container/not-guild", "guild/not-guild", 54),
            ["container/good"] = container("container/good", "guild/good", 54),
        })
        context.include_guild_ids = { "guild/good" }
        context.resolve_guild_chest = function(_, container_id)
            if container_id == "container/missing" then
                return nil
            end
            local owner = container_id == "container/not-guild" and "guild/not-guild" or "guild/good"
            return {
                container_id = container_id,
                owner_guild_id = owner,
                is_guild_chest = container_id ~= "container/not-guild",
                container = container_id == "container/not-guild"
                    and container("container/not-guild", owner, 54)
                    or container("container/good", owner, 54),
            }
        end

        local result = capture_table(context)

        assert_error(
            find_guild(result, "guild/missing").errors,
            "CGCE-AUD-CONTAINER-UNRESOLVED",
            "chest_container_id"
        )
        assert_error(
            find_guild(result, "guild/not-guild").errors,
            "CGCE-AUD-NON-GUILD-CONTAINER",
            "chest_container_id"
        )
        assert_error(result.blocking_errors, "CGCE-AUD-CONTAINER-UNRESOLVED")
        assert_error(result.blocking_errors, "CGCE-AUD-NON-GUILD-CONTAINER")
    end)

    it("never resolves or snapshots a guild without a configured chest ID", function()
        local context, calls = fixture({
            guild("guild/new", "New", nil),
        }, {})

        local result = capture_table(context)

        a.equal("not_initialized", result.guilds[1].status)
        a.deep_equal({}, result.guilds[1].errors)
        a.deep_equal({}, result.blocking_errors)
        a.equal(0, #calls.resolve)
        a.equal(0, #calls.snapshot)
    end)

    it("fails closed on malformed guild, resolver, and snapshot projections", function()
        local malformed_context = fixture({
            { guild_id = "guild/a", guild_name = "A", chest_container_id = nil, raw_uobject = {} },
        }, {})
        local malformed_guilds = capture_table(malformed_context)
        a.equal(0, #malformed_guilds.guilds)
        assert_error(malformed_guilds.blocking_errors, "CGCE-AUD-GUILD-PROJECTION", "guilds")

        local resolver_context = fixture({
            guild("guild/a", "A", "container/a"),
        }, {})
        resolver_context.resolve_guild_chest = function()
            return {
                container_id = "container/a",
                owner_guild_id = "guild/a",
                is_guild_chest = true,
                container = {},
                setter = function() end,
            }
        end
        local malformed_resolver = capture_table(resolver_context)
        assert_error(
            malformed_resolver.guilds[1].errors,
            "CGCE-AUD-CONTAINER-UNRESOLVED",
            "chest_container_id"
        )

        local snapshot_context = fixture({
            guild("guild/a", "A", "container/a"),
        }, {
            ["container/a"] = container("container/a", "guild/a", 54),
        })
        snapshot_context.snapshot_container = function()
            local value = snapshot.capture(
                readonly_adapter,
                container("container/a", "guild/a", 54)
            )
            value.raw_uobject = {}
            return value
        end
        local malformed_snapshot = capture_table(snapshot_context)
        assert_error(malformed_snapshot.guilds[1].errors, "CGCE-AUD-SNAPSHOT", "snapshot")
    end)

    it("sanitizes all read-port failures", function()
        local secret = "approval_token=super-secret"
        local context = fixture({}, {})
        context.list_guilds = function()
            error(secret)
        end
        local list_failure = audit.capture(context)
        local list_json = audit.canonical_json(list_failure)
        a.equal(false, list_json:find(secret, 1, true) ~= nil)
        assert_error(
            audit.to_table(list_failure).blocking_errors,
            "CGCE-AUD-GUILD-PROJECTION",
            "guilds"
        )

        local resolve_context = fixture({
            guild("guild/a", "A", "container/a"),
        }, {})
        resolve_context.resolve_guild_chest = function()
            error(secret)
        end
        local resolve_failure = audit.capture(resolve_context)
        a.equal(false, audit.canonical_json(resolve_failure):find(secret, 1, true) ~= nil)
        assert_error(
            audit.to_table(resolve_failure).guilds[1].errors,
            "CGCE-AUD-CONTAINER-UNRESOLVED",
            "chest_container_id"
        )

        local snapshot_context = fixture({
            guild("guild/a", "A", "container/a"),
        }, {
            ["container/a"] = container("container/a", "guild/a", 54),
        })
        snapshot_context.snapshot_container = function()
            error(secret)
        end
        local snapshot_failure = audit.capture(snapshot_context)
        a.equal(false, audit.canonical_json(snapshot_failure):find(secret, 1, true) ~= nil)
        assert_error(
            audit.to_table(snapshot_failure).guilds[1].errors,
            "CGCE-AUD-SNAPSHOT",
            "snapshot"
        )
    end)

    it("rejects unknown context members without invoking write-capable functions", function()
        local context = fixture({}, {})
        local invoked = false
        context.resize = function()
            invoked = true
        end

        local ok, err = pcall(audit.capture, context)

        a.equal(false, ok)
        a.equal(false, invoked)
        a.equal("CGCE-AUD-CONTEXT", err.code)
        a.equal("resize", err.field)
        a.equal(false, err.detail:find("super-secret", 1, true) ~= nil)
    end)

    it("accesses only the three declared read ports behind write traps", function()
        local context = fixture({
            guild("guild/a", "A", "container/a"),
        }, {
            ["container/a"] = container("container/a", "guild/a", 54),
        })
        local write_names = {
            resize = true,
            append = true,
            mark_dirty = true,
            replicate = true,
            execute_in_game_thread = true,
            set_property = true,
        }
        setmetatable(context, {
            __index = function(_, key)
                if write_names[key] then
                    error("write trap accessed: " .. key)
                end
                return nil
            end,
        })

        local result = capture_table(context)

        a.equal("eligible_expand", result.guilds[1].status)
        a.deep_equal({}, result.blocking_errors)
    end)

    it("binds checksum to deterministic canonical unsigned data", function()
        local containers = {
            ["container/a"] = container("container/a", "guild/a", 54),
            ["container/b"] = container("container/b", "guild/b", 400),
        }
        local first_context = fixture({
            guild("guild/b", "B", "container/b"),
            guild("guild/a", "A", "container/a"),
        }, containers)
        first_context.include_guild_ids = { "guild/b", "guild/a" }
        local second_context = fixture({
            guild("guild/a", "A", "container/a"),
            guild("guild/b", "B", "container/b"),
        }, containers)
        second_context.include_guild_ids = { "guild/a", "guild/b" }

        local first = audit.capture(first_context)
        local second = audit.capture(second_context)
        local plain = audit.to_table(first)
        local checksum = plain.checksum
        plain.checksum = nil

        a.equal(sha256.hex(json.encode(plain)), checksum)
        a.equal(checksum, audit.checksum(first))
        a.equal(checksum, audit.checksum(second))
        a.equal(audit.canonical_json(first), audit.canonical_json(second))
        a.equal(false, audit.canonical_json(first):find("timestamp", 1, true) ~= nil)
    end)

    it("returns an opaque handle backed by cached canonical data", function()
        local context = fixture({
            guild("guild/a", "A", "container/a"),
        }, {
            ["container/a"] = container("container/a", "guild/a", 54),
        })
        local result = audit.capture(context)
        local canonical = audit.canonical_json(result)

        local direct_ok = pcall(function()
            return result.world_id
        end)
        local shadow_ok = pcall(function()
            rawset(result, "checksum", string.rep("0", 64))
        end)
        a.equal("function", type(result))
        a.equal(false, direct_ok)
        a.equal(false, shadow_ok)
        a.equal(canonical, audit.canonical_json(result))

        local detached = audit.to_table(result)
        local trusted_checksum = audit.checksum(result)
        detached.world_id = "changed"
        detached.guilds[1].snapshot.slot_count = 999
        detached.checksum = string.rep("0", 64)
        a.equal("world/test", audit.to_table(result).world_id)
        a.equal(54, audit.to_table(result).guilds[1].snapshot.slot_count)
        a.equal(trusted_checksum, audit.checksum(result))
        a.equal(canonical, json.encode(audit.to_table(result)))
    end)

    it("rejects forged opaque audit handles", function()
        local function assert_forged(forged)
            for _, operation in ipairs({
                audit.canonical_json,
                audit.to_table,
                audit.checksum,
            }) do
                local ok, err = pcall(operation, forged)
                a.equal(false, ok)
                a.equal("CGCE-AUD-CHECKSUM", err.code)
                a.equal("audit", err.field)
                a.equal("string", type(err.detail))
            end
        end
        for _, forged in ipairs({ function() end, {}, "forged", false }) do
            assert_forged(forged)
        end
        assert_forged(nil)
    end)

    it("keeps saved accessors bound to trusted storage when public slots are shadowed", function()
        local context = fixture({}, {})
        local real_handle = audit.capture(context)
        local forged_handle = function() end
        local original = {
            canonical_json = audit.canonical_json,
            checksum = audit.checksum,
            to_table = audit.to_table,
        }
        local forged_checksum = string.rep("0", 64)
        local forged_json = json.encode({
            world_id = "world/forged",
            checksum = forged_checksum,
        })

        rawset(audit, "canonical_json", function() return forged_json end)
        rawset(audit, "checksum", function() return forged_checksum end)
        rawset(audit, "to_table", function()
            return { world_id = "world/forged", checksum = forged_checksum }
        end)

        local real_ok, real_value = pcall(original.to_table, real_handle)
        local canonical_ok, canonical_value = pcall(original.canonical_json, real_handle)
        local checksum_ok, checksum_value = pcall(original.checksum, real_handle)
        local forged_ok, forged_error = pcall(original.to_table, forged_handle)

        rawset(audit, "canonical_json", original.canonical_json)
        rawset(audit, "checksum", original.checksum)
        rawset(audit, "to_table", original.to_table)

        a.equal(true, real_ok)
        a.equal("world/test", real_value.world_id)
        a.equal(real_value.checksum, checksum_value)
        a.equal(true, canonical_ok)
        a.equal(canonical_value, json.encode(real_value))
        a.equal(true, checksum_ok)
        a.equal(false, forged_ok)
        a.equal("CGCE-AUD-CHECKSUM", forged_error.code)
        a.equal("audit", forged_error.field)
    end)

    it("uses deterministic fields for unknown context keys without address leakage", function()
        local string_context = fixture({}, {})
        string_context.zebra = true
        string_context.alpha = true
        local ok, err = pcall(audit.capture, string_context)
        a.equal(false, ok)
        a.equal("CGCE-AUD-CONTEXT", err.code)
        a.equal("alpha", err.field)

        local non_string_context = fixture({}, {})
        non_string_context[{}] = true
        non_string_context[function() end] = true
        non_string_context[io.stdout] = true
        ok, err = pcall(audit.capture, non_string_context)
        a.equal(false, ok)
        a.equal("CGCE-AUD-CONTEXT", err.code)
        a.equal("context", err.field)
        a.equal(false, err.detail:find("0x", 1, true) ~= nil)
    end)

    it("validates the exact scalar, filter, and read-port context", function()
        local valid = fixture({}, {})
        local scenarios = {
            { field = "world_id", value = "" },
            { field = "game_revision", value = 0 },
            { field = "game_revision", value = 1.5 },
            { field = "deployment_profile", value = false },
            { field = "target_slots", value = 0 },
            { field = "include_guild_ids", value = { "guild/a", "guild/a" } },
            { field = "exclude_guild_ids", value = { [2] = "guild/a" } },
            { field = "list_guilds", value = false },
            { field = "resolve_guild_chest", value = false },
            { field = "snapshot_container", value = false },
        }
        for _, scenario in ipairs(scenarios) do
            local context = {}
            for key, value in pairs(valid) do
                context[key] = value
            end
            context[scenario.field] = scenario.value
            local ok, err = pcall(audit.capture, context)
            a.equal(false, ok)
            a.equal("CGCE-AUD-CONTEXT", err.code)
            a.equal(scenario.field, err.field)
            a.equal("string", type(err.detail))
        end
    end)
end)
