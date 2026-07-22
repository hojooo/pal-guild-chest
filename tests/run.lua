local suites, failures = {}, 0

package.path = "./?.lua;./?/init.lua;" .. package.path

local function report_failure(name, err)
    failures = failures + 1
    io.stderr:write("FAIL ", name, "\n", err, "\n")
end

function describe(name, fn)
    suites[#suites + 1] = name
    local ok, err = xpcall(fn, debug.traceback)
    if not ok then
        report_failure(table.concat(suites, " > "), err)
    end
    suites[#suites] = nil
end

function it(name, fn)
    local ok, err = xpcall(fn, debug.traceback)
    if ok then
        io.write("PASS ", table.concat(suites, " > "), " > ", name, "\n")
    else
        report_failure(name, err)
    end
end

if #arg == 0 then
    io.stderr:write("No test files specified.\n")
    os.exit(1)
end

for _, path in ipairs(arg) do
    local chunk, err = loadfile(path)
    if not chunk then
        report_failure(path, err)
    else
        local ok, load_err = xpcall(chunk, debug.traceback)
        if not ok then
            report_failure(path, load_err)
        end
    end
end

os.exit(failures == 0 and 0 or 1)
