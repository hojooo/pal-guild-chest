local a = require("tests.support.assertions")
local json = require("CrossplayGuildChestExpander.Scripts.json")
local logger = require("CrossplayGuildChestExpander.Scripts.logger")

local MAX_EVENT_BYTES = 16 * 1024

local function event(overrides)
    local value = {
        timestamp = "2026-07-22T00:00:00Z",
        level = "INFO",
        event = "guild_chest_audited",
        world_id = "world/alpha",
    }

    for key, item in pairs(overrides or {}) do
        value[key] = item
    end
    return value
end

local function expect_error(code, field, fn)
    local ok, err = pcall(fn)
    a.equal(false, ok)
    a.equal("table", type(err))
    a.equal(code, err.code)
    a.equal(field, err.field)
    a.equal("string", type(err.detail))
    return err
end

local function decode_jsonl(line)
    a.equal("\n", line:sub(-1))
    local body = line:sub(1, -2)
    a.equal(nil, body:find("[\r\n]"))
    return json.decode(body)
end

local function assert_one_physical_line(line)
    a.equal("\n", line:sub(-1))
    a.equal(nil, line:sub(1, -2):find("[\r\n]"))
end

describe("logger", function()
    it("requires timestamp, exact level, and event without coercion", function()
        local levels = { "DEBUG", "INFO", "WARNING", "BLOCKING", "CRITICAL" }
        for _, level in ipairs(levels) do
            local decoded = decode_jsonl(logger.jsonl(event({ level = level })))
            a.equal(level, decoded.level)
        end

        local missing = event()
        missing.timestamp = nil
        expect_error("CGCE-LOG-MISSING-FIELD", "timestamp", function()
            logger.jsonl(missing)
        end)
        expect_error("CGCE-LOG-FIELD", "timestamp", function()
            logger.jsonl(event({ timestamp = "" }))
        end)
        expect_error("CGCE-LOG-FIELD", "event", function()
            logger.jsonl(event({ event = 42 }))
        end)
        expect_error("CGCE-LOG-LEVEL", "level", function()
            logger.jsonl(event({ level = "ERROR" }))
        end)
    end)

    it("recursively redacts normalized credential-key variants without mutating input", function()
        local input = event({
            AdminPassword = "admin-secret",
            nested = {
                ["approval-token"] = "approval-secret",
                API_KEY = "api-secret",
                Authorization = "bearer-secret",
                Cookie = "cookie-secret",
                ["session-cookie"] = "session-cookie-secret",
                Credentials = {
                    private_key = "private-secret",
                    safe_value = "visible",
                },
            },
            items = json.array({
                { refresh_token = "refresh-secret", name = "visible-item" },
            }),
            empty = json.array(),
        })

        local decoded = decode_jsonl(logger.jsonl(input))
        a.equal("[REDACTED]", decoded.AdminPassword)
        a.equal("[REDACTED]", decoded.nested["approval-token"])
        a.equal("[REDACTED]", decoded.nested.API_KEY)
        a.equal("[REDACTED]", decoded.nested.Authorization)
        a.equal("[REDACTED]", decoded.nested.Cookie)
        a.equal("[REDACTED]", decoded.nested["session-cookie"])
        a.equal("[REDACTED]", decoded.nested.Credentials)
        a.equal("[REDACTED]", decoded.items[1].refresh_token)
        a.equal("visible-item", decoded.items[1].name)
        a.equal("[]", json.encode(decoded.empty))

        a.equal("admin-secret", input.AdminPassword)
        a.equal("private-secret", input.nested.Credentials.private_key)
        a.equal("refresh-secret", input.items[1].refresh_token)
    end)

    it("escapes controls so text and JSONL each remain one physical line", function()
        local input = event({
            timestamp = "2026-07-22\n00:00:00Z",
            event = "audit\rcomplete",
            message = "line1\nline2\r\t" .. string.char(1),
        })

        local text_line = logger.text(input)
        local json_line = logger.jsonl(input)
        assert_one_physical_line(text_line)
        assert_one_physical_line(json_line)
        a.equal(true, text_line:find("\\n", 1, true) ~= nil)
        a.equal(true, text_line:find("\\r", 1, true) ~= nil)
        a.equal(true, json_line:find("\\u0001", 1, true) ~= nil)

        local decoded = decode_jsonl(json_line)
        a.equal(input.timestamp, decoded.timestamp)
        a.equal(input.event, decoded.event)
        a.equal(input.message, decoded.message)
    end)

    it("rejects non-JSON-safe, invalid UTF-8, non-finite, and cyclic values", function()
        expect_error("CGCE-LOG-VALUE", "message", function()
            logger.jsonl(event({ message = string.char(0xFF) }))
        end)
        expect_error("CGCE-LOG-VALUE", "duration_ms", function()
            logger.jsonl(event({ duration_ms = math.huge }))
        end)
        expect_error("CGCE-LOG-VALUE", "callback", function()
            logger.jsonl(event({ callback = function() end }))
        end)

        local cyclic = {}
        cyclic.self = cyclic
        expect_error("CGCE-LOG-VALUE", "details.self", function()
            logger.jsonl(event({ details = cyclic }))
        end)

        expect_error("CGCE-LOG-VALUE", "values", function()
            logger.jsonl(event({ values = { [1] = "a", [3] = "b" } }))
        end)
        expect_error("CGCE-LOG-VALUE", "details", function()
            logger.jsonl(event({ details = setmetatable({}, {}) }))
        end)
    end)

    it("rejects per-slot INFO-or-higher details while allowing DEBUG", function()
        for _, level in ipairs({ "INFO", "WARNING", "BLOCKING", "CRITICAL" }) do
            expect_error("CGCE-LOG-PER-SLOT", "details.slot_index", function()
                logger.jsonl(event({
                    level = level,
                    details = { slot_index = 1, slot_fingerprint = string.rep("a", 64) },
                }))
            end)
            expect_error("CGCE-LOG-PER-SLOT", "granularity", function()
                logger.jsonl(event({
                    level = level,
                    granularity = "slot",
                }))
            end)
            expect_error("CGCE-LOG-PER-SLOT", "slots", function()
                logger.jsonl(event({
                    level = level,
                    slots = json.array({ { occupied = false } }),
                }))
            end)
        end

        local debug = decode_jsonl(logger.jsonl(event({
            level = "DEBUG",
            details = { slot_index = 1, slot_fingerprint = string.rep("a", 64) },
        })))
        a.equal(1, debug.details.slot_index)

        local aggregate = decode_jsonl(logger.jsonl(event({
            before_slots = 54,
            after_slots = 358,
            occupied_slots = 27,
            slot_count = 358,
        })))
        a.equal(358, aggregate.after_slots)
        a.equal(358, aggregate.slot_count)
    end)

    it("enforces the 16 KiB boundary including newline and emits valid replacements", function()
        local empty_line = logger.jsonl(event({ message = "" }))
        local exact_payload_length = MAX_EVENT_BYTES - #empty_line
        local exact_line = logger.jsonl(event({ message = string.rep("x", exact_payload_length) }))
        a.equal(MAX_EVENT_BYTES, #exact_line)
        a.equal("guild_chest_audited", decode_jsonl(exact_line).event)

        local oversized_json = logger.jsonl(event({
            message = string.rep("x", exact_payload_length + 1),
            AdminPassword = "must-not-appear",
        }))
        local replacement = decode_jsonl(oversized_json)
        a.equal(true, #oversized_json <= MAX_EVENT_BYTES)
        a.equal("log_event_oversize", replacement.event)
        a.equal("WARNING", replacement.level)
        a.equal("jsonl", replacement.format)
        a.equal("guild_chest_audited", replacement.original_event)
        a.equal(true, replacement.dropped)
        a.equal(true, replacement.original_size_bytes > MAX_EVENT_BYTES)
        a.equal(false, oversized_json:find("must-not-appear", 1, true) ~= nil)
        a.equal(false, oversized_json:find(string.rep("x", 128), 1, true) ~= nil)

        local oversized_text = logger.text(event({ message = string.rep("y", MAX_EVENT_BYTES) }))
        assert_one_physical_line(oversized_text)
        a.equal(true, #oversized_text <= MAX_EVENT_BYTES)
        a.equal(true, oversized_text:find("log_event_oversize", 1, true) ~= nil)
        a.equal(false, oversized_text:find(string.rep("y", 128), 1, true) ~= nil)

        local event_256 = string.rep("a", 253) .. "한"
        local event_257 = string.rep("a", 254) .. "한"
        a.equal(256, #event_256)
        a.equal(257, #event_257)

        local bounded = decode_jsonl(logger.jsonl(event({
            event = event_256,
            message = string.rep("z", MAX_EVENT_BYTES),
        })))
        a.equal(event_256, bounded.original_event)
        a.equal(true, bounded.dropped)

        local omitted = decode_jsonl(logger.jsonl(event({
            event = event_257,
            message = string.rep("z", MAX_EVENT_BYTES),
        })))
        a.equal("event_name_omitted", omitted.original_event)
        a.equal(true, omitted.dropped)
    end)

    it("performs formatting without I/O or mutable sibling dispatch", function()
        local original_io = _G.io
        local original_json_encode = json.encode
        local original_logger_jsonl = logger.jsonl

        _G.io = setmetatable({}, {
            __index = function()
                error("I/O access is forbidden")
            end,
        })
        json.encode = function()
            error("mutable json.encode dispatch is forbidden")
        end
        logger.jsonl = function()
            error("mutable logger.jsonl dispatch is forbidden")
        end

        local ok_json, json_line = pcall(original_logger_jsonl, event())
        local ok_text, text_line = pcall(logger.text, event())

        logger.jsonl = original_logger_jsonl
        json.encode = original_json_encode
        _G.io = original_io

        a.equal(true, ok_json)
        a.equal(true, ok_text)
        assert_one_physical_line(json_line)
        assert_one_physical_line(text_line)
    end)
end)
