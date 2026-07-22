local json = require("CrossplayGuildChestExpander.Scripts.json")

local platform_preflight = {}

local required_platforms = { "Steam", "PS5", "Mac" }
local allowed_platforms = {
    Steam = true,
    Xbox = true,
    PS5 = true,
    Mac = true,
}

local known_option_order = {
    "crossplayplatforms",
    "ballowclientmod",
    "publicport",
    "logformattype",
}

local function make_error(code, field, detail)
    return {
        code = code,
        field = field,
        detail = detail,
    }
end

local function has_control(text)
    return text:find("[%z\1-\31\127]") ~= nil
end

local function trim_bounds(text, first, last)
    while first <= last and text:byte(first) == 0x20 do
        first = first + 1
    end
    while last >= first and text:byte(last) == 0x20 do
        last = last - 1
    end
    return first, last
end

local function malformed_option(field, detail)
    return nil, make_error(
        "CGCE-PF-OPTION-SETTINGS-MALFORMED",
        field or "option_settings",
        detail or "OptionSettings tuple is malformed"
    )
end

local function matching_parenthesis(text, open_index)
    local depth = 0
    local quote = nil
    local escaped = false
    for index = open_index, #text do
        local character = text:sub(index, index)
        if quote ~= nil then
            if escaped then
                escaped = false
            elseif character == "\\" then
                escaped = true
            elseif character == quote then
                quote = nil
            end
        elseif character == '"' or character == "'" then
            quote = character
        elseif character == "(" then
            depth = depth + 1
        elseif character == ")" then
            depth = depth - 1
            if depth == 0 then
                return index, nil
            end
            if depth < 0 then
                return nil, make_error(
                    "CGCE-PF-OPTION-SETTINGS-MALFORMED",
                    "option_settings",
                    "OptionSettings tuple has an unmatched parenthesis"
                )
            end
        end
    end
    return nil, make_error(
        "CGCE-PF-OPTION-SETTINGS-MALFORMED",
        "option_settings",
        "OptionSettings tuple has an unterminated quote or parenthesis"
    )
end

local function split_top_level(text, first, last)
    local segments = {}
    local start = first
    local depth = 0
    local quote = nil
    local escaped = false

    for index = first, last do
        local character = text:sub(index, index)
        if quote ~= nil then
            if escaped then
                escaped = false
            elseif character == "\\" then
                escaped = true
            elseif character == quote then
                quote = nil
            end
        elseif character == '"' or character == "'" then
            quote = character
        elseif character == "(" then
            depth = depth + 1
        elseif character == ")" then
            if depth == 0 then
                return nil, make_error(
                    "CGCE-PF-OPTION-SETTINGS-MALFORMED",
                    "option_settings",
                    "OptionSettings value has an unmatched parenthesis"
                )
            end
            depth = depth - 1
        elseif character == "," and depth == 0 then
            segments[#segments + 1] = { first = start, last = index - 1 }
            start = index + 1
        end
    end

    if quote ~= nil or escaped or depth ~= 0 then
        return nil, make_error(
            "CGCE-PF-OPTION-SETTINGS-MALFORMED",
            "option_settings",
            "OptionSettings value has an unterminated quote or tuple"
        )
    end
    segments[#segments + 1] = { first = start, last = last }
    return segments, nil
end

local function find_top_level_equals(text, first, last)
    local found = nil
    local depth = 0
    local quote = nil
    local escaped = false
    for index = first, last do
        local character = text:sub(index, index)
        if quote ~= nil then
            if escaped then
                escaped = false
            elseif character == "\\" then
                escaped = true
            elseif character == quote then
                quote = nil
            end
        elseif character == '"' or character == "'" then
            quote = character
        elseif character == "(" then
            depth = depth + 1
        elseif character == ")" then
            depth = depth - 1
        elseif character == "=" and depth == 0 then
            if found ~= nil then
                return nil
            end
            found = index
        end
    end
    return found
end

local function tuple_location(text)
    local first, last = trim_bounds(text, 1, #text)
    if first > last then
        return malformed_option("option_settings", "OptionSettings must not be empty")
    end

    local open_index
    if text:sub(first, first) == "(" then
        open_index = first
    else
        local key_first, key_last = text:find("^[A-Za-z][A-Za-z0-9_]*", first)
        if key_first ~= first or text:sub(key_first, key_last) ~= "OptionSettings" then
            return malformed_option("option_settings", "expected OptionSettings assignment or tuple RHS")
        end
        local cursor = key_last + 1
        while cursor <= last and text:byte(cursor) == 0x20 do
            cursor = cursor + 1
        end
        if text:sub(cursor, cursor) ~= "=" then
            return malformed_option("option_settings", "OptionSettings assignment is missing equals")
        end
        cursor = cursor + 1
        while cursor <= last and text:byte(cursor) == 0x20 do
            cursor = cursor + 1
        end
        if text:sub(cursor, cursor) ~= "(" then
            return malformed_option("option_settings", "OptionSettings assignment is missing tuple RHS")
        end
        open_index = cursor
    end

    local close_index, close_error = matching_parenthesis(text, open_index)
    if close_error then
        return nil, close_error
    end
    if close_index ~= last then
        return malformed_option("option_settings", "unexpected text follows OptionSettings tuple")
    end
    return {
        open_index = open_index,
        close_index = close_index,
    }, nil
end

local function parse_platform_tuple(value)
    local first, last = trim_bounds(value, 1, #value)
    if first > last or value:sub(first, first) ~= "(" then
        return nil, make_error(
            "CGCE-PF-OPTION-SETTINGS-MALFORMED",
            "CrossplayPlatforms",
            "CrossplayPlatforms must be a tuple"
        )
    end
    local close_index, close_error = matching_parenthesis(value, first)
    if close_error or close_index ~= last then
        return nil, make_error(
            "CGCE-PF-OPTION-SETTINGS-MALFORMED",
            "CrossplayPlatforms",
            "CrossplayPlatforms tuple is malformed"
        )
    end

    local platform_set = {}
    if first + 1 == last then
        return platform_set, nil
    end
    local segments, segment_error = split_top_level(value, first + 1, last - 1)
    if segment_error then
        return nil, segment_error
    end
    for _, segment in ipairs(segments) do
        local item_first, item_last = trim_bounds(value, segment.first, segment.last)
        local platform = value:sub(item_first, item_last)
        if not allowed_platforms[platform] then
            return nil, make_error(
                "CGCE-PF-UNKNOWN-CROSSPLAY-PLATFORM",
                "CrossplayPlatforms",
                "CrossplayPlatforms contains an unsupported value"
            )
        end
        if platform_set[platform] then
            return nil, make_error(
                "CGCE-PF-DUPLICATE-OPTION-VALUE",
                "CrossplayPlatforms",
                "CrossplayPlatforms contains a duplicate value"
            )
        end
        platform_set[platform] = true
    end
    return platform_set, nil
end

local function parse_option_settings(text)
    if type(text) ~= "string" or has_control(text) then
        return malformed_option("option_settings", "OptionSettings must be a control-free string")
    end
    local location, location_error = tuple_location(text)
    if location_error then
        return nil, location_error
    end

    local entries = {}
    local by_key = {}
    local body_first = location.open_index + 1
    local body_last = location.close_index - 1
    local trimmed_first, trimmed_last = trim_bounds(text, body_first, body_last)
    if trimmed_first <= trimmed_last then
        local segments, segment_error = split_top_level(text, body_first, body_last)
        if segment_error then
            return nil, segment_error
        end
        for _, segment in ipairs(segments) do
            local first, last = trim_bounds(text, segment.first, segment.last)
            if first > last then
                return malformed_option("option_settings", "OptionSettings contains an empty entry")
            end
            local equals_index = find_top_level_equals(text, first, last)
            if equals_index == nil then
                return malformed_option("option_settings", "OptionSettings entry must contain one top-level equals")
            end
            local key_first, key_last = trim_bounds(text, first, equals_index - 1)
            local value_first, value_last = trim_bounds(text, equals_index + 1, last)
            local key = text:sub(key_first, key_last)
            if not key:match("^[A-Za-z][A-Za-z0-9_]*$") or value_first > value_last then
                return malformed_option("option_settings", "OptionSettings entry has an invalid key or empty value")
            end
            local normalized = string.lower(key)
            if by_key[normalized] ~= nil then
                return nil, make_error(
                    "CGCE-PF-DUPLICATE-OPTION-KEY",
                    "option_settings",
                    "OptionSettings contains a duplicate key"
                )
            end
            local entry = {
                key = key,
                normalized = normalized,
                value = text:sub(value_first, value_last),
                value_first = value_first,
                value_last = value_last,
            }
            entries[#entries + 1] = entry
            by_key[normalized] = entry
        end
    end

    local platforms = {}
    local platform_entry = by_key.crossplayplatforms
    if platform_entry ~= nil then
        local platform_error
        platforms, platform_error = parse_platform_tuple(platform_entry.value)
        if platform_error then
            return nil, platform_error
        end
    end

    return {
        text = text,
        open_index = location.open_index,
        close_index = location.close_index,
        entries = entries,
        by_key = by_key,
        platforms = platforms,
    }, nil
end

local function dense_argv_length(args)
    if type(args) ~= "table" or getmetatable(args) ~= nil then
        return nil
    end
    local count = 0
    local largest = 0
    for key in next, args do
        if type(key) ~= "number" or math.type(key) ~= "integer" or key < 1 then
            return nil
        end
        count = count + 1
        if key > largest then
            largest = key
        end
    end
    if count ~= largest then
        return nil
    end
    return count
end

local function parse_argv(args)
    local length = dense_argv_length(args)
    if length == nil then
        return nil, make_error("CGCE-PF-ARGV-MALFORMED", "args", "argv must be a dense array")
    end

    local result = { public_lobby = false }
    local seen = {}
    for index = 1, length do
        local argument = args[index]
        if type(argument) ~= "string" or has_control(argument) then
            return nil, make_error("CGCE-PF-ARGV-MALFORMED", "args", "argv entries must be control-free strings")
        end

        local key, suffix = argument:match("^%-([A-Za-z][A-Za-z0-9%-]*)(.*)$")
        if key ~= nil then
            local normalized = string.lower(key)
            if seen[normalized] then
                return nil, make_error(
                    "CGCE-PF-DUPLICATE-CLI-KEY",
                    "args",
                    "argv contains a duplicate option key"
                )
            end
            seen[normalized] = true

            if normalized == "publiclobby" then
                if suffix ~= "" then
                    return nil, make_error(
                        "CGCE-PF-PUBLIC-LOBBY-INVALID",
                        "public_lobby",
                        "-publiclobby must be a standalone switch"
                    )
                end
                result.public_lobby = true
            elseif normalized == "port" or normalized == "publicport" then
                if suffix:sub(1, 1) ~= "=" or #suffix == 1 then
                    result[normalized == "port" and "port" or "public_port"] = false
                else
                    result[normalized == "port" and "port" or "public_port"] = suffix:sub(2)
                end
            end
        end
    end
    return result, nil
end

local function parse_port(value)
    if type(value) ~= "string" or not value:match("^%d+$") then
        return nil
    end
    local number = tonumber(value)
    if number == nil or math.type(number) ~= "integer" or number < 1 or number > 65535 then
        return nil
    end
    return number
end

local function failure_report(finding)
    return {
        preflight_ok = false,
        state = "PS5_CONNECTIVITY_MISCONFIGURED",
        certification = "UNPROVEN",
        diagnostic_only = true,
        evidence = {
            public_lobby = false,
            required_platforms = { Steam = false, PS5 = false, Mac = false },
            xbox = false,
        },
        findings = json.array({ finding }),
    }
end

local function add_finding(findings, code, field, detail)
    findings[#findings + 1] = make_error(code, field, detail)
end

function platform_preflight.check(args, option_settings)
    local parsed_args, args_error = parse_argv(args)
    if args_error then
        return failure_report(args_error)
    end
    local parsed_options, options_error = parse_option_settings(option_settings)
    if options_error then
        return failure_report(options_error)
    end

    local cli_port = parse_port(parsed_args.port)
    local cli_public_port = parse_port(parsed_args.public_port)
    local ini_port_entry = parsed_options.by_key.publicport
    local ini_port = ini_port_entry and parse_port(ini_port_entry.value) or nil
    local platforms = parsed_options.platforms
    local client_mod_entry = parsed_options.by_key.ballowclientmod
    local log_format_entry = parsed_options.by_key.logformattype
    local findings = json.array({})
    local client_mod_allowed = nil
    if client_mod_entry ~= nil then
        if client_mod_entry.value == "True" then
            client_mod_allowed = true
        elseif client_mod_entry.value == "False" then
            client_mod_allowed = false
        end
    end
    local log_format = "INVALID"
    if log_format_entry ~= nil and log_format_entry.value == "Json" then
        log_format = "Json"
    end

    if not parsed_args.public_lobby then
        add_finding(findings, "CGCE-PF-PUBLIC-LOBBY-REQUIRED", "public_lobby", "-publiclobby is required")
    end
    if cli_port == nil then
        add_finding(findings, "CGCE-PF-GAME-PORT-INVALID", "port", "-port must be an integer from 1 to 65535")
    end
    if cli_public_port == nil then
        add_finding(findings, "CGCE-PF-PUBLIC-PORT-INVALID", "public_port", "-publicport must be an integer from 1 to 65535")
    end
    if ini_port == nil then
        add_finding(findings, "CGCE-PF-OPTION-PUBLIC-PORT-INVALID", "PublicPort", "PublicPort must be an integer from 1 to 65535")
    end
    if cli_port ~= nil and cli_public_port ~= nil and ini_port ~= nil
        and (cli_port ~= cli_public_port or cli_port ~= ini_port) then
        add_finding(findings, "CGCE-PF-PUBLIC-PORT-MISMATCH", "PublicPort", "advertised and configured ports must match")
    end
    for _, platform in ipairs(required_platforms) do
        if not platforms[platform] then
            add_finding(
                findings,
                "CGCE-PF-REQUIRED-PLATFORM-MISSING",
                "CrossplayPlatforms",
                "a required vanilla client platform is missing"
            )
        end
    end
    if client_mod_entry == nil or client_mod_entry.value ~= "False" then
        add_finding(
            findings,
            "CGCE-PF-CLIENT-MOD-MUST-BE-FALSE",
            "bAllowClientMod",
            "client mods must be disabled"
        )
    end
    if log_format_entry == nil or log_format_entry.value ~= "Json" then
        add_finding(
            findings,
            "CGCE-PF-LOG-FORMAT-MUST-BE-JSON",
            "LogFormatType",
            "structured JSON logging is required"
        )
    end

    local ok = #findings == 0
    return {
        preflight_ok = ok,
        state = ok and "CONNECTIVITY_PREFLIGHT_OK" or "PS5_CONNECTIVITY_MISCONFIGURED",
        certification = "UNPROVEN",
        diagnostic_only = true,
        evidence = {
            public_lobby = parsed_args.public_lobby,
            game_port = cli_port,
            public_port = cli_public_port,
            ini_public_port = ini_port,
            required_platforms = {
                Steam = platforms.Steam == true,
                PS5 = platforms.PS5 == true,
                Mac = platforms.Mac == true,
            },
            xbox = platforms.Xbox == true,
            client_mod_allowed = client_mod_allowed,
            log_format = log_format,
        },
        findings = findings,
    }
end

local merge_policy_fields = {
    public_port = true,
    include_xbox = true,
}

local function validate_merge_policy(policy)
    if type(policy) ~= "table" then
        return nil, make_error("CGCE-PF-MERGE-POLICY-INVALID", "policy", "merge policy must be a table")
    end
    local unknown = {}
    local non_string = false
    for key in next, policy do
        if type(key) ~= "string" then
            non_string = true
        elseif not merge_policy_fields[key] then
            unknown[#unknown + 1] = key
        end
    end
    if non_string then
        return nil, make_error("CGCE-PF-MERGE-POLICY-INVALID", "policy", "merge policy contains an invalid field")
    end
    table.sort(unknown)
    if unknown[1] then
        return nil, make_error("CGCE-PF-MERGE-POLICY-INVALID", unknown[1], "merge policy contains an unknown field")
    end

    local public_port = rawget(policy, "public_port")
    if type(public_port) ~= "number"
        or math.type(public_port) ~= "integer"
        or public_port < 1
        or public_port > 65535 then
        return nil, make_error("CGCE-PF-MERGE-POLICY-INVALID", "public_port", "public_port must be an integer from 1 to 65535")
    end
    local include_xbox = rawget(policy, "include_xbox")
    if include_xbox ~= nil and type(include_xbox) ~= "boolean" then
        return nil, make_error("CGCE-PF-MERGE-POLICY-INVALID", "include_xbox", "include_xbox must be a boolean")
    end
    return {
        public_port = public_port,
        include_xbox = include_xbox == true,
    }, nil
end

local function apply_edits(text, edits)
    table.sort(edits, function(left, right)
        return left.first < right.first
    end)
    local pieces = {}
    local cursor = 1
    for _, edit in ipairs(edits) do
        pieces[#pieces + 1] = text:sub(cursor, edit.first - 1)
        pieces[#pieces + 1] = edit.value
        cursor = edit.last + 1
    end
    pieces[#pieces + 1] = text:sub(cursor)
    return table.concat(pieces)
end

function platform_preflight.merge_option_settings(option_settings, policy)
    local checked_policy, policy_error = validate_merge_policy(policy)
    if policy_error then
        return nil, policy_error
    end
    local parsed, parse_error = parse_option_settings(option_settings)
    if parse_error then
        return nil, parse_error
    end

    local include_xbox = checked_policy.include_xbox or parsed.platforms.Xbox == true
    local platform_value = include_xbox
        and "(Steam,Xbox,PS5,Mac)"
        or "(Steam,PS5,Mac)"
    local replacements = {
        crossplayplatforms = platform_value,
        ballowclientmod = "False",
        publicport = tostring(checked_policy.public_port),
        logformattype = "Json",
    }
    local canonical_names = {
        crossplayplatforms = "CrossplayPlatforms",
        ballowclientmod = "bAllowClientMod",
        publicport = "PublicPort",
        logformattype = "LogFormatType",
    }

    local edits = {}
    local missing = {}
    for _, normalized in ipairs(known_option_order) do
        local entry = parsed.by_key[normalized]
        if entry ~= nil then
            edits[#edits + 1] = {
                first = entry.value_first,
                last = entry.value_last,
                value = replacements[normalized],
            }
        else
            missing[#missing + 1] = canonical_names[normalized] .. "=" .. replacements[normalized]
        end
    end

    if #missing > 0 then
        local body_first = parsed.open_index + 1
        local body_last = parsed.close_index - 1
        local _, content_last = trim_bounds(option_settings, body_first, body_last)
        local insertion_at
        local prefix
        if #parsed.entries == 0 then
            insertion_at = body_first
            prefix = ""
        else
            insertion_at = content_last + 1
            prefix = ","
        end
        edits[#edits + 1] = {
            first = insertion_at,
            last = insertion_at - 1,
            value = prefix .. table.concat(missing, ","),
        }
    end

    return apply_edits(option_settings, edits), nil
end

return platform_preflight
