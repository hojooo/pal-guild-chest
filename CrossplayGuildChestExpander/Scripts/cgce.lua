local approval_module = require("CrossplayGuildChestExpander.Scripts.approval")
local audit_module = require("CrossplayGuildChestExpander.Scripts.audit")
local command_router_module = require("CrossplayGuildChestExpander.Scripts.command_router")
local config_module = require("CrossplayGuildChestExpander.Scripts.config")
local conflict_detector_module = require("CrossplayGuildChestExpander.Scripts.conflict_detector")
local container_resolver_module = require("CrossplayGuildChestExpander.Scripts.container_resolver")
local guild_repository_module = require("CrossplayGuildChestExpander.Scripts.guild_repository")
local json_module = require("CrossplayGuildChestExpander.Scripts.json")
local ledger_module = require("CrossplayGuildChestExpander.Scripts.ledger")
local path_guard_module = require("CrossplayGuildChestExpander.Scripts.path_guard")
local platform_preflight_module = require("CrossplayGuildChestExpander.Scripts.platform_preflight")
local report_module = require("CrossplayGuildChestExpander.Scripts.report")
local revision_guard_module = require("CrossplayGuildChestExpander.Scripts.revision_guard")
local state_machine_module = require("CrossplayGuildChestExpander.Scripts.state_machine")
local ue4ss_adapter_module = require("CrossplayGuildChestExpander.Scripts.ue4ss_adapter")
local world_ready_module = require("CrossplayGuildChestExpander.Scripts.world_ready")

local approval_verify = approval_module.verify
local audit_capture = audit_module.capture
local audit_checksum = audit_module.checksum
local audit_to_table = audit_module.to_table
local command_execute = command_router_module.execute
local command_new = command_router_module.new
local config_parse = config_module.parse
local conflict_scan = conflict_detector_module.scan
local container_capture_snapshot = container_resolver_module.capture_snapshot
local container_resolve = container_resolver_module.resolve
local guild_list = guild_repository_module.list
local json_array = json_module.array
local json_decode = json_module.decode
local json_encode = json_module.encode
local ledger_verify = ledger_module.verify
local path_resolve = path_guard_module.resolve
local platform_check = platform_preflight_module.check
local report_build = report_module.build
local revision_binding_metadata = revision_guard_module.binding_metadata
local revision_check = revision_guard_module.check
local state_new = state_machine_module.new
local state_read = state_machine_module.state
local state_transition = state_machine_module.transition
local adapter_close = ue4ss_adapter_module.close
local adapter_inspect_descriptor = ue4ss_adapter_module.inspect_descriptor
local adapter_new = ue4ss_adapter_module.new
local world_close = world_ready_module.close
local world_epoch = world_ready_module.epoch
local world_id = world_ready_module.world_id
local world_assert_current = world_ready_module.assert_current
local world_start = world_ready_module.start
local world_status = world_ready_module.status

local cgce = {}

local dependency_order = {
    "package_root",
    "config_relative_path",
    "bindings_relative_directory",
    "report_relative_path",
    "ledger_relative_path",
    "mod_version",
    "filesystem_read",
    "persist_operational_report",
    "ue4ss_port",
    "read_live_revision",
    "read_platform_inputs",
    "read_conflict_inventory",
    "capture_container_snapshot",
    "schedule",
    "cancel",
}

local dependency_fields = {}
for _, field in ipairs(dependency_order) do
    dependency_fields[field] = true
end

local filesystem_order = {
    "capabilities",
    "canonicalize",
    "inspect_no_follow",
    "propose_temp_sibling",
    "read_all_no_follow",
}

local filesystem_fields = {}
for _, field in ipairs(filesystem_order) do
    filesystem_fields[field] = true
end

local receipt_order = {
    "path",
    "relative_path",
    "report_checksum",
    "audit_checksum",
    "byte_length",
    "durable",
    "read_back_verified",
}

local receipt_fields = {}
for _, field in ipairs(receipt_order) do
    receipt_fields[field] = true
end

local terminal_states = {
    AUDIT_COMPLETE = true,
    AWAITING_APPROVAL = true,
    BLOCKED = true,
    UNSUPPORTED = true,
}

local app_records = setmetatable({}, { __mode = "k" })
local active_app
local perform_shutdown

local function problem(code, field, detail)
    return { code = code, field = field, detail = detail }
end

local function fail(code, field, detail)
    error(problem(code, field, detail), 0)
end

local function is_plain_table(value)
    return type(value) == "table" and getmetatable(value) == nil
end

local function has_control(value)
    return type(value) ~= "string" or value:find("[%z\1-\31\127]") ~= nil
end

local function sorted_unknown(value, allowed)
    local names = {}
    local invalid = false
    for key in next, value do
        if type(key) ~= "string" then
            invalid = true
        elseif not allowed[key] then
            names[#names + 1] = key
        end
    end
    table.sort(names)
    if invalid then
        return false
    end
    return names[1]
end

local function safe_problem(value, fallback_code, fallback_field, fallback_detail)
    if type(value) == "table" then
        local code = rawget(value, "code")
        local field = rawget(value, "field")
        local detail = rawget(value, "detail")
        if type(code) == "string"
            and not has_control(code)
            and (field == nil or (type(field) == "string" and not has_control(field)))
            and type(detail) == "string"
            and not has_control(detail) then
            return problem(code, field, detail)
        end
    end
    return problem(fallback_code, fallback_field, fallback_detail)
end

local function detached(value)
    local ok, encoded = pcall(json_encode, value)
    if not ok then
        return nil
    end
    local decoded, copy = pcall(json_decode, encoded)
    if not decoded then
        return nil
    end
    return copy
end

local function capture_filesystem(value)
    if not is_plain_table(value) then
        fail(
            "CGCE-RUNTIME-DEPENDENCIES",
            "filesystem_read",
            "filesystem_read must be a strict plain read-only port"
        )
    end
    local unknown = sorted_unknown(value, filesystem_fields)
    if unknown == false then
        fail(
            "CGCE-RUNTIME-DEPENDENCIES",
            "filesystem_read",
            "filesystem_read keys must be strings"
        )
    end
    if unknown ~= nil then
        fail(
            "CGCE-RUNTIME-DEPENDENCIES",
            "filesystem_read." .. unknown,
            "unknown or write-capable filesystem dependency"
        )
    end
    local captured = {}
    for _, field in ipairs(filesystem_order) do
        local port = rawget(value, field)
        if type(port) ~= "function" then
            fail(
                "CGCE-RUNTIME-DEPENDENCIES",
                "filesystem_read." .. field,
                "required read-only filesystem dependency is unavailable"
            )
        end
        captured[field] = port
    end
    return captured
end

local function capture_dependencies(value)
    if not is_plain_table(value) then
        fail(
            "CGCE-RUNTIME-DEPENDENCIES",
            "dependencies",
            "runtime dependencies must be a strict plain table"
        )
    end
    local unknown = sorted_unknown(value, dependency_fields)
    if unknown == false then
        fail(
            "CGCE-RUNTIME-DEPENDENCIES",
            "dependencies",
            "runtime dependency keys must be strings"
        )
    end
    if unknown ~= nil then
        fail(
            "CGCE-RUNTIME-DEPENDENCIES",
            unknown,
            "unknown or write-capable runtime dependency"
        )
    end
    for _, field in ipairs(dependency_order) do
        if rawget(value, field) == nil then
            fail(
                "CGCE-RUNTIME-DEPENDENCIES",
                field,
                "required runtime dependency is unavailable"
            )
        end
    end

    local captured = {}
    for _, field in ipairs({
        "package_root",
        "config_relative_path",
        "bindings_relative_directory",
        "report_relative_path",
        "ledger_relative_path",
        "mod_version",
    }) do
        local item = rawget(value, field)
        if type(item) ~= "string" or item == "" or has_control(item) then
            fail(
                "CGCE-RUNTIME-DEPENDENCIES",
                field,
                "runtime path and version dependencies must be non-empty control-free strings"
            )
        end
        captured[field] = item
    end
    captured.filesystem_read = capture_filesystem(rawget(value, "filesystem_read"))
    for _, field in ipairs({
        "persist_operational_report",
        "read_live_revision",
        "read_platform_inputs",
        "read_conflict_inventory",
        "capture_container_snapshot",
        "schedule",
        "cancel",
    }) do
        local port = rawget(value, field)
        if type(port) ~= "function" then
            fail(
                "CGCE-RUNTIME-DEPENDENCIES",
                field,
                "runtime dependency must be a narrow function port"
            )
        end
        captured[field] = port
    end
    captured.adapter = adapter_new(rawget(value, "ue4ss_port"))
    return captured
end

local function add_error(record, value, code, field, detail)
    record.errors[#record.errors + 1] = safe_problem(value, code, field, detail)
end

local function copy_errors(value)
    local result = json_array()
    for index, item in ipairs(value or {}) do
        result[index] = safe_problem(
            item,
            "CGCE-RUNTIME-FAILURE",
            "runtime",
            "runtime operation failed"
        )
    end
    return result
end

local function transition(record, event, context)
    local target, err = state_transition(record.machine, event, context)
    if err ~= nil then
        add_error(
            record,
            err,
            "CGCE-RUNTIME-STATE",
            "state",
            "discovery state transition failed"
        )
        return nil
    end
    return target
end

local function result_snapshot(record)
    local state = record.epoch_invalidated and "BLOCKED" or state_read(record.machine)
    return {
        state = state,
        pending = state == "WAITING",
        terminal = terminal_states[state] == true,
        report_persisted = record.receipt ~= nil,
        errors = copy_errors(record.errors),
    }
end

local function lifecycle_error(detail)
    return problem("CGCE-RUNTIME-LIFECYCLE", "lifecycle", detail)
end

local function start_result(record)
    record.start_in_progress = false
    if record.shutdown_requested and perform_shutdown ~= nil then
        perform_shutdown(record.app)
    end
    if record.closed then
        return nil, lifecycle_error("runtime app shut down during startup")
    end
    return result_snapshot(record), nil
end

local function startup_interrupted(record, generation)
    return record.closed or not rawequal(record.generation, generation)
end

local function resolve_path(record, relative_path)
    local ok, resolved = pcall(
        path_resolve,
        record.dependencies.filesystem_read,
        record.dependencies.package_root,
        relative_path
    )
    if not ok then
        error(safe_problem(
            resolved,
            "CGCE-RUNTIME-PATH",
            "path",
            "safe bootstrap path resolution failed"
        ), 0)
    end
    return resolved
end

local function read_file(record, resolved, code, field, detail)
    local values = table.pack(pcall(
        record.dependencies.filesystem_read.read_all_no_follow,
        resolved.target
    ))
    if not values[1] or values.n ~= 2 or type(values[2]) ~= "string" then
        fail(code, field, detail)
    end
    return values[2]
end

local function manifest_relative_path(record, revision)
    return record.dependencies.bindings_relative_directory
        .. "\\"
        .. tostring(revision)
        .. ".json"
end

local function same_windows_path(left, right)
    return type(left) == "string"
        and type(right) == "string"
        and left:gsub("/", "\\"):lower() == right:gsub("/", "\\"):lower()
end

local function within_windows_path(root, candidate)
    if type(root) ~= "string" or type(candidate) ~= "string" then
        return false
    end
    local folded_root = root:gsub("/", "\\"):lower()
    local folded_candidate = candidate:gsub("/", "\\"):lower()
    if folded_candidate == folded_root then
        return true
    end
    local boundary = folded_root:sub(-1) == "\\"
        and folded_root
        or (folded_root .. "\\")
    return folded_candidate:sub(1, #boundary) == boundary
end

local function validate_bootstrap_path_roles(record)
    local report_relative = record.resolved_report.relative_path
        :gsub("/", "\\")
        :lower()
    local report_prefix = "artifacts\\"
    if report_relative:sub(1, #report_prefix) ~= report_prefix then
        fail(
            "CGCE-RUNTIME-PATH-ROLE",
            "report_relative_path",
            "operational reports must remain in the dedicated artifacts namespace"
        )
    end
    local canonical_artifacts = record.resolved_report.root .. "\\artifacts"
    if not within_windows_path(canonical_artifacts, record.resolved_report.parent) then
        fail(
            "CGCE-RUNTIME-PATH-ROLE",
            "report_relative_path",
            "operational report canonical paths escaped the dedicated artifacts namespace"
        )
    end

    for _, report_path in ipairs({
        record.resolved_report.target,
        record.resolved_report.temp_sibling,
    }) do
        if same_windows_path(report_path, record.resolved_config.target)
            or same_windows_path(report_path, record.resolved_ledger.target)
            or within_windows_path(record.resolved_bindings_probe.parent, report_path) then
            fail(
                "CGCE-RUNTIME-PATH-ROLE",
                "report_relative_path",
                "operational report paths must not alias read-only runtime inputs"
            )
        end
    end
    return true
end

local function load_manifest(record, revision)
    local resolved_ok, resolved = pcall(resolve_path, record, manifest_relative_path(record, revision))
    if not resolved_ok then
        return nil, "path"
    end
    if record.resolved_bindings_probe == nil
        or not same_windows_path(resolved.parent, record.resolved_bindings_probe.parent) then
        return nil, "path"
    end
    local values = table.pack(pcall(
        record.dependencies.filesystem_read.read_all_no_follow,
        resolved.target
    ))
    if not values[1] then
        return nil, "read"
    end
    if values.n == 3 and values[2] == nil and values[3] == "missing" then
        return nil
    end
    if values.n ~= 2 or type(values[2]) ~= "string" then
        return nil, "read"
    end
    return values[2]
end

local function block_preflight(record, value)
    add_error(
        record,
        value,
        "CGCE-RUNTIME-PREFLIGHT",
        "preflight",
        "discovery preflight failed"
    )
    transition(record, "preflight_blocked")
end

local function exact_object(value, allowed, field)
    if not is_plain_table(value) then
        fail("CGCE-RUNTIME-PORT", field, field .. " must be a strict plain object")
    end
    local unknown = sorted_unknown(value, allowed)
    if unknown == false then
        fail("CGCE-RUNTIME-PORT", field, field .. " keys must be strings")
    end
    if unknown ~= nil then
        fail("CGCE-RUNTIME-PORT", field .. "." .. unknown, "unknown read-port result field")
    end
end

local function read_platform(record)
    local values = table.pack(pcall(record.dependencies.read_platform_inputs))
    if not values[1] or values.n ~= 2 or values[2] == nil then
        fail(
            "CGCE-RUNTIME-PLATFORM",
            "platform_inputs",
            "platform diagnostic inputs are unavailable"
        )
    end
    exact_object(values[2], { args = true, option_settings = true }, "platform_inputs")
    if rawget(values[2], "args") == nil or rawget(values[2], "option_settings") == nil then
        fail(
            "CGCE-RUNTIME-PLATFORM",
            "platform_inputs",
            "platform diagnostic inputs are incomplete"
        )
    end
    local checked_ok, checked = pcall(
        platform_check,
        values[2].args,
        values[2].option_settings
    )
    if not checked_ok or type(checked) ~= "table" then
        fail(
            "CGCE-RUNTIME-PLATFORM",
            "platform_inputs",
            "platform diagnostic evaluation failed"
        )
    end
    return checked
end

local function audit_context(record)
    local adapter = record.dependencies.adapter
    local binding = record.binding_session
    local epoch = record.world_epoch
    local cfg = record.config
    return {
        world_id = world_id(epoch),
        game_revision = record.game_revision,
        deployment_profile = cfg.deployment_profile,
        target_slots = cfg.requested_target_slots,
        include_guild_ids = cfg.include_guild_ids,
        exclude_guild_ids = cfg.exclude_guild_ids,
        list_guilds = function()
            return guild_list({
                adapter = adapter,
                binding_session = binding,
                world_epoch = epoch,
            })
        end,
        resolve_guild_chest = function(guild_id, container_id)
            return container_resolve(
                adapter,
                binding,
                epoch,
                guild_id,
                container_id
            )
        end,
        snapshot_container = function(token)
            local values = table.pack(pcall(
                container_capture_snapshot,
                token,
                adapter,
                binding,
                epoch,
                record.dependencies.capture_container_snapshot
            ))
            if not values[1] or values.n ~= 2 or values[2] == nil then
                fail(
                    "CGCE-RUNTIME-SNAPSHOT",
                    "snapshot",
                    "runtime snapshot bridge failed"
                )
            end
            return values[2]
        end,
    }
end

local function read_conflicts(record)
    local values = table.pack(pcall(
        record.dependencies.read_conflict_inventory,
        record.dependencies.adapter,
        record.binding_session,
        record.world_epoch,
        record.config.requested_target_slots
    ))
    if not values[1] or values.n ~= 2 or values[2] == nil then
        fail(
            "CGCE-RUNTIME-CONFLICT",
            "conflict_inventory",
            "exact conflict inventory is unavailable"
        )
    end
    exact_object(values[2], {
        policy = true,
        mods = true,
        hooks = true,
        containers = true,
    }, "conflict_inventory")
    for _, field in ipairs({ "policy", "mods", "hooks", "containers" }) do
        if rawget(values[2], field) == nil then
            fail(
                "CGCE-RUNTIME-CONFLICT",
                "conflict_inventory." .. field,
                "exact conflict inventory is incomplete"
            )
        end
    end
    return conflict_scan(
        values[2].policy,
        values[2].mods,
        values[2].hooks,
        values[2].containers
    )
end

local function add_finding(findings, code, severity, field, detail, forced_noop)
    findings[#findings + 1] = {
        code = code,
        severity = severity,
        field = field,
        detail = detail,
        forced_noop = forced_noop == true,
    }
end

local function report_inputs(record, verification, approval_valid)
    local findings = json_array()
    local mode = record.config.mode

    for _, finding in ipairs(record.platform.findings or {}) do
        add_finding(
            findings,
            finding.code,
            mode == "apply" and "BLOCKING" or "WARNING",
            finding.field,
            finding.detail,
            false
        )
    end
    for _, finding in ipairs(record.conflict.findings) do
        add_finding(
            findings,
            finding.code,
            finding.severity,
            finding.field,
            finding.detail,
            finding.forced_noop
        )
    end

    local ledger_severity
    if verification.status == "MISSING" then
        ledger_severity = "INFO"
    elseif verification.status == "AUDIT_BLOCKED" then
        ledger_severity = "BLOCKING"
    else
        ledger_severity = mode == "apply" and "BLOCKING" or "WARNING"
    end
    for _, finding in ipairs(verification.findings or {}) do
        add_finding(
            findings,
            finding.code,
            ledger_severity,
            finding.field,
            finding.detail,
            false
        )
    end

    for _, field in ipairs({
        "require_operator_approval",
        "verify_on_startup",
        "write_migration_ledger",
        "fail_fast",
    }) do
        if record.config[field] ~= true then
            add_finding(
                findings,
                "CGCE-RUNTIME-SAFETY-INTENT-DISABLED",
                mode == "apply" and "BLOCKING" or "WARNING",
                "config." .. field,
                "a safety-intent flag is disabled but its check was not skipped",
                false
            )
        end
    end

    if mode == "apply" and record.conflict.coverage == "partial" then
        add_finding(
            findings,
            "CGCE-RUNTIME-CONFLICT-COVERAGE-PARTIAL",
            "BLOCKING",
            "conflict.coverage",
            "apply mode requires complete Gate A conflict coverage",
            false
        )
    end
    if mode == "apply" and not approval_valid then
        add_finding(
            findings,
            "CGCE-RUNTIME-APPROVAL-REQUIRED",
            "INFO",
            "approval",
            "fresh-audit operator approval is absent or invalid",
            false
        )
    end

    table.sort(findings, function(left, right)
        if left.code ~= right.code then
            return left.code < right.code
        end
        if left.field ~= right.field then
            return left.field < right.field
        end
        return left.detail < right.detail
    end)

    local blocking = false
    for _, finding in ipairs(findings) do
        blocking = blocking
            or finding.severity == "BLOCKING"
            or finding.severity == "CRITICAL"
    end
    local audit_value = audit_to_table(record.audit_handle)
    blocking = blocking or #audit_value.blocking_errors > 0 or record.conflict.blocking
    for _, guild in ipairs(audit_value.guilds) do
        blocking = blocking or guild.status == "blocked"
    end

    local predicted
    if blocking then
        predicted = "BLOCKED"
    elseif mode == "apply" and not approval_valid then
        predicted = "AWAITING_APPROVAL"
    else
        predicted = "AUDIT_COMPLETE"
    end
    return predicted, findings
end

local function project_platform_for_report(value)
    return {
        preflight_ok = value.preflight_ok,
        state = value.state,
        certification = value.certification,
        diagnostic_only = value.diagnostic_only,
        evidence = detached(value.evidence),
    }
end

local function validate_receipt(record, receipt, expected)
    exact_object(receipt, receipt_fields, "receipt")
    for _, field in ipairs(receipt_order) do
        if rawget(receipt, field) == nil then
            fail(
                "CGCE-RUNTIME-RECEIPT",
                "receipt." .. field,
                "operational report receipt is incomplete"
            )
        end
    end
    if receipt.path ~= record.resolved_report.target
        or receipt.relative_path ~= record.resolved_report.relative_path
        or receipt.report_checksum ~= expected.report_checksum
        or receipt.audit_checksum ~= expected.audit_checksum
        or receipt.byte_length ~= expected.byte_length
        or receipt.durable ~= true
        or receipt.read_back_verified ~= true then
        fail(
            "CGCE-RUNTIME-RECEIPT",
            "receipt",
            "operational report receipt does not prove exact durable read-back"
        )
    end
    return detached(receipt)
end

local function block_audit(record, value)
    add_error(
        record,
        value,
        "CGCE-RUNTIME-AUDIT",
        "audit",
        "discovery audit orchestration failed"
    )
    if state_read(record.machine) == "AUDIT" then
        transition(record, "audit_blocked")
    end
end

local function assert_active_epoch(record, generation)
    if record.closed or not rawequal(record.generation, generation) then
        fail(
            "CGCE-RUNTIME-EPOCH",
            "generation",
            "runtime generation changed during discovery audit"
        )
    end
    world_assert_current(
        record.world_epoch,
        record.dependencies.adapter,
        record.binding_session
    )
    if record.closed or not rawequal(record.generation, generation) then
        fail(
            "CGCE-RUNTIME-EPOCH",
            "generation",
            "runtime generation changed during discovery audit"
        )
    end
    return true
end

local function invalidate_runtime_epoch(record)
    if record.epoch_invalidated then
        return false
    end
    record.epoch_invalidated = true
    record.receipt = nil
    record.report = nil
    add_error(record, problem(
        "CGCE-RUNTIME-EPOCH",
        "world_epoch",
        "the completed discovery epoch is no longer current"
    ))
    return false
end

local function refresh_runtime_epoch(record)
    if record.epoch_invalidated then
        return false
    end
    if record.world_epoch == nil then
        return true
    end
    local ok = pcall(
        world_assert_current,
        record.world_epoch,
        record.dependencies.adapter,
        record.binding_session
    )
    if not ok then
        return invalidate_runtime_epoch(record)
    end
    return true
end

local function run_audit(record, generation)
    local conflict_ok, conflict_or_error = pcall(read_conflicts, record)
    if not conflict_ok then
        block_audit(record, conflict_or_error)
        return
    end
    assert_active_epoch(record, generation)
    record.conflict = conflict_or_error

    local verified = table.pack(pcall(
        ledger_verify,
        record.dependencies.filesystem_read,
        record.dependencies.package_root,
        record.dependencies.ledger_relative_path,
        audit_context(record)
    ))
    if not verified[1]
        or verified.n ~= 3
        or type(verified[2]) ~= "table"
        or verified[3] == nil then
        block_audit(record, verified[1] and nil or verified[2])
        return
    end
    assert_active_epoch(record, generation)
    local verification = verified[2]
    local fresh_handle = verified[3]
    record.ledger_verification = verification
    record.audit_handle = fresh_handle

    local approval_valid = false
    if record.config.mode == "apply" then
        approval_valid = approval_verify({
            world_id = world_id(record.world_epoch),
            game_revision = record.game_revision,
            audit_checksum = audit_checksum(fresh_handle),
            requested_target_slots = record.config.requested_target_slots,
            deployment_profile = record.config.deployment_profile,
        }, record.config.approval_token)
    end

    local inputs = table.pack(pcall(
        report_inputs,
        record,
        verification,
        approval_valid
    ))
    if not inputs[1] or inputs.n ~= 3 or inputs[2] == nil or inputs[3] == nil then
        block_audit(record, inputs[2])
        return
    end
    local predicted = inputs[2]
    local findings = inputs[3]

    local built_value = table.pack(pcall(report_build, {
        audit = fresh_handle,
        mode = record.config.mode,
        state = predicted,
        mod_version = record.dependencies.mod_version,
        binding_manifest_checksum = record.binding_manifest_checksum,
        platform_preflight = project_platform_for_report(record.platform),
        conflict_summary = {
            coverage = record.conflict.coverage,
            blocking = record.conflict.blocking,
            forced_noop = record.conflict.forced_noop,
        },
        mod_inventory = record.conflict.mod_inventory,
        findings = findings,
    }))
    if not built_value[1] or built_value.n ~= 2 or built_value[2] == nil then
        block_audit(record, built_value[2])
        return
    end
    local built = built_value[2]

    local expected_bytes = json_encode(built)
    local expected_receipt = {
        report_checksum = built.checksum,
        audit_checksum = built.audit_checksum,
        byte_length = #expected_bytes,
    }
    assert_active_epoch(record, generation)
    local persisted = table.pack(pcall(record.dependencies.persist_operational_report, built))
    if not persisted[1] or persisted.n ~= 2 or persisted[2] == nil then
        block_audit(record, problem(
            "CGCE-RUNTIME-REPORT-PERSIST",
            "report",
            "operational report persistence failed"
        ))
        return
    end
    assert_active_epoch(record, generation)
    local unchanged = table.pack(pcall(json_encode, built))
    if not unchanged[1] or unchanged.n ~= 2 or unchanged[2] ~= expected_bytes then
        block_audit(record, problem(
            "CGCE-RUNTIME-REPORT-MUTATED",
            "report",
            "operational report changed during persistence"
        ))
        return
    end
    local receipt_value = table.pack(pcall(
        validate_receipt,
        record,
        persisted[2],
        expected_receipt
    ))
    if not receipt_value[1] or receipt_value.n ~= 2 or receipt_value[2] == nil then
        block_audit(record, receipt_value[2])
        return
    end
    local read_back = table.pack(pcall(
        record.dependencies.filesystem_read.read_all_no_follow,
        record.resolved_report.target
    ))
    if not read_back[1]
        or read_back.n ~= 2
        or type(read_back[2]) ~= "string"
        or read_back[2] ~= expected_bytes then
        block_audit(record, problem(
            "CGCE-RUNTIME-REPORT-READBACK",
            "report",
            "operational report bytes were not independently read back exactly"
        ))
        return
    end
    assert_active_epoch(record, generation)
    record.receipt = receipt_value[2]
    record.report = built

    if predicted == "BLOCKED" then
        if record.conflict.blocking then
            transition(record, "audit_conflicts")
        else
            transition(record, "audit_blocked")
        end
    else
        local context = { mode = record.config.mode }
        if record.config.mode == "apply" then
            context.approval_present = approval_valid
        end
        transition(record, "audit_complete", context)
    end
end

local function complete_world(record, detector, generation)
    if record.closed
        or record.generation ~= generation
        or record.continuation_started then
        return
    end
    record.continuation_started = true
    local status_ok, status = pcall(world_status, detector)
    if not status_ok or type(status) ~= "table" then
        if state_read(record.machine) == "WAITING" then
            transition(record, "discovery_failure")
        else
            block_preflight(record)
        end
        return
    end
    if status.state ~= "READY" then
        for _, item in ipairs(status.errors or {}) do
            add_error(
                record,
                item,
                "CGCE-RUNTIME-WORLD",
                "world",
                "world readiness failed"
            )
        end
        if state_read(record.machine) == "WAITING" then
            local event = status.errors
                and status.errors[1]
                and status.errors[1].code == "CGCE-WORLD-TIMEOUT"
                and "world_ready_timeout"
                or "discovery_failure"
            transition(record, event)
        else
            transition(record, "preflight_blocked")
        end
        return
    end

    local epoch_ok, epoch = pcall(world_epoch, detector)
    if not epoch_ok or epoch == nil then
        if state_read(record.machine) == "WAITING" then
            transition(record, "discovery_failure")
        else
            transition(record, "preflight_blocked")
        end
        add_error(
            record,
            epoch_ok and nil or epoch,
            "CGCE-RUNTIME-WORLD",
            "world_epoch",
            "ready world did not provide a current epoch"
        )
        return
    end
    record.world_epoch = epoch
    if transition(record, "world_ready") == nil then
        return
    end
    run_audit(record, generation)
end

local function continue_world_safely(record, detector, generation)
    local ok, err = pcall(complete_world, record, detector, generation)
    if not ok and not record.closed and record.generation == generation then
        add_error(
            record,
            err,
            "CGCE-RUNTIME-WORLD",
            "world",
            "world readiness continuation failed"
        )
        local current = state_read(record.machine)
        if current == "WAITING" then
            transition(record, "discovery_failure")
        elseif current == "AUDIT" then
            transition(record, "audit_blocked")
        elseif current == "PREFLIGHT" then
            transition(record, "preflight_blocked")
        end
    end
end

local function command_status(record)
    if record.config == nil or record.game_revision == nil then
        error("runtime status is unavailable", 0)
    end
    return {
        revision = record.game_revision,
        mode = record.config.mode,
        target = record.config.requested_target_slots,
        state = record.epoch_invalidated and "BLOCKED" or state_read(record.machine),
    }
end

local function require_live_audit(record)
    if record.closed
        or record.binding_session == nil
        or record.world_epoch == nil
        or record.epoch_invalidated then
        error("live audit is unavailable", 0)
    end
    return audit_context(record)
end

local app_methods = {}

function app_methods:start()
    local record = app_records[self]
    if record == nil then
        return nil, lifecycle_error("runtime app handle is invalid")
    end
    if record.closed then
        return nil, lifecycle_error("runtime app is already shut down")
    end
    if record.started then
        return nil, lifecycle_error("runtime app can be started only once")
    end
    record.started = true
    record.start_in_progress = true
    local generation = record.generation
    if transition(record, "enable") == nil then
        return start_result(record)
    end

    local paths_ok, paths_error = pcall(function()
        record.resolved_bindings_probe = resolve_path(
            record,
            record.dependencies.bindings_relative_directory .. "\\.cgce-binding-probe"
        )
        if startup_interrupted(record, generation) then
            return
        end
        record.resolved_config = resolve_path(record, record.dependencies.config_relative_path)
        if startup_interrupted(record, generation) then
            return
        end
        record.resolved_report = resolve_path(record, record.dependencies.report_relative_path)
        if startup_interrupted(record, generation) then
            return
        end
        record.resolved_ledger = resolve_path(record, record.dependencies.ledger_relative_path)
        if startup_interrupted(record, generation) then
            return
        end
        validate_bootstrap_path_roles(record)
    end)
    if startup_interrupted(record, generation) then
        return start_result(record)
    end
    if not paths_ok then
        block_preflight(record, paths_error)
        return start_result(record)
    end

    local config_ok, config_or_error = pcall(function()
        local bytes = read_file(
            record,
            record.resolved_config,
            "CGCE-RUNTIME-CONFIG",
            "config",
            "configuration file could not be read safely"
        )
        if startup_interrupted(record, generation) then
            return nil
        end
        return config_parse(bytes)
    end)
    if startup_interrupted(record, generation) then
        return start_result(record)
    end
    if not config_ok then
        block_preflight(record, config_or_error)
        return start_result(record)
    end
    record.config = config_or_error

    local revision_values = table.pack(pcall(revision_check, {
        read_revision = function()
            local values = table.pack(record.dependencies.read_live_revision())
            if startup_interrupted(record, generation) then
                error(lifecycle_error("runtime shutdown interrupted live revision read"), 0)
            end
            return table.unpack(values, 1, values.n)
        end,
        load_manifest = function(revision)
            if startup_interrupted(record, generation) then
                error(lifecycle_error("runtime shutdown interrupted manifest lookup"), 0)
            end
            local values = table.pack(load_manifest(record, revision))
            if startup_interrupted(record, generation) then
                error(lifecycle_error("runtime shutdown interrupted manifest lookup"), 0)
            end
            return table.unpack(values, 1, values.n)
        end,
        inspect_descriptor = function(_, expected)
            if startup_interrupted(record, generation) then
                error(lifecycle_error("runtime shutdown interrupted reflection inspection"), 0)
            end
            local actual, status = adapter_inspect_descriptor(record.dependencies.adapter, expected)
            if startup_interrupted(record, generation) then
                error(lifecycle_error("runtime shutdown interrupted reflection inspection"), 0)
            end
            if status ~= "MATCHED" then
                return nil, "mismatch"
            end
            return actual
        end,
    }))
    if startup_interrupted(record, generation) then
        return start_result(record)
    end
    if not revision_values[1]
        or (revision_values.n ~= 2 and revision_values.n ~= 3)
        or type(revision_values[2]) ~= "table" then
        block_preflight(record, revision_values[1] and nil or revision_values[2])
        return start_result(record)
    end
    local revision_outcome = revision_values[2]
    local binding_session = revision_values[3]
    record.game_revision = revision_outcome.game_revision
    record.binding_manifest_checksum = revision_outcome.manifest_checksum
    if revision_outcome.status == "UNSUPPORTED" then
        for _, item in ipairs(revision_outcome.errors) do
            add_error(record, item, "CGCE-RUNTIME-REVISION", "revision", "revision is unsupported")
        end
        transition(record, "preflight_unsupported")
        return start_result(record)
    end
    if revision_outcome.status ~= "SUPPORTED" or binding_session == nil then
        for _, item in ipairs(revision_outcome.errors) do
            add_error(record, item, "CGCE-RUNTIME-REVISION", "revision", "revision validation failed")
        end
        transition(record, "preflight_blocked")
        return start_result(record)
    end
    record.binding_session = binding_session
    local metadata_ok, metadata = pcall(revision_binding_metadata, binding_session)
    if startup_interrupted(record, generation) then
        return start_result(record)
    end
    if not metadata_ok
        or metadata.game_revision ~= record.game_revision
        or metadata.manifest_checksum ~= record.binding_manifest_checksum then
        block_preflight(record, metadata_ok and nil or metadata)
        return start_result(record)
    end

    local platform_ok, platform_or_error = pcall(read_platform, record)
    if startup_interrupted(record, generation) then
        return start_result(record)
    end
    if not platform_ok then
        block_preflight(record, platform_or_error)
        return start_result(record)
    end
    record.platform = platform_or_error

    record.starting_world = true
    local detector_ok, detector_or_error = pcall(world_start, {
        adapter = record.dependencies.adapter,
        binding_session = binding_session,
        schedule = record.dependencies.schedule,
        cancel = record.dependencies.cancel,
        on_terminal = function(detector)
            if record.starting_world then
                record.terminal_signal = detector
                return
            end
            continue_world_safely(record, detector, generation)
        end,
    })
    record.starting_world = false
    if detector_ok then
        record.detector = detector_or_error
    end
    if startup_interrupted(record, generation) then
        return start_result(record)
    end
    if not detector_ok then
        block_preflight(record, detector_or_error)
        return start_result(record)
    end
    local status_ok, status = pcall(world_status, detector_or_error)
    if startup_interrupted(record, generation) then
        return start_result(record)
    end
    if not status_ok or type(status) ~= "table" then
        block_preflight(record, status_ok and nil or status)
        return start_result(record)
    end
    if status.state == "PENDING" then
        transition(record, "world_waiting")
        if record.terminal_signal ~= nil then
            continue_world_safely(record, record.terminal_signal, generation)
        end
    else
        continue_world_safely(record, detector_or_error, generation)
    end
    return start_result(record)
end

function app_methods:handle_command(line)
    local record = app_records[self]
    if record == nil then
        return nil, lifecycle_error("runtime app handle is invalid")
    end
    if record.closed then
        return nil, lifecycle_error("runtime app is already shut down")
    end
    if not record.started then
        return nil, lifecycle_error("runtime app has not started")
    end
    local current_before = refresh_runtime_epoch(record)
    local response, err = command_execute(record.router, line)
    local current_after = refresh_runtime_epoch(record)
    if response ~= nil and current_before and not current_after then
        return nil, problem(
            "CGCE-RUNTIME-EPOCH",
            "world_epoch",
            "world epoch changed during the read-only command"
        )
    end
    if err ~= nil and err.code == "MUTATION_BUILD_UNAVAILABLE" then
        return nil, err
    end
    return response, err
end

function app_methods:shutdown()
    local record = app_records[self]
    if record == nil then
        return false, json_array({ lifecycle_error("runtime app handle is invalid") })
    end
    if record.shutdown_result ~= nil then
        return record.shutdown_result.ok, copy_errors(record.shutdown_result.errors)
    end
    if record.shutdown_in_progress then
        return false, json_array({
            lifecycle_error("runtime shutdown is already in progress"),
        })
    end
    if record.start_in_progress then
        record.shutdown_requested = true
        record.closed = true
        record.generation = function() end
        return false, json_array({
            lifecycle_error("runtime shutdown is deferred until startup unwinds"),
        })
    end
    record.shutdown_in_progress = true
    record.closed = true
    record.generation = function() end
    local errors = json_array()

    if record.detector ~= nil then
        local values = table.pack(pcall(world_close, record.detector))
        if not values[1] or values[2] ~= true then
            local supplied = values[1] and values[3] or nil
            if type(supplied) == "table" and #supplied > 0 then
                for _, item in ipairs(supplied) do
                    errors[#errors + 1] = safe_problem(
                        item,
                        "CGCE-RUNTIME-CLEANUP",
                        "world_ready",
                        "world readiness cleanup failed"
                    )
                end
            else
                errors[#errors + 1] = safe_problem(
                    values[1] and nil or values[2],
                    "CGCE-RUNTIME-CLEANUP",
                    "world_ready",
                    "world readiness cleanup failed"
                )
            end
        end
    end

    local adapter_values = table.pack(pcall(adapter_close, record.dependencies.adapter))
    if not adapter_values[1] or adapter_values[2] ~= true then
        local supplied = adapter_values[1] and adapter_values[3] or nil
        if type(supplied) == "table" and #supplied > 0 then
            for _, item in ipairs(supplied) do
                local normalized = {
                    code = item.code,
                    field = item.field or item.path,
                    detail = item.detail,
                }
                errors[#errors + 1] = safe_problem(
                    normalized,
                    "CGCE-RUNTIME-CLEANUP",
                    "adapter",
                    "read-only adapter cleanup failed"
                )
            end
        else
            errors[#errors + 1] = safe_problem(
                adapter_values[1] and nil or adapter_values[2],
                "CGCE-RUNTIME-CLEANUP",
                "adapter",
                "read-only adapter cleanup failed"
            )
        end
    end
    record.shutdown_result = {
        ok = #errors == 0,
        errors = copy_errors(errors),
    }
    record.shutdown_in_progress = false
    if record.shutdown_result.ok and rawequal(active_app, self) then
        active_app = nil
    end
    return record.shutdown_result.ok, copy_errors(record.shutdown_result.errors)
end

perform_shutdown = function(app)
    return app_methods.shutdown(app)
end

function cgce.start(app)
    return app_methods.start(app)
end

function cgce.handle_command(app, line)
    return app_methods.handle_command(app, line)
end

function cgce.shutdown(app)
    return app_methods.shutdown(app)
end

function cgce.status(app)
    local record = app_records[app]
    if record == nil then
        return nil, lifecycle_error("runtime app handle is invalid")
    end
    if record.closed then
        return nil, lifecycle_error("runtime app is already shut down")
    end
    if not record.started then
        return nil, lifecycle_error("runtime app has not started")
    end
    refresh_runtime_epoch(record)
    return result_snapshot(record), nil
end

function cgce.new(dependencies)
    if active_app ~= nil then
        fail(
            "CGCE-RUNTIME-LIFECYCLE",
            "lifecycle",
            "another runtime app is active; successful cleanup is required before reload"
        )
    end
    local captured = capture_dependencies(dependencies)
    local machine = state_new({ mutation_capability = false })
    local app = setmetatable({}, {
        __index = app_methods,
        __newindex = function()
            error("runtime app surface is immutable", 2)
        end,
        __metatable = false,
    })
    local record = {
        app = app,
        dependencies = captured,
        machine = machine,
        generation = function() end,
        started = false,
        start_in_progress = false,
        shutdown_requested = false,
        closed = false,
        continuation_started = false,
        shutdown_in_progress = false,
        errors = json_array(),
    }
    app_records[app] = record
    record.router = command_new({
        status = function()
            return command_status(record)
        end,
        audit = function()
            local handle = audit_capture(require_live_audit(record))
            return audit_to_table(handle)
        end,
        guilds = function()
            local context = require_live_audit(record)
            return context.list_guilds()
        end,
        verify = function()
            local generation = record.generation
            assert_active_epoch(record, generation)
            local verified = table.pack(pcall(
                ledger_verify,
                record.dependencies.filesystem_read,
                record.dependencies.package_root,
                record.dependencies.ledger_relative_path,
                require_live_audit(record)
            ))
            if not verified[1]
                or verified.n ~= 3
                or type(verified[2]) ~= "table"
                or verified[3] == nil then
                fail(
                    "CGCE-RUNTIME-LEDGER",
                    "ledger",
                    "fresh ledger verification failed"
                )
            end
            assert_active_epoch(record, generation)
            return verified[2]
        end,
        report_path = function()
            if record.receipt == nil then
                error("operational report is unavailable", 0)
            end
            return record.receipt.path
        end,
    })
    active_app = app
    return app
end

return cgce
