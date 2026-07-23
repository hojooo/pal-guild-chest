local module_argument = ...
local MODULE_NAME = "CrossplayGuildChestExpander.Scripts.main"
local PACKAGE_DIRECTORY = "CrossplayGuildChestExpander"

if module_argument == nil and type(package.loaded[MODULE_NAME]) == "table" then
    return package.loaded[MODULE_NAME]
end

local function package_root_from_source()
    if type(debug) ~= "table" or type(debug.getinfo) ~= "function" then
        return nil
    end
    local info = debug.getinfo(1, "S")
    local source = info and info.source
    if type(source) ~= "string" or source:sub(1, 1) ~= "@" then
        return nil
    end
    local path = source:sub(2):gsub("\\", "/")
    local relative_prefix = PACKAGE_DIRECTORY .. "/Scripts/"
    if path:sub(1, #relative_prefix) == relative_prefix then
        return "."
    end
    local marker = "/" .. relative_prefix
    local marker_start = path:find(marker, 1, true)
    if marker_start == nil then
        return nil
    end
    return path:sub(1, marker_start - 1)
end

local function package_root_from_search_path()
    local suffix = PACKAGE_DIRECTORY .. "/Scripts/?.lua"
    for entry in package.path:gmatch("[^;]+") do
        local normalized = entry:gsub("\\", "/")
        if normalized == suffix then
            return "."
        end
        local marker = "/" .. suffix
        if normalized:sub(-#marker) == marker then
            return normalized:sub(1, #normalized - #marker)
        end
    end
    return nil
end

local function install_package_root()
    local mods_directory = package_root_from_source() or package_root_from_search_path()
    if mods_directory == nil or mods_directory == "" then
        return false
    end
    local separator = package.config:sub(1, 1)
    local native_directory = mods_directory:gsub("[/\\]", separator)
    local pattern = native_directory .. separator .. "?.lua"
    for entry in package.path:gmatch("[^;]+") do
        if entry == pattern then
            return true
        end
    end
    package.path = pattern .. ";" .. package.path
    return true
end

local path_ready = install_package_root()
local cgce_module
if path_ready then
    local loaded, value = pcall(require, "CrossplayGuildChestExpander.Scripts.cgce")
    if loaded and type(value) == "table" then
        cgce_module = value
    else
        path_ready = false
    end
end

local cgce_new = cgce_module and cgce_module.new
local cgce_shutdown = cgce_module and cgce_module.shutdown
local cgce_status = cgce_module and cgce_module.status
local main = {}
local bootstrap_record

local function loader_problem(detail)
    return {
        code = "CGCE-LOADER-COMPOSITION-UNAVAILABLE",
        field = "production_dependencies",
        detail = detail,
    }
end

local function blocked_loader_result(detail)
    return {
        state = "BLOCKED",
        pending = false,
        terminal = true,
        report_persisted = false,
        errors = { loader_problem(detail) },
    }
end

local function refresh_bootstrap_record()
    if bootstrap_record == nil
        or bootstrap_record.app == nil
        or cgce_status == nil then
        return
    end
    local result, err = cgce_status(bootstrap_record.app)
    bootstrap_record.result = result
    bootstrap_record.error = err
end

function main.start(dependencies)
    if cgce_new == nil then
        return nil, blocked_loader_result("the installed package root could not be verified"), nil
    end
    local app = cgce_new(dependencies)
    local result, err = app:start()
    return app, result, err
end

function main.bootstrap(dependencies)
    if bootstrap_record ~= nil then
        refresh_bootstrap_record()
        return bootstrap_record.app, bootstrap_record.result, bootstrap_record.error
    end
    if dependencies == nil then
        bootstrap_record = {
            result = blocked_loader_result(
                path_ready
                    and "verified production read-only ports are not packaged yet"
                    or "the installed package root could not be verified"
            ),
        }
        return nil, bootstrap_record.result, nil
    end
    local app, result, err = main.start(dependencies)
    bootstrap_record = { app = app, result = result, error = err }
    return app, result, err
end

function main.status()
    if bootstrap_record == nil then
        return nil
    end
    refresh_bootstrap_record()
    return bootstrap_record.result, bootstrap_record.error
end

function main.shutdown()
    if bootstrap_record == nil then
        return true, {}
    end
    if bootstrap_record.app == nil then
        bootstrap_record = nil
        return true, {}
    end
    local ok, errors = cgce_shutdown(bootstrap_record.app)
    if ok then
        bootstrap_record = nil
    end
    return ok, errors
end

package.loaded[MODULE_NAME] = main

if module_argument == nil then
    local _, result = main.bootstrap()
    print(result.errors[1].code .. ": " .. result.errors[1].detail)
end

return main
