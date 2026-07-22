local path_guard = {}

local required_capabilities = {
    "no_follow",
    "atomic_replace",
    "durable_flush",
}

local reserved_names = {
    con = true,
    prn = true,
    aux = true,
    nul = true,
    ["conin$"] = true,
    ["conout$"] = true,
    ["clock$"] = true,
}

local function fail(code, field, detail)
    error({
        code = code,
        field = field,
        detail = detail,
    }, 0)
end

local function has_control(value)
    return value:find("[%z\1-\31\127]") ~= nil
end

local function normalize_separators(value)
    return (value:gsub("/", "\\"))
end

local function fold(value)
    return string.lower(normalize_separators(value))
end

local function is_reserved_component(component)
    local stem = component:match("^([^.]*)") or component
    stem = stem:gsub("[ .]+$", "")
    local normalized_stem = string.lower(stem)
    local numbered_device = normalized_stem:match("^com([1-9])$") ~= nil
        or normalized_stem:match("^lpt([1-9])$") ~= nil
    local superscript_device = normalized_stem == "com\194\185"
        or normalized_stem == "com\194\178"
        or normalized_stem == "com\194\179"
        or normalized_stem == "lpt\194\185"
        or normalized_stem == "lpt\194\178"
        or normalized_stem == "lpt\194\179"
    return reserved_names[normalized_stem] == true or numbered_device or superscript_device
end

local function valid_absolute_component(component)
    return component ~= ""
        and component ~= "."
        and component ~= ".."
        and not has_control(component)
        and component:find(":", 1, true) == nil
        and component:find('[<>"|?*]') == nil
        and component:sub(-1) ~= "."
        and component:sub(-1) ~= " "
        and not is_reserved_component(component)
end

local function validate_component(component, field)
    if component == "" or component == "." then
        fail("CGCE-PATH-COMPONENT", field, "path components must be non-empty and not dot")
    end
    if component == ".." then
        fail("CGCE-PATH-TRAVERSAL", field, "parent traversal is forbidden")
    end
    if has_control(component) then
        fail("CGCE-PATH-CONTROL", field, "path components must not contain controls")
    end
    if component:find(":", 1, true) ~= nil then
        fail("CGCE-PATH-COLON", field, "drive and alternate-data-stream syntax is forbidden")
    end
    if component:find('[<>"|?*]') ~= nil then
        fail("CGCE-PATH-COMPONENT", field, "path component contains a forbidden Windows character")
    end
    local final = component:sub(-1)
    if final == "." or final == " " then
        fail("CGCE-PATH-TRAILING", field, "path components must not end in dot or space")
    end

    if is_reserved_component(component) then
        fail("CGCE-PATH-RESERVED", field, "Windows reserved device names are forbidden")
    end
end

local function split_relative(relative_path)
    if type(relative_path) ~= "string" or relative_path == "" then
        fail("CGCE-PATH-RELATIVE", "relative_path", "relative_path must be a non-empty string")
    end

    local first = relative_path:sub(1, 1)
    if first == "/" or first == "\\" or relative_path:match("^[A-Za-z]:") ~= nil then
        fail("CGCE-PATH-ABSOLUTE", "relative_path", "relative_path must not be absolute or drive-relative")
    end

    local components = {}
    local start = 1
    local index = 1
    while index <= #relative_path do
        local character = relative_path:sub(index, index)
        if character == "/" or character == "\\" then
            components[#components + 1] = relative_path:sub(start, index - 1)
            start = index + 1
        end
        index = index + 1
    end
    components[#components + 1] = relative_path:sub(start)

    for component_index, component in ipairs(components) do
        validate_component(component, "relative_path[" .. tostring(component_index) .. "]")
    end
    return components
end

local function parse_absolute(path)
    if type(path) ~= "string" or path == "" or has_control(path) then
        return nil
    end

    local normalized = normalize_separators(path)
    local lowered = string.lower(normalized)
    if lowered:sub(1, 4) == "\\\\?\\"
        or lowered:sub(1, 4) == "\\\\.\\"
        or lowered:sub(1, 4) == "\\??\\" then
        return nil
    end

    local components = {}
    local root
    local remainder
    if normalized:match("^[A-Za-z]:\\") ~= nil then
        root = normalized:sub(1, 3)
        remainder = normalized:sub(4)
    elseif normalized:sub(1, 2) == "\\\\" then
        local server_end = normalized:find("\\", 3, true)
        if server_end == nil or server_end == 3 then
            return nil
        end
        local server = normalized:sub(3, server_end - 1)
        local share_end = normalized:find("\\", server_end + 1, true)
        local share
        if share_end == nil then
            share = normalized:sub(server_end + 1)
            remainder = ""
        else
            share = normalized:sub(server_end + 1, share_end - 1)
            remainder = normalized:sub(share_end + 1)
        end
        if not valid_absolute_component(server) or not valid_absolute_component(share) then
            return nil
        end
        root = normalized:sub(1, server_end - 1) .. "\\" .. share
    else
        return nil
    end

    if remainder ~= "" then
        local start = 1
        for index = 1, #remainder do
            if remainder:sub(index, index) == "\\" then
                components[#components + 1] = remainder:sub(start, index - 1)
                start = index + 1
            end
        end
        components[#components + 1] = remainder:sub(start)
    end

    for _, component in ipairs(components) do
        if not valid_absolute_component(component) then
            return nil
        end
    end

    local canonical = root
    for _, component in ipairs(components) do
        if canonical:sub(-1) == "\\" then
            canonical = canonical .. component
        else
            canonical = canonical .. "\\" .. component
        end
    end

    return {
        normalized = canonical,
        root = root,
        components = components,
    }
end

local function join(parent, component)
    if parent:sub(-1) == "\\" then
        return parent .. component
    end
    return parent .. "\\" .. component
end

local function parent_of(path)
    local parent = path:match("^(.*)\\[^\\]+$")
    if parent ~= nil and parent:match("^[A-Za-z]:$") ~= nil then
        return parent .. "\\"
    end
    return parent
end

local function within(root, candidate)
    local folded_root = fold(root)
    local folded_candidate = fold(candidate)
    if folded_candidate == folded_root then
        return true
    end
    local boundary = folded_root:sub(-1) == "\\" and folded_root or (folded_root .. "\\")
    return folded_candidate:sub(1, #boundary) == boundary
end

local function same_path(left, right)
    return fold(left) == fold(right)
end

local function require_port(fs, name)
    local value = rawget(fs, name)
    if type(value) ~= "function" then
        fail("CGCE-PATH-PORT", name, "required read-only filesystem port is unavailable")
    end
    return value
end

local function call_port(name, port, argument)
    local ok, value, returned_error = pcall(port, argument)
    if not ok or returned_error ~= nil then
        fail("CGCE-PATH-FS-ERROR", name, "filesystem port failed")
    end
    return value
end

local function canonicalize(port, path)
    local canonical = call_port("canonicalize", port, path)
    local parsed = parse_absolute(canonical)
    if parsed == nil then
        fail("CGCE-PATH-FS-ERROR", "canonicalize", "filesystem returned a malformed canonical path")
    end
    return parsed.normalized
end

local function inspect(port, path)
    local value = call_port("inspect_no_follow", port, path)
    if type(value) ~= "table"
        or getmetatable(value) ~= nil
        or (value.kind ~= "missing" and value.kind ~= "directory" and value.kind ~= "file")
        or type(value.reparse_point) ~= "boolean" then
        fail("CGCE-PATH-FS-ERROR", "inspect_no_follow", "filesystem returned malformed no-follow metadata")
    end
    return value
end

local function reject_reparse(metadata, field)
    if metadata.reparse_point then
        fail("CGCE-PATH-REPARSE", field, "symlink and reparse traversal is forbidden")
    end
end

local function require_directory(metadata, field)
    reject_reparse(metadata, field)
    if metadata.kind == "missing" then
        fail("CGCE-PATH-MISSING", field, "path parent is missing")
    end
    if metadata.kind ~= "directory" then
        fail("CGCE-PATH-NOT-DIRECTORY", field, "path parent is not a directory")
    end
end

local function inspect_directory(port, lexical, canonical, field)
    require_directory(inspect(port, lexical), field)
    if not same_path(lexical, canonical) then
        require_directory(inspect(port, canonical), field)
    end
end

local function inspect_target(port, lexical, canonical, field)
    local lexical_metadata = inspect(port, lexical)
    reject_reparse(lexical_metadata, field)
    if lexical_metadata.kind == "directory" then
        fail("CGCE-PATH-TARGET-TYPE", field, "target must be a file or missing")
    end

    if not same_path(lexical, canonical) then
        local canonical_metadata = inspect(port, canonical)
        reject_reparse(canonical_metadata, field)
        if canonical_metadata.kind == "directory" then
            fail("CGCE-PATH-TARGET-TYPE", field, "target must be a file or missing")
        end
    end
end

function path_guard.resolve(fs, root, relative_path)
    if type(fs) ~= "table" or getmetatable(fs) ~= nil then
        fail("CGCE-PATH-PORT", "fs", "filesystem port must be a plain table")
    end

    local capabilities_port = require_port(fs, "capabilities")
    local canonicalize_port = require_port(fs, "canonicalize")
    local inspect_port = require_port(fs, "inspect_no_follow")
    local temp_port = require_port(fs, "propose_temp_sibling")

    local capabilities = call_port("capabilities", capabilities_port)
    if type(capabilities) ~= "table" or getmetatable(capabilities) ~= nil then
        fail("CGCE-PATH-FS-ERROR", "capabilities", "filesystem returned malformed capabilities")
    end
    for _, name in ipairs(required_capabilities) do
        if rawget(capabilities, name) ~= true then
            fail("CGCE-PATH-CAPABILITY", name, "required filesystem safety guarantee is unavailable")
        end
    end

    local parsed_root = type(root) == "string" and parse_absolute(root) or nil
    if parsed_root == nil then
        fail("CGCE-PATH-ROOT", "root", "root must be a standard absolute Windows path")
    end
    root = parsed_root.normalized
    local components = split_relative(relative_path)

    local root_metadata = inspect(inspect_port, root)
    require_directory(root_metadata, "root")
    local canonical_root = canonicalize(canonicalize_port, root)
    if not same_path(root, canonical_root) then
        require_directory(inspect(inspect_port, canonical_root), "root")
    end

    local current = canonical_root
    for index = 1, #components - 1 do
        local field = "relative_path[" .. tostring(index) .. "]"
        local lexical = join(current, components[index])
        local canonical = canonicalize(canonicalize_port, lexical)
        local canonical_parent = parent_of(canonical)
        if not within(canonical_root, canonical)
            or canonical_parent == nil
            or not same_path(canonical_parent, current) then
            fail("CGCE-PATH-ESCAPE", field, "canonical parent escaped the configured root boundary")
        end
        inspect_directory(inspect_port, lexical, canonical, field)
        current = canonical
    end

    local target_index = #components
    local target_field = "relative_path[" .. tostring(target_index) .. "]"
    local lexical_target = join(current, components[target_index])
    local canonical_target = canonicalize(canonicalize_port, lexical_target)
    local canonical_target_parent = parent_of(canonical_target)
    if not within(canonical_root, canonical_target)
        or canonical_target_parent == nil
        or not same_path(canonical_target_parent, current) then
        fail("CGCE-PATH-ESCAPE", target_field, "canonical target escaped the configured root boundary")
    end
    inspect_target(inspect_port, lexical_target, canonical_target, target_field)

    local proposed_temp = call_port("propose_temp_sibling", temp_port, canonical_target)
    local parsed_temp = parse_absolute(proposed_temp)
    if parsed_temp == nil then
        fail("CGCE-PATH-FS-ERROR", "propose_temp_sibling", "filesystem returned a malformed temp sibling")
    end
    proposed_temp = parsed_temp.normalized
    local proposed_temp_parent = parent_of(proposed_temp)
    if same_path(proposed_temp, canonical_target)
        or proposed_temp_parent == nil
        or not same_path(proposed_temp_parent, current) then
        fail("CGCE-PATH-TEMP", "temp_sibling", "temp candidate must be a distinct same-directory sibling")
    end

    local temp_metadata = inspect(inspect_port, proposed_temp)
    reject_reparse(temp_metadata, "temp_sibling")
    if temp_metadata.kind ~= "missing" then
        fail("CGCE-PATH-TEMP", "temp_sibling", "temp candidate must not already exist")
    end

    local canonical_temp = canonicalize(canonicalize_port, proposed_temp)
    local canonical_temp_parent = parent_of(canonical_temp)
    if not within(canonical_root, canonical_temp) then
        fail("CGCE-PATH-ESCAPE", "temp_sibling", "canonical temp path escaped the configured root boundary")
    end
    if same_path(canonical_temp, canonical_target)
        or canonical_temp_parent == nil
        or not same_path(canonical_temp_parent, current) then
        fail("CGCE-PATH-TEMP", "temp_sibling", "canonical temp path must remain a distinct same-directory sibling")
    end

    local canonical_temp_metadata = inspect(inspect_port, canonical_temp)
    reject_reparse(canonical_temp_metadata, "temp_sibling")
    if canonical_temp_metadata.kind ~= "missing" then
        fail("CGCE-PATH-TEMP", "temp_sibling", "canonical temp candidate must not already exist")
    end

    return {
        root = canonical_root,
        relative_path = table.concat(components, "\\"),
        parent = current,
        target = canonical_target,
        temp_sibling = canonical_temp,
    }
end

return path_guard
