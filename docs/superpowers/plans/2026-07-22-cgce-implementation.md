# Crossplay Guild Chest Expander Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Windows Palworld Dedicated Server에서만 실행되며 Steam Windows·PS5·macOS 순정 클라이언트가 공유하는 길드 상자를 안전하게 확장하는 CGCE 서버 모드를 구현한다.

**Architecture:** 게임 비의존 안전 코어는 순수 Lua 모듈로 만들고 synthetic adapter를 통해 전부 단위 검증한다. UE4SS/Palworld 의존 코드는 포트 어댑터 뒤에 격리하며, 정확한 revision manifest와 실제 서버 증거가 없으면 read-only discovery만 실행하고 mutation hook을 등록하지 않는다. 운영 패키지는 audit-first, approval-token, expand-only, fail-closed 규칙을 정적 검증기로 강제한다.

**Tech Stack:** Lua 5.4, UE4SS Lua API, JSON/JSON Lines, pure-Lua SHA-256, shell 기반 정적 패키지 검증, Windows 64-bit Palworld Dedicated Server 실기기 통합 테스트.

## Global Constraints

- 서버 플랫폼은 Windows 64-bit Dedicated Server만 지원한다.
- 필수 순정 클라이언트는 `SteamWindows`, `PS5`, `Mac`이며 Xbox는 선택 지원이다.
- 클라이언트 파일, custom RPC, custom UI, PAK, DLL을 배포하지 않는다.
- 기본 모드는 `audit`; 유효한 승인 토큰 없이는 `apply` mutation이 0건이어야 한다.
- 슬롯 정책은 expand-only, append-only, idempotent이며 기존 ID·GUID·index·수량·instance metadata를 보존한다.
- 미지원 revision, 타입 불일치, 중복 container ID, owner mismatch, report/ledger 기록 실패는 fail-closed다.
- `requested_target_slots`는 운영 모드에서 세 필수 클라이언트가 인증한 값에 포함되어야 한다.
- UObject mutation은 게임 스레드에서만 수행한다.
- PRD §32 Gate A 산출물 1–16을 확보하기 전 실제 Palworld mutation adapter를 활성화하지 않는다.
- Gate B 산출물 17–20과 Steam Windows·PS5·macOS 실기기 인증 전 release-compatible 상태를 만들지 않는다.

---

## File Map

```text
CrossplayGuildChestExpander/
├── Info.json
├── README.md
├── CHANGELOG.md
├── LICENSE
├── config/config.default.json
└── Scripts/
    ├── main.lua
    ├── cgce.lua
    ├── constants.lua
    ├── json.lua
    ├── sha256.lua
    ├── config.lua
    ├── binding_manifest.lua
    ├── state_machine.lua
    ├── fingerprint.lua
    ├── snapshot.lua
    ├── validator.lua
    ├── migration.lua
    ├── approval.lua
    ├── ledger.lua
    ├── report.lua
    ├── logger.lua
    ├── command_router.lua
    ├── scheduler.lua
    ├── revision_guard.lua
    ├── world_ready.lua
    ├── guild_repository.lua
    ├── container_resolver.lua
    ├── resizer.lua
    ├── replication.lua
    ├── new_guild_hook.lua
    ├── platform_preflight.lua
    ├── ue4ss_adapter.lua
    └── bindings/README.md
tests/
├── run.lua
├── support/assertions.lua
├── support/fake_adapter.lua
├── unit/*.lua
└── integration/*.lua
scripts/
├── run-tests.sh
├── verify-package.sh
└── build-release.sh
docs/
├── discovery-runbook.md
├── certification-runbook.md
├── release-report.schema.json
└── requirements-traceability.md
```

### Task 1: Repository bootstrap and executable Lua test harness

**Files:**
- Create: `.gitignore`
- Create: `tests/run.lua`
- Create: `tests/support/assertions.lua`
- Create: `tests/unit/test_harness_spec.lua`
- Create: `scripts/run-tests.sh`
- Create: `CrossplayGuildChestExpander/LICENSE`

**Interfaces:**
- Produces: `describe(name, fn)`, `it(name, fn)`, `assertions.equal(expected, actual)`, `assertions.deep_equal(expected, actual)`, `assertions.raises(pattern, fn)`.

- [ ] **Step 1: Write the failing harness self-test**

```lua
describe("test harness", function()
    it("supports equality and expected errors", function()
        local a = require("tests.support.assertions")
        a.equal(2, 1 + 1)
        a.raises("boom", function() error("boom") end)
    end)
end)
```

- [ ] **Step 2: Run the test and verify RED**

Run: `./scripts/run-tests.sh tests/unit/test_harness_spec.lua`

Expected: non-zero with missing runner or assertion module.

- [ ] **Step 3: Implement the minimal runner**

```lua
local suites, failures = {}, 0
function describe(name, fn) suites[#suites + 1] = name; fn(); suites[#suites] = nil end
function it(name, fn)
    local ok, err = xpcall(fn, debug.traceback)
    if ok then io.write("PASS ", table.concat(suites, " > "), " > ", name, "\n")
    else failures = failures + 1; io.stderr:write("FAIL ", name, "\n", err, "\n") end
end
-- load requested files, then os.exit(failures == 0 and 0 or 1)
```

- [ ] **Step 4: Verify GREEN**

Run: `./scripts/run-tests.sh`

Expected: all harness tests pass and process exits 0.

### Task 2: Strict JSON and SHA-256 primitives

**Files:**
- Create: `CrossplayGuildChestExpander/Scripts/json.lua`
- Create: `CrossplayGuildChestExpander/Scripts/sha256.lua`
- Create: `tests/unit/json_spec.lua`
- Create: `tests/unit/sha256_spec.lua`

**Interfaces:**
- Produces: `json.decode(text) -> value`, `json.encode(value) -> canonical_json`, `sha256.hex(text) -> 64-char lowercase hex`.

- [ ] **Step 1: Write failing JSON tests** for objects, arrays, escapes, Unicode escapes, numbers, booleans/null, duplicate keys, trailing input, non-finite numbers, deterministic key ordering, and cyclic tables.

```lua
a.deep_equal({a = 1, b = {true, false}}, json.decode('{"b":[true,false],"a":1}'))
a.equal('{"a":1,"b":[true,false]}', json.encode({b = {true, false}, a = 1}))
a.raises("duplicate key", function() json.decode('{"a":1,"a":2}') end)
```

- [ ] **Step 2: Verify JSON RED** with `./scripts/run-tests.sh tests/unit/json_spec.lua`.

- [ ] **Step 3: Implement a strict recursive-descent JSON codec** with sorted object keys and an explicit `json.null` sentinel.

- [ ] **Step 4: Verify JSON GREEN** and run the full suite.

- [ ] **Step 5: Write failing SHA-256 vector tests**.

```lua
a.equal("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", sha256.hex(""))
a.equal("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", sha256.hex("abc"))
```

- [ ] **Step 6: Verify SHA RED**, implement Lua 5.4 bitwise SHA-256, then verify GREEN and full suite.

### Task 3: Configuration and revision binding validation

**Files:**
- Create: `CrossplayGuildChestExpander/config/config.default.json`
- Create: `CrossplayGuildChestExpander/Scripts/constants.lua`
- Create: `CrossplayGuildChestExpander/Scripts/config.lua`
- Create: `CrossplayGuildChestExpander/Scripts/binding_manifest.lua`
- Create: `CrossplayGuildChestExpander/Scripts/bindings/README.md`
- Create: `tests/unit/config_spec.lua`
- Create: `tests/unit/binding_manifest_spec.lua`

**Interfaces:**
- Produces: `config.parse(text) -> validated_config`; `binding_manifest.parse(text) -> manifest`; `binding_manifest.verify_types(manifest, adapter) -> ok, errors`.

- [ ] **Step 1: Write failing config contract tests** covering the exact default, unknown keys, profile lock, required clients, include/exclude overlap, minimum rescan 30, expand-only lock, certification allow-list, and apply approval presence.

```lua
local cfg = config.parse(default_text)
a.equal("audit", cfg.mode)
a.deep_equal({"SteamWindows", "PS5", "Mac"}, cfg.required_clients)
a.raises("unknown config key", function() config.parse('{"config_version":"1.1","oops":1}') end)
```

- [ ] **Step 2: Verify RED**, implement schema validation without coercion, verify GREEN.

- [ ] **Step 3: Write failing manifest tests** for exact revision, required symbol descriptors, allowed keys, checksum, type signatures, and empty discovery-only manifests.

- [ ] **Step 4: Verify RED**, implement parser/runtime type checks, verify GREEN.

### Task 4: Snapshots, fingerprints, and invariants

**Files:**
- Create: `CrossplayGuildChestExpander/Scripts/fingerprint.lua`
- Create: `CrossplayGuildChestExpander/Scripts/snapshot.lua`
- Create: `CrossplayGuildChestExpander/Scripts/validator.lua`
- Create: `tests/support/fake_adapter.lua`
- Create: `tests/unit/snapshot_spec.lua`
- Create: `tests/unit/validator_spec.lua`

**Interfaces:**
- Consumes adapter methods: `container_id`, `owner_guild_id`, `slots`, `slot_item`.
- Produces: `snapshot.capture(adapter, container) -> snapshot`; `validator.compare(before, after, target) -> ok, violations`.

- [ ] **Step 1: Write failing snapshot tests** proving stable fingerprint independent of Lua table iteration while preserving slot index, static ID, dynamic GUID, quantity, durability, and instance metadata hash.

- [ ] **Step 2: Verify RED**, implement canonical per-slot representation and SHA-256 fingerprint, verify GREEN.

- [ ] **Step 3: Write failing invariant tests** for every PRD §16.1 rule, including empty appended slots and unchanged containers above target.

```lua
local ok, errors = validator.compare(before, after, 358)
a.equal(false, ok)
a.contains(errors, "CGCE-VAL-004:item_fingerprint_changed")
```

- [ ] **Step 4: Verify RED**, implement structured violations, verify GREEN and full suite.

### Task 5: State machine and adapter-driven migration engine

**Files:**
- Create: `CrossplayGuildChestExpander/Scripts/state_machine.lua`
- Create: `CrossplayGuildChestExpander/Scripts/migration.lua`
- Create: `CrossplayGuildChestExpander/Scripts/resizer.lua`
- Create: `tests/unit/state_machine_spec.lua`
- Create: `tests/integration/migration_spec.lua`

**Interfaces:**
- Produces: `state_machine.new()`, `machine:transition(event, context)`; `migration.audit(context) -> report`; `migration.apply(context) -> result`.
- Adapter mutation interface: `execute_in_game_thread(fn)`, `resize_container(container, target)`, `mark_dirty(container)`, `replicate(container)`, `is_container_in_use(container)`.

- [ ] **Step 1: Write failing state-transition table tests** for every PRD §12 path and forbidden transitions from `BLOCKED`, `UNSUPPORTED`, `FAILED`.
- [ ] **Step 2: Verify RED**, implement explicit transition table, verify GREEN.
- [ ] **Step 3: Write failing synthetic migration tests** for 54→358 empty/occupied, 358/400 no-op, owner mismatch, duplicate IDs, include/exclude, append exception, fingerprint mismatch, idempotent second run, in-use refusal, and fail-fast.
- [ ] **Step 4: Verify RED**, implement audit and apply through the injected adapter only, verify GREEN.
- [ ] **Step 5: Add a production guard test** proving `apply` never calls adapter mutation unless revision, bindings, certified target, report persistence, and approval all pass.

### Task 6: Approval, reports, ledger, and structured logging

**Files:**
- Create: `CrossplayGuildChestExpander/Scripts/approval.lua`
- Create: `CrossplayGuildChestExpander/Scripts/report.lua`
- Create: `CrossplayGuildChestExpander/Scripts/ledger.lua`
- Create: `CrossplayGuildChestExpander/Scripts/logger.lua`
- Create: `docs/release-report.schema.json`
- Create: `tests/unit/approval_spec.lua`
- Create: `tests/unit/report_spec.lua`
- Create: `tests/unit/ledger_spec.lua`
- Create: `tests/unit/logger_spec.lua`

**Interfaces:**
- Produces: `approval.token(fields)`, `report.build(context)`, `report.persist(path, value)`, `ledger.load/save/verify`, `logger.text/jsonl`.

- [ ] **Step 1: Write failing approval tests** using unambiguous length-prefixed UTF-8 fields for world ID, revision, report checksum, target, and profile; prove any field change invalidates the token.
- [ ] **Step 2: Verify RED**, implement SHA-256 approval token, verify GREEN.
- [ ] **Step 3: Write failing report/ledger tests** for deterministic JSON, atomic temp-write/rename adapter, save-as-source-of-truth drift, per-guild results, and persistence failure blocking apply.
- [ ] **Step 4: Verify RED**, implement persistence ports and verification, verify GREEN.
- [ ] **Step 5: Write failing log tests** for control-character escaping, credential field redaction, event size bound, and no per-slot INFO logs; implement and verify.

### Task 7: Commands, bounded scheduling, and connectivity preflight

**Files:**
- Create: `CrossplayGuildChestExpander/Scripts/command_router.lua`
- Create: `CrossplayGuildChestExpander/Scripts/scheduler.lua`
- Create: `CrossplayGuildChestExpander/Scripts/platform_preflight.lua`
- Create: `tests/unit/command_router_spec.lua`
- Create: `tests/unit/scheduler_spec.lua`
- Create: `tests/unit/platform_preflight_spec.lua`

**Interfaces:**
- Produces exact commands: `cgce status|audit|apply|guilds|verify|export-report`; `scheduler.retry(options, probe)`; `platform_preflight.check(args, settings)`.

- [ ] **Step 1: Write failing command tests** proving unknown commands and arguments do not mutate, apply delegates only after guard success, and output contains revision/mode/target/state.
- [ ] **Step 2: Verify RED**, implement command routing, verify GREEN.
- [ ] **Step 3: Write failing scheduler tests** proving bounded world-ready retries, 30-second minimum fallback, 60-second default, completed-guild cache, and no infinite polling.
- [ ] **Step 4: Verify RED**, implement scheduler as injected clock callbacks, verify GREEN.
- [ ] **Step 5: Write failing connectivity tests** for `-publiclobby`, `CrossplayPlatforms` containing PS5 and Mac, public port match, and diagnostic-only behavior; implement and verify.

### Task 8: UE4SS read-only runtime adapter and Discovery Build

**Files:**
- Create: `CrossplayGuildChestExpander/Scripts/ue4ss_adapter.lua`
- Create: `CrossplayGuildChestExpander/Scripts/revision_guard.lua`
- Create: `CrossplayGuildChestExpander/Scripts/world_ready.lua`
- Create: `CrossplayGuildChestExpander/Scripts/guild_repository.lua`
- Create: `CrossplayGuildChestExpander/Scripts/container_resolver.lua`
- Create: `tests/integration/discovery_adapter_spec.lua`
- Create: `docs/discovery-runbook.md`

**Interfaces:**
- Produces: `ue4ss_adapter.capabilities()`, `read_revision()`, `find_all_of(class_name)`, `resolve_property(object, descriptor)`, `validate_function(descriptor)`, `register_hook(path, pre, post)`, `execute_in_game_thread(fn)`.

- [ ] **Step 1: Write failing contract tests** using a fake UE4SS global surface and proving missing APIs/symbols yield `UNSUPPORTED`/`BLOCKED`, never fuzzy matching.
- [ ] **Step 2: Verify RED**, implement exact-name reflection wrappers and read-only capability detection, verify GREEN.
- [ ] **Step 3: Write failing guild traversal tests** proving `guild_id → container_id → owner_guild_id` and duplicate/container-type rejection.
- [ ] **Step 4: Verify RED**, implement repositories/resolver, verify GREEN.
- [ ] **Step 5: Implement discovery report fields** for PRD §32 items 1–16 while leaving production `resize_container` unavailable until an exact manifest passes.

### Task 9: Runtime orchestration, replication, and new-guild lifecycle

**Files:**
- Create: `CrossplayGuildChestExpander/Scripts/replication.lua`
- Create: `CrossplayGuildChestExpander/Scripts/new_guild_hook.lua`
- Create: `CrossplayGuildChestExpander/Scripts/cgce.lua`
- Create: `CrossplayGuildChestExpander/Scripts/main.lua`
- Create: `tests/integration/runtime_spec.lua`
- Create: `tests/integration/new_guild_spec.lua`

**Interfaces:**
- Produces: `cgce.new(dependencies)`, `app:start()`, `app:handle_command(line)`, `new_guild_hook.install(app, manifest, adapter)`.

- [ ] **Step 1: Write failing startup tests** for unsupported revision, invalid config, missing report path, audit default, world-ready retry, and no mutation hook registration before all gates pass.
- [ ] **Step 2: Verify RED**, implement dependency-injected orchestration, verify GREEN.
- [ ] **Step 3: Write failing new-guild tests** proving exact hook, limited initialization retries, empty/non-empty invariant handling, same migration engine reuse, and 60-second cached fallback.
- [ ] **Step 4: Verify RED**, implement lifecycle modules and existing dirty/replication functions only, verify GREEN.

### Task 10: Official package, release verifier, and operator documentation

**Files:**
- Create: `CrossplayGuildChestExpander/Info.json`
- Create: `CrossplayGuildChestExpander/README.md`
- Create: `CrossplayGuildChestExpander/CHANGELOG.md`
- Create: `scripts/verify-package.sh`
- Create: `scripts/build-release.sh`
- Create: `tests/integration/package_spec.lua`
- Create: `docs/certification-runbook.md`
- Create: `docs/requirements-traceability.md`

**Interfaces:**
- Produces: deterministic release archive only when exact `MinRevision`, one exact binding manifest, Tier-0 certification report, and server-only file allow-list pass.

- [ ] **Step 1: Write a failing package test** asserting one Lua `InstallRule` with `IsServer=true`, non-zero `MinRevision`, UE4SS dependency, no client assets, and only allow-listed files.
- [ ] **Step 2: Verify RED**, create package metadata and static verifier, verify GREEN for development package and prove release build remains blocked without certification artifacts.
- [ ] **Step 3: Document exact backup, audit, approval, apply, verify, update, removal, rollback, discovery, Steam/PS5/macOS certification, performance, and six-hour soak procedures.
- [ ] **Step 4: Populate requirement traceability** mapping every `FR-*`, `AT-*`, DoD item, and §32 artifact to code/test/manual evidence.

### Task 11: Gate A real Windows server discovery

**Files:**
- Create after capture: `CrossplayGuildChestExpander/Scripts/bindings/<revision>.json`
- Create after capture: `artifacts/discovery/<revision>/audit-report.json`
- Modify: `docs/requirements-traceability.md`

**Interfaces:**
- Consumes a user-provided Windows Palworld Dedicated Server with UE4SS and a disposable backed-up test world.
- Produces PRD §32 evidence items 1–16 and an exact checksum-bound manifest.

- [ ] **Step 1:** Run the Discovery Build in audit-only mode on the exact target revision.
- [ ] **Step 2:** Inspect runtime types/functions and record exact paths/signatures; reject ambiguous candidates.
- [ ] **Step 3:** Verify three-way guild/container ownership on representative guilds and prove general containers are excluded.
- [ ] **Step 4:** Add the exact manifest, run contract tests, and retain mutation disabled until independent review of the report.

### Task 12: Gate B isolated mutation and Tier-0 certification

**Files:**
- Create after test: `artifacts/certification/<revision>/release-report.json`
- Modify: `CrossplayGuildChestExpander/config/config.default.json`
- Modify: `CrossplayGuildChestExpander/Info.json`
- Modify: `docs/requirements-traceability.md`

**Interfaces:**
- Consumes disposable backed-up Windows server worlds plus Steam Windows, PS5, and macOS vanilla clients.
- Produces certified target slots, after snapshots, removal evidence, performance baselines, and final release eligibility.

- [ ] **Step 1:** Run 54→120 on a disposable world, save/reload, verify all invariants and idempotency.
- [ ] **Step 2:** Repeat `120→256→358`; add a value to `certified_target_slots` only after all three Tier-0 clients pass.
- [ ] **Step 3:** Run concurrent access, restart/reconnect, removal, 32-player load model, and six-hour soak protocols.
- [ ] **Step 4:** Generate the signed/checksummed release report, inject exact `MinRevision`, build the server-only archive, and run the full completion audit.

## Plan Self-Review

- Every P0/P1 functional requirement maps to Tasks 3–10.
- Every synthetic/unit test category maps to Tasks 1–9.
- Actual runtime, save/reload, removal, performance, PS5, and macOS claims remain explicitly unproven until Tasks 11–12 produce primary evidence.
- The apparent §32 circularity is resolved operationally as Gate A (items 1–16, read-only discovery) followed by Gate B (items 17–20, disposable test-world mutation/certification); production mutation remains disabled between them.
- No placeholder game revision or guessed Palworld symbol is accepted as a release manifest.

