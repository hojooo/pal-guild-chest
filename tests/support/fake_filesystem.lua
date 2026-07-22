local fake_filesystem = {}

local REQUIRED_CAPABILITIES = {
    no_follow = true,
    atomic_replace = true,
    durable_flush = true,
}

local function normalize(path)
    return (path:gsub("/", "\\"))
end

local function fold(path)
    return string.lower(normalize(path))
end

local function copy_table(value)
    local copy = {}
    for key, item in pairs(value) do
        copy[key] = item
    end
    return copy
end

function fake_filesystem.new(options)
    options = options or {}

    local configured_capabilities = options.capabilities or REQUIRED_CAPABILITIES
    local entries = {}
    for path, descriptor in pairs(options.entries or {}) do
        local node
        if type(descriptor) == "string" then
            node = { kind = descriptor }
        else
            node = copy_table(descriptor)
        end
        node.canonical_path = normalize(node.canonical_path or path)
        node.reparse_point = node.reparse_point == true
        entries[fold(path)] = node
    end

    local canonical_overrides = {}
    for path, canonical in pairs(options.canonical_overrides or {}) do
        canonical_overrides[fold(path)] = normalize(canonical)
    end

    local observations = {
        capabilities = 0,
        canonicalize = {},
        inspect_no_follow = {},
        propose_temp_sibling = {},
        writes = 0,
        closes = 0,
        atomic_replaces = 0,
        directory_flushes = 0,
        persistence_sequence = {},
        host_io = 0,
    }

    local fs = {}
    local open_handles = setmetatable({}, { __mode = "k" })

    local function record_persistence(name)
        observations.persistence_sequence[#observations.persistence_sequence + 1] = name
    end

    function fs.capabilities()
        observations.capabilities = observations.capabilities + 1
        return copy_table(configured_capabilities)
    end

    function fs.canonicalize(path)
        local normalized = normalize(path)
        observations.canonicalize[#observations.canonicalize + 1] = normalized
        local override = canonical_overrides[fold(normalized)]
        if override ~= nil then
            return override
        end
        local node = entries[fold(normalized)]
        if node ~= nil then
            return node.canonical_path
        end
        return normalized
    end

    function fs.inspect_no_follow(path)
        local normalized = normalize(path)
        observations.inspect_no_follow[#observations.inspect_no_follow + 1] = normalized
        local node = entries[fold(normalized)]
        if node == nil then
            return { kind = "missing", reparse_point = false }
        end
        return {
            kind = node.kind,
            reparse_point = node.reparse_point,
        }
    end

    function fs.propose_temp_sibling(target)
        observations.propose_temp_sibling[#observations.propose_temp_sibling + 1] = target
        if type(options.temp_sibling) == "function" then
            return options.temp_sibling(target)
        end
        return options.temp_sibling or (target .. ".cgce.tmp")
    end

    function fs.create_exclusive(path)
        record_persistence("create_exclusive")
        local normalized = normalize(path)
        local key = fold(normalized)
        if entries[key] ~= nil then
            return nil, "exists"
        end

        local node = {
            kind = "file",
            canonical_path = normalized,
            reparse_point = false,
            content = "",
        }
        entries[key] = node
        local handle = function() end
        open_handles[handle] = {
            key = key,
            node = node,
            closed = false,
        }
        return handle
    end

    function fs.write_all(handle, bytes)
        record_persistence("write_all")
        local open = open_handles[handle]
        if open == nil or open.closed or type(bytes) ~= "string" then
            return nil, "invalid handle"
        end
        open.node.content = bytes
        observations.writes = observations.writes + 1
        return true
    end

    function fs.flush_file(handle)
        record_persistence("flush_file")
        local open = open_handles[handle]
        if open == nil or open.closed then
            return nil, "invalid handle"
        end
        return true
    end

    function fs.close_file(handle)
        record_persistence("close_file")
        local open = open_handles[handle]
        if open == nil or open.closed then
            return nil, "invalid handle"
        end
        open.closed = true
        observations.closes = observations.closes + 1
        return true
    end

    function fs.atomic_replace(temp_path, target_path)
        record_persistence("atomic_replace")
        local temp_key = fold(temp_path)
        local target = normalize(target_path)
        local node = entries[temp_key]
        if node == nil or node.kind ~= "file" or node.reparse_point then
            return nil, "invalid temp"
        end

        entries[temp_key] = nil
        entries[fold(target)] = {
            kind = "file",
            canonical_path = target,
            reparse_point = false,
            content = node.content,
        }
        observations.atomic_replaces = observations.atomic_replaces + 1
        return true
    end

    function fs.flush_directory(path)
        record_persistence("flush_directory")
        local node = entries[fold(path)]
        if node == nil or node.kind ~= "directory" or node.reparse_point then
            return nil, "invalid directory"
        end
        observations.directory_flushes = observations.directory_flushes + 1
        return true
    end

    function fs.read_all_no_follow(path)
        record_persistence("read_all_no_follow")
        local node = entries[fold(path)]
        if node == nil then
            return nil, "missing"
        end
        if node.kind ~= "file" or node.reparse_point or type(node.content) ~= "string" then
            return nil, "not-readable"
        end
        return node.content
    end

    return fs, observations
end

return fake_filesystem
