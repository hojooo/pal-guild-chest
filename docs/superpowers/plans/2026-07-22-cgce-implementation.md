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
├── thumbnail.png
├── README.md
├── CHANGELOG.md
├── config/config.default.json
└── Scripts/
    ├── main.lua
    ├── cgce.lua
    ├── constants.lua
    ├── json.lua
    ├── sha256.lua
    ├── config.lua
    ├── binding_manifest.lua
    ├── certification.lua
    ├── state_machine.lua
    ├── fingerprint.lua
    ├── snapshot.lua
    ├── validator.lua
    ├── migration.lua
    ├── gate_a.lua
    ├── mutation_guard.lua
    ├── fatal_safety.lua
    ├── persisted_verifier.lua
    ├── approval.lua
    ├── ledger.lua
    ├── report.lua
    ├── logger.lua
    ├── path_guard.lua
    ├── conflict_detector.lua
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
- Vendor: `third_party/lua-5.4.8/**` from the official Lua 5.4.8 source archive
- Create: `third_party/README.md`
- Create: `tests/run.lua`
- Create: `tests/support/assertions.lua`
- Create: `tests/unit/test_harness_spec.lua`
- Create: `scripts/run-tests.sh`

**Interfaces:**
- Produces: `describe(name, fn)`, `it(name, fn)`, `assertions.equal(expected, actual)`, `assertions.deep_equal(expected, actual)`, `assertions.raises(pattern, fn)`.

- [ ] **Step 0: Vendor and build the test-only Lua runtime**

Download `https://www.lua.org/ftp/lua-5.4.8.tar.gz`, verify SHA-256 `4f18ddae154e793e46eeab727c59ef1c0c0c2b744e7b94219710d76f530629ae`, extract it under `third_party/`, and run `make -C third_party/lua-5.4.8 all`. Record that this runtime is test tooling and is excluded from the CGCE release package. The CGCE project license is a separate owner decision and is not invented during bootstrap.

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
- Create: `CrossplayGuildChestExpander/Scripts/certification.lua`
- Create: `CrossplayGuildChestExpander/Scripts/bindings/README.md`
- Create: `tests/unit/config_spec.lua`
- Create: `tests/unit/binding_manifest_spec.lua`
- Create: `tests/unit/certification_spec.lua`

**Interfaces:**
- Produces: `config.parse(text) -> validated_config`; `binding_manifest.parse(text) -> manifest`; `binding_manifest.verify_types(manifest, adapter) -> ok, errors`; `certification.verify(release_artifact, pinned_checksum, revision, profile) -> certified_slots`.

**Exact contracts:**

- `constants.lua` defines versions `config=1.1`, `manifest=1.0`, `certification=1.0`; profile `windows-dedicated-ps5-macos-required`; required clients `SteamWindows,PS5,Mac`; optional client `Xbox`; candidates `54,120,256,358`; release certification checksum is absent in Discovery Build.
- Errors are tables `{code=<stable code>, field=<field or nil>, detail=<non-secret detail>}`. Config codes use `CGCE-CFG-*`, manifest codes `CGCE-MAN-*`, certification codes `CGCE-CERT-*`; approval tokens are never copied into diagnostics.
- Config allows exactly the 21 PRD keys from `config_version` through `structured_log`. Values are never coerced. Required clients equal the canonical ordered triple; optional clients are a unique subset of `{"Xbox"}`; certified targets are unique ascending candidates; guild IDs are opaque non-empty UTF-8 strings; include/exclude are unique and disjoint; fallback is an integer ≥30; `expand_only=true`. `approval_token` is type-checked but may be empty in `mode=apply`: validity depends on the fresh Task 5 audit checksum and is evaluated only after audit/report persistence, producing `AWAITING_APPROVAL` with zero mutation when absent or invalid.
- `config.certified_target_slots` is only a local restriction. Production target authorization is the intersection of config values and the build-pinned certification artifact; adding `358` to config alone never authorizes it.
- A discovery manifest allows exactly `manifest_version,kind,game_revision,symbols,tested_platform_matrix,checksum`, requires `kind="discovery"` and empty symbols, and can confer no mutation capability.
- A runtime manifest additionally requires `source_audit_checksum`; exact logical symbol keys cover world readiness, guild manager/list/ID/chest ID, container manager/find/owner, slot array, empty-slot type, resize, dirty, replication, new-guild hook, container-in-use, and fatal-safe-stop descriptors. Descriptor keys/types are strict and reflection verification is read-only; candidates are never invoked.
- `tested_platform_matrix` is non-authoritative metadata. Only the certification artifact authorizes release slots.
- Manifest/artifact self-checksum is SHA-256 over canonical JSON after removing the top-level `checksum`; a release build separately pins the expected checksum.
- A certification artifact binds exact revision, profile, binding-manifest checksum, Gate A checksum, release-report checksum, exact required clients, and per-slot evidence. Every client record has a lowercase SHA-256 evidence checksum and all common Tier-0 checks: connect/reconnect, guild/chest access, first/last/all-row navigation, deposit/withdraw, split/quick-move/sort, last-slot after sort, close/reopen, server/app restart persistence, concurrent cross-platform access/state equality, last-slot display/quantity/GUID preservation, zero UI freeze/crash/disconnect, high-latency pass, and packet-loss pass. PS5 additionally requires Community Server discovery plus D-pad/analog/all-row/boundary/last-focus/tooltip/split/quick-move DualSense checks. Missing, false, unknown, or duplicate evidence blocks authorization.
- `MinRevision` never appears in runtime authorization; exact live revision equality is mandatory.

- [ ] **Step 1: Write failing config contract tests** covering the exact default, unknown keys, profile lock, required clients, include/exclude overlap, minimum rescan 30, expand-only lock, certification allow-list, and deferred apply approval validation. Prove that empty apply tokens parse for audit but confer no authority, and adding `358` to config alone does not make it certified.

```lua
local cfg = config.parse(default_text)
a.equal("audit", cfg.mode)
a.deep_equal({"SteamWindows", "PS5", "Mac"}, cfg.required_clients)
a.raises("unknown config key", function() config.parse('{"config_version":"1.1","oops":1}') end)
```

- [ ] **Step 2: Verify RED**, implement schema validation without coercion, verify GREEN.

- [ ] **Step 3: Write failing manifest tests** for exact revision, required symbol descriptors, allowed keys, checksum, type signatures, and empty discovery-only manifests.

- [ ] **Step 4: Verify RED**, implement parser/runtime type checks, verify GREEN.

- [ ] **Step 5: Write failing certification artifact tests** proving the artifact is bound to exact revision, deployment profile, Steam Windows·PS5·macOS evidence, certified slots, and a checksum pinned by the release build; reject config-only escalation and artifact checksum drift.

- [ ] **Step 6: Verify RED**, implement certification verification, verify GREEN.

### Task 4: Snapshots, fingerprints, and invariants

**Files:**
- Modify: `CrossplayGuildChestExpander/Scripts/json.lua`
- Create: `CrossplayGuildChestExpander/Scripts/fingerprint.lua`
- Create: `CrossplayGuildChestExpander/Scripts/snapshot.lua`
- Create: `CrossplayGuildChestExpander/Scripts/validator.lua`
- Create: `tests/support/fake_adapter.lua`
- Modify: `tests/unit/json_spec.lua`
- Create: `tests/unit/snapshot_spec.lua`
- Create: `tests/unit/validator_spec.lua`

**Interfaces:**
- Consumes adapter methods: `container_id`, `owner_guild_id`, `slots`, `slot_item`.
- Produces: `snapshot.capture(adapter, container) -> snapshot`; `validator.compare(before, after, target) -> ok, violations`.

**Exact contracts:**

- Add `json.array(values?)` so newly constructed empty arrays encode as `[]`; do not use decode hacks to mark arrays.
- Adapter IDs are non-empty opaque strings. `slots` returns a dense 1-based engine-order array. `slot_item` returns `nil` only for empty, otherwise exact `static_id`, `dynamic_guid`, integer quantity ≥1, canonical durability string, and lowercase SHA-256 instance metadata hash. Adapter failures and malformed projections fail closed with `CGCE-SNAP-*` errors.
- Snapshot schema contains version, container/owner IDs, slot/occupied counts, total quantity, a detached per-index slots array, and item fingerprint. Empty records are exactly `{index=N,empty=true}`; occupied records copy all preservation fields and no UObject references.
- Fingerprint is SHA-256 of canonical JSON `{schema="cgce.item-fingerprint.v1",items=[occupied records in ascending index]}`. Index participates; trailing empty slots do not.
- Validator expected count is `target` only when `before.slot_count < target`; otherwise it is unchanged `before.slot_count`, so 358→358 and 400→400 are valid no-ops.
- Violations are deterministic structured records: `CGCE-VAL-001` container ID, `002` owner, `003` slot count, `004` fingerprint, `005` occupied count, `006` total quantity, `007` existing slot/field, `008` appended non-empty. Return all applicable violations in code/index order.

- [ ] **Step 0: Write a failing JSON constructor test**, implement `json.array(values?)`, and verify new empty/non-empty arrays encode deterministically without changing decoded-array behavior.
- [ ] **Step 1: Write failing snapshot tests** proving stable fingerprint independent of Lua table iteration while preserving slot index, static ID, dynamic GUID, quantity, durability, and instance metadata hash. Cover detached copies and every malformed/missing adapter projection.

- [ ] **Step 2: Verify RED**, implement canonical per-slot representation and SHA-256 fingerprint, verify GREEN.

- [ ] **Step 3: Write failing invariant tests** for every PRD §16.1 rule, including empty appended slots, valid 358/400 no-ops, every existing field change, empty↔occupied, item index swaps, invalid slot counts, and deterministic multi-fault ordering.

```lua
local ok, errors = validator.compare(before, after, 358)
a.equal(false, ok)
a.contains(errors, "CGCE-VAL-004:item_fingerprint_changed")
```

- [ ] **Step 4: Verify RED**, implement structured violations, verify GREEN and full suite.

### Task 5: Discovery-safe state machine and read-only audit engine

**Files:**
- Create: `CrossplayGuildChestExpander/Scripts/state_machine.lua`
- Create: `CrossplayGuildChestExpander/Scripts/audit.lua`
- Create: `tests/unit/state_machine_spec.lua`
- Create: `tests/integration/audit_spec.lua`

**Interfaces:**
- Produces: `state_machine.new({mutation_capability = false}) -> opaque_machine`, `state_machine.state/transition(opaque_machine, ...)`; `audit.capture(context) -> opaque_audit`, `audit.checksum/canonical_json/to_table(opaque_audit)`.
- The Discovery Build has no resizer module and exposes no mutation adapter method.

**Exact contracts:**

- Discovery states are `DISABLED`, `PREFLIGHT`, `WAITING`, `AUDIT`, `AUDIT_COMPLETE`, `AWAITING_APPROVAL`, `BLOCKED`, and `UNSUPPORTED`. Only `enable`, preflight outcomes, world-ready/timeout outcomes, `audit_conflicts`, generic post-audit `audit_blocked`, and `audit_complete` are valid events. Both audit blocker events lead to `BLOCKED`, while the generic event preserves report/persistence failure meaning instead of misclassifying it as a topology conflict. `BLOCKED`, `UNSUPPORTED`, `AUDIT_COMPLETE`, and `AWAITING_APPROVAL` are terminal for one execution epoch.
- When `mutation_capability=false`, the graph contains no `APPLYING`, `VALIDATING`, `COMPLETE`, or `FAILED_AFTER_MUTATION` node or edge. `apply` from any state returns `CGCE-STATE-MUTATION-BUILD-UNAVAILABLE` without changing state; a fresh execution creates a new machine instead of resetting an audit identity in place.
- `audit.capture` accepts only scalar world/revision/profile/target/filter fields and three read-only ports: `list_guilds`, `resolve_guild_chest`, and `snapshot_container`. The context rejects unknown/write-capable dependencies and never reads `resize`, `append`, `mark_dirty`, `replicate`, game-thread, or raw UObject setter functions.
- Canonical unsigned audit schema is `cgce.audit.v1` with exact world ID, positive integer game revision, deployment profile, target, sorted include/exclude arrays, all discovered guild records sorted by opaque guild ID, and deterministic top-level blocking errors. The captured canonical value adds `checksum = sha256(canonical_unsigned_json)`; timestamps never participate. Both machine and audit identities are non-table opaque handles so `rawset` cannot shadow authoritative methods or fields. Each saved accessor calls one private captured-value resolver directly—no accessor dispatches through another mutable public module slot. `audit.to_table` returns a fresh detached copy, while checksum/canonical accessors reject forged handles.
- Each guild record contains exact guild ID/name, configured container ID when present, status, `eligible_action = expand|noop|none`, detached Task 4 snapshot when available, and deterministic errors. Missing configured chest IDs are reported as `not_initialized`, not resolved and not treated as conflicts.
- Establish candidates only through `guild_id -> configured chest_container_id -> resolved owner_guild_id`. Never scan by class/name/position. Detect duplicate non-empty container IDs across every discovered guild before filters; owner mismatch, unresolved references, malformed/non-guild references, and malformed snapshots are blocking even for excluded guilds. Unrelated general containers are never included or snapshotted.
- Empty include means every guild except explicit excludes. A non-empty include limits action eligibility, but non-selected guilds remain in the audit as `excluded_by_filter`. Include/exclude overlap fails closed. Counts below target are `eligible_expand`; counts at or above target are `eligible_noop`, so 358 and 400 never become shrink candidates.
- Errors use `{code,field,detail}` and deterministic order. Unknown string keys are sorted; non-string keys use a fixed field label and never `tostring` an address-bearing table/function/userdata. State errors use `CGCE-STATE-INVALID-EVENT`, `CGCE-STATE-INVALID-CONTEXT`, `CGCE-STATE-MUTATION-BUILD-UNAVAILABLE`, or `CGCE-STATE-TERMINAL`; audit errors use the `CGCE-AUD-*` namespace for context, filter overlap, projection, duplicate, unresolved container, owner mismatch, non-guild container, snapshot, and checksum failures.

- [ ] **Step 1: Write failing state-transition table tests** for `DISABLED → PREFLIGHT → WAITING/AUDIT → AUDIT_COMPLETE/AWAITING_APPROVAL` plus terminal `BLOCKED` and `UNSUPPORTED`. Prove `APPLYING`, `VALIDATING`, `COMPLETE`, and `FAILED_AFTER_MUTATION` are unreachable when `mutation_capability=false`, and prove raw assignment/`rawset` cannot replace transition/state authority.
- [ ] **Step 2: Verify RED**, implement the explicit discovery-safe transition table, verify GREEN.
- [ ] **Step 3: Write failing read-only audit tests** for all discovered guilds, 358/400 no-op eligibility, owner mismatch, duplicate IDs, include/exclude, general-container exclusion, and deterministic audit checksum.
- [ ] **Step 4: Verify RED**, implement audit capture without any write-capable dependency, verify GREEN.
- [ ] **Step 5: Add exported-surface tests** proving no production file through Task 10 defines/exports `resize`, `append`, `mark_dirty`, `replicate`, raw property writes, or a mutating state edge. Dynamically load pure production modules behind traps and prove the audit never accesses a write-capable member; permit only the literal `cgce apply` command added later when its tested result is `MUTATION_BUILD_UNAVAILABLE`.

### Task 6: Approval, reports, ledger, security boundaries, and structured logging

**Files:**
- Create: `CrossplayGuildChestExpander/Scripts/approval.lua`
- Create: `CrossplayGuildChestExpander/Scripts/report.lua`
- Create: `CrossplayGuildChestExpander/Scripts/ledger.lua`
- Create: `CrossplayGuildChestExpander/Scripts/logger.lua`
- Create: `CrossplayGuildChestExpander/Scripts/path_guard.lua`
- Create: `CrossplayGuildChestExpander/Scripts/conflict_detector.lua`
- Create: `docs/release-report.schema.json`
- Create: `tests/support/fake_filesystem.lua`
- Create: `tests/unit/approval_spec.lua`
- Create: `tests/unit/report_spec.lua`
- Create: `tests/unit/ledger_spec.lua`
- Create: `tests/unit/logger_spec.lua`
- Create: `tests/unit/path_guard_spec.lua`
- Create: `tests/unit/conflict_detector_spec.lua`
- Create: `tests/unit/release_report_schema_spec.lua`

**Interfaces:**
- Produces: `approval.token/verify(fields)`, `report.build/validate(context)`, `report.persist(fs, root, relative_path, value)`, `ledger.load/save/verify(fs, ...)`, `path_guard.resolve(fs, root, relative_path)`, `conflict_detector.scan(policy, mods, hooks, containers)`, `logger.text/jsonl`.

**Exact contracts:**

- Keep the local operational report separate from Task 14's public release report. The operational report may contain raw world/guild/container identifiers and is always `report_kind="operational"`, `build_kind="discovery"`, and `release_eligible=false`; the public release schema contains only checksummed evidence and no raw world/guild/container/player ID, password, public IP, or command line. The certification artifact references the final release-report checksum; the release report must not reference the certification artifact checksum back.
- Approval accepts exactly world ID, positive exact revision, Task 5 `audit.checksum`, approved slot candidate, and fixed deployment profile. Hash a versioned, key-labelled, UTF-8 byte-length-prefixed canonical preimage; verify lowercase SHA-256 with constant-time comparison and never echo a token. `require_operator_approval=false` grants no authority: every eventual apply still requires this token.
- Operational reports capture trusted Task 5 accessor references privately at module initialization, revalidate and embed a detached audit, sort mod inventory and findings, reject secret-bearing keys recursively, allow only discovery states, and self-checksum canonical JSON without their checksum field. No authority-relevant call is dynamically routed through a caller-mutable public module slot. Persistence must verify the supplied checksum, then use the injected filesystem port for exclusive same-directory temp creation, durable flush, atomic replace, and exact read-back; there is no non-atomic fallback.
- `path_guard` rejects POSIX/Windows/UNC/device/drive-relative absolute paths, both-separator traversal, empty/dot components, control/NUL, ADS/colon, reserved device names, trailing dot/space, symlink/reparse traversal, missing/non-directory parents, sibling-prefix escape, and filesystem ports lacking no-follow/atomic-replace/durable-flush guarantees. Root, every parent, target, and temp sibling are canonicalized and checked by component boundary rather than string prefix.
- Ledger data self-checksums, sorts guild records, stores source audit checksum plus before/after counts and fingerprints, and never stores raw dynamic GUID sets. Every verify captures a fresh Task 5 audit and examines every live guild; a completed cache never suppresses startup inspection. Missing is distinct from malformed/read failure, and restart-required can only yield `can_mark_completed=true` after a live match—it cannot update itself.
- Logger formatting performs no I/O, recursively redacts normalized credential-key variants, escapes controls so text/JSONL remain one physical line, rejects per-slot INFO-or-higher payloads, and emits a small valid replacement event rather than truncated JSON above the fixed 16 KiB limit.
- Conflict detection uses only exact paths/types from verified policy; never guess package names or fuzzy-match hooks. Before Gate A, inventory is allowed but collision coverage remains `partial` and cannot authorize apply. Exact foreign hook/storage collisions and type replacement block; an unknown count below target blocks, while a count above target is warning + forced no-op.

- [ ] **Step 1: Write failing approval tests** using unambiguous length-prefixed UTF-8 fields for world ID, revision, Task 5 `audit.checksum` as the canonical audit-report checksum, target, and profile; prove any field change invalidates the token. A timestamp-dependent wrapper/report checksum must never substitute for this binding.
- [ ] **Step 2: Verify RED**, implement SHA-256 approval token, verify GREEN.
- [ ] **Step 3: Write failing report/ledger tests** for deterministic JSON, atomic temp-write/rename adapter, live save-as-source-of-truth drift, per-guild results, and persistence failure blocking later apply. Prove a completed-guild cache never suppresses startup live-container reinspection and invalidates on revision, target, fingerprint, or owner change.
- [ ] **Step 4: Verify RED**, implement persistence ports and verification, verify GREEN.
- [ ] **Step 5: Write failing log tests** for control-character escaping, credential field redaction, event size bound, and no per-slot INFO logs; implement and verify.

- [ ] **Step 6: Write failing containment/conflict tests** rejecting absolute paths, `..`, symlink escape, package-external manifests, unallowlisted manifest keys/function paths, colliding storage mods/hooks, unexpected slot counts, and replaced container types. Capture mod package names/versions in the report; implement and verify.

### Task 7: Discovery commands, bounded scheduling, and connectivity preflight

**Files:**
- Create: `CrossplayGuildChestExpander/Scripts/command_router.lua`
- Create: `CrossplayGuildChestExpander/Scripts/scheduler.lua`
- Create: `CrossplayGuildChestExpander/Scripts/platform_preflight.lua`
- Create: `tests/unit/command_router_spec.lua`
- Create: `tests/unit/scheduler_spec.lua`
- Create: `tests/unit/platform_preflight_spec.lua`

**Interfaces:**
- Produces Discovery Build commands: `cgce status|audit|guilds|verify|export-report`; `cgce apply` returns `MUTATION_BUILD_UNAVAILABLE`; `scheduler.retry(options, probe)`; `platform_preflight.check(args, option_settings)`.

**Exact contracts:**

- `command_router.new` accepts only five read-only ports for status, audit, guild listing, live verification, and existing report path. Parse one control-free line as exact lowercase `cgce <command>` with no shell/quote interpretation or arguments. Every successful response contains revision, mode, target, and state; payloads are detached JSON-safe values. `cgce apply` (including any attempted arguments) returns `MUTATION_BUILD_UNAVAILABLE` without calling any port, regardless of mode, token, or state.
- `scheduler.retry` receives explicit positive `max_attempts`, nonnegative finite delay, injected schedule/cancel callbacks, optional `on_terminal(result)`, and a probe; it returns a generation-guarded controller exposing detached `status()` and idempotent `cancel()`. The first probe runs immediately, so status distinguishes `PENDING` from terminal `READY|EXHAUSTED|FAILED|CANCELLED`; at most one timer is outstanding. Probe/callback errors fail closed, late callbacks are no-ops, and even a synchronous fake scheduler cannot exceed the bound or deliver terminal twice.
- `scheduler.rescan_interval(nil)` is 60 seconds and rejects values below 30. `scheduler.cache_decision` always requests live inspection at startup, even for a matching completed cache. Fallback may skip only when revision, target, fingerprint, and owner all exactly match; malformed/missing data inspects conservatively and multiple drift reasons are deterministic.
- `platform_preflight` parses dense argv plus either a full `OptionSettings=(...)` assignment or tuple RHS using quote/escape/nested-parenthesis awareness—never comma splitting. Duplicate CLI/INI keys, malformed quoting/tuples, and control characters fail closed without exposing raw arguments or secrets.
- Preflight requires `-publiclobby`; matching integer `-port`, `-publicport`, and `PublicPort` in 1–65535; `CrossplayPlatforms` containing `Steam`, `PS5`, and `Mac`; `bAllowClientMod=False`; and `LogFormatType=Json`. Xbox is optional. `AllowConnectPlatform` and `IsServer=true` are never compatibility evidence. Even a green diagnostic reports certification `UNPROVEN` until Gate B.
- `merge_option_settings` returns text only and updates the four known keys in place, appending missing keys deterministically while byte-preserving unrelated/secret fields. Existing Xbox is preserved; policy may add it; unknown platform values cause failure rather than silent deletion. A second merge is byte-identical and no file is written.

- [ ] **Step 1: Write failing command tests** proving unknown commands and arguments do not mutate, Discovery Build `apply` always returns `MUTATION_BUILD_UNAVAILABLE`, and output contains revision/mode/target/state.
- [ ] **Step 2: Verify RED**, implement command routing, verify GREEN.
- [ ] **Step 3: Write failing scheduler tests** proving bounded world-ready retries, 30-second minimum fallback, 60-second default, no infinite polling, and cache invalidation on revision/target/fingerprint/owner drift with mandatory startup live reinspection.
- [ ] **Step 4: Verify RED**, implement scheduler as injected clock callbacks, verify GREEN.
- [ ] **Step 5: Write failing connectivity tests** that parse the real `PalWorldSettings.ini` `OptionSettings` tuple for `-publiclobby`, `CrossplayPlatforms` containing PS5 and Mac, public port match, and diagnostic-only behavior; do not use the deprecated REST `AllowConnectPlatform` field. Implement and verify.

### Task 8: UE4SS read-only runtime adapter and Discovery Build

**Files:**
- Modify: `CrossplayGuildChestExpander/Scripts/binding_manifest.lua`
- Modify: `tests/unit/binding_manifest_spec.lua`
- Create: `CrossplayGuildChestExpander/Scripts/discovery_probe.lua`
- Create: `CrossplayGuildChestExpander/Scripts/ue4ss_adapter.lua`
- Create: `CrossplayGuildChestExpander/Scripts/revision_guard.lua`
- Create: `CrossplayGuildChestExpander/Scripts/world_ready.lua`
- Create: `CrossplayGuildChestExpander/Scripts/guild_repository.lua`
- Create: `CrossplayGuildChestExpander/Scripts/container_resolver.lua`
- Create: `tests/support/fake_ue4ss.lua`
- Create: `tests/integration/discovery_adapter_spec.lua`
- Create: `docs/discovery-runbook.md`

**Interfaces:**
- Produces: a self-checksummed non-authoritative `discovery_probe` parser; `ue4ss_adapter.new(strict_api_port)` with narrow read/observe/close methods; `revision_guard.check`; bounded `world_ready`; detached `guild_repository`; exact `container_resolver`. Generic hook, function-call, game-thread, raw property, and TArray-write APIs are not exported.

**Exact contracts:**

- The empty-symbol Discovery Manifest remains incapable. A separate `discovery_probe_request` carries owner-supplied exact candidate paths and signatures, permits partial evidence, self-checksums canonical JSON, and rejects fuzzy/wildcard values. It is explicitly non-authoritative and is never accepted by certification or `mutation_guard`; automatic class/property inference remains unsupported.
- Runtime property descriptors add exact `owner_path`, `member_name`, observed full `path`, and canonical `type_signature`; function/class/struct descriptors retain exact absolute identity and signatures. Expand logical descriptors to cover world-ID provenance, guild name, exact guild-chest class/container ID, and the complete Task 4 snapshot projection: empty/occupied discriminator, static ID, dynamic GUID, quantity, durability canonicalization, and metadata-hash inputs. No userdata `tostring()` may stand in for a verified conversion.
- `ue4ss_adapter` accepts only an allow-listed fakeable UE4SS v3.0.1 API surface and reports mutation/raw-property-write/TArray-write/function-invoke as false. `StaticFindObject` receives exact absolute UObject paths; `FindAllOf` uses only a short name derived from an already verified UClass and is treated as loaded-instance inventory, never proof that an absent object is unsupported.
- Property reads first resolve the exact owner and member, then compare observed full name/signature before `GetPropertyValue`. TArray iteration copies `elem:get()` values in engine order behind a private callback. `SetPropertyValue`, `ImportText`, `ContainerPtrToValuePtr`, `elem:set`, `Empty`, index assignment, constructors, raw addresses, and candidate UFunction invocation are prohibited and trapped in tests.
- Expose only `observe_function(descriptor, observer)`: verify the UFunction first, provide detached phase/path metadata only, discard observer return values, and never expose `RemoteUnrealParam` or UObject context. `/Script/` registration uses a no-op pre plus post observer; non-`/Script/` is post-only. Handles retain exact path plus both IDs; `close` invalidates the generation, unregisters active handles in reverse exactly once, and continues deterministic cleanup after individual failures.
- Live revision is a strict injected reader returning one positive integer. Until Gate A proves an authoritative runtime property/function or server-log source, it reports unavailable; `Info.json.MinRevision` is never used as live revision. Missing exact manifest yields `UNSUPPORTED`; duplicate/malformed/checksum/type mismatch yields `BLOCKED`; even an exact read-only manifest confers no mutation capability.
- World readiness does immediate probe, optional exact observation, post-registration race re-probe, and bounded polling. Hook events merely wake a new probe. Selected-world singleton/cardinality checks must pass before `READY`; timeout blocks. Generation fences make timer/hook/game-thread callbacks after cancel no-ops; UE4SS delayed callbacks are not claimed physically cancellable without real evidence.
- Guild/container traversal uses only exact selected-world managers and verified read projections. A missing configured chest ID performs zero resolution. Before Gate A, exact guild-chest class inventory + verified container-ID property is used; `find_container_function` is validated but never invoked. Results are detached, epoch-bound, and reject ambiguous IDs, wrong world/class/owner, or general containers.
- Every Gate A evidence record states status, kind, exact query/path, observed full name, signature and coverage, provenance API, and `invoked=false`. `NOT_LOADED`, partial function signature coverage, or any missing snapshot projection keeps acceptance blocked.

- [ ] **Step 1: Write failing contract tests** against the selected stable UE4SS v3.0.1 API surface using fakes. Prove missing APIs/symbols yield `UNSUPPORTED`/`BLOCKED`, `/Script/` and non-`/Script/` hook callback contracts are distinguished, hook IDs are unregistered on shutdown/reload, and fuzzy matching/raw writes are absent.
- [ ] **Step 2: Verify RED**, implement exact-name reflection wrappers and read-only capability detection, verify GREEN.
- [ ] **Step 3: Write failing guild traversal tests** proving `guild_id → container_id → owner_guild_id` and duplicate/container-type rejection.
- [ ] **Step 4: Verify RED**, implement repositories/resolver, verify GREEN.
- [ ] **Step 5: Implement explicit discovery evidence fields and rejection rules** for every PRD §32 Gate A item: revision; guild manager/list/ID/chest-ID; container manager/find/slot array; empty-slot type; exact resize/add-slot candidates and signatures; dirty and replication candidates/signatures; world-ready and new-guild hook candidates; in-use detection method; canonical 54-slot snapshot. Candidate discovery is read-only, never invokes a candidate, records provenance/type signatures, and leaves all mutation functions unavailable.

### Task 9: Discovery runtime orchestration

**Files:**
- Create: `CrossplayGuildChestExpander/Scripts/cgce.lua`
- Create: `CrossplayGuildChestExpander/Scripts/main.lua`
- Create: `tests/integration/discovery_runtime_spec.lua`

**Interfaces:**
- Produces: `cgce.new(read_only_dependencies)`, `app:start()`, `app:shutdown()`, `app:handle_command(line)`.

**Exact contracts:**

- Startup order is lifecycle/dependency allow-list → path containment → config → one exact live revision read → manifest/checksum/reflection → platform diagnostic → bounded readiness → exact conflict inventory → fresh audit → existing-ledger live comparison → always-on approval verification in apply mode → predicted terminal state → operational report build + atomic durable persist/read-back → actual terminal transition. Bootstrap hard failures stop at the first stage; post-audit findings are sorted and retained.
- Immediate readiness transitions `PREFLIGHT → AUDIT`; a pending controller transitions exactly once through `WAITING`. The package policy is one immediate probe plus at most 59 one-second retries. Exhaustion/probe/schedule/callback failure blocks; late callbacks are fenced.
- Platform misconfiguration, pre-Gate partial collision coverage, malformed existing ledger, or disabled safety intent flags remain visible diagnostics in audit mode but block apply mode. Audit topology/snapshot blockers always block. If no other blocker exists, missing or invalid fresh-audit approval yields `AWAITING_APPROVAL`; a valid token still ends only at discovery `AUDIT_COMPLETE` and `cgce apply` remains unavailable.
- `require_operator_approval=false`, `verify_on_startup=false`, `write_migration_ledger=false`, and `fail_fast=false` never skip approval, fresh live audit, ledger verification, integrity failure, or report persistence. Discovery writes only its current operational report; it never writes a migration ledger.
- Predict final state before persistence but transition only after the receipt proves exact bytes/checksums. Report build/persist/read-back failure uses `audit_blocked → BLOCKED`; no stale report or receipt is reused. `UNSUPPORTED` is reserved for a valid live revision with no exact supported manifest/API; malformed or mismatched trust data is `BLOCKED`.
- Construction rejects unknown or write-capable dependencies. The only allowed observation hook is verified world-ready; mutation/new-guild/resize/dirty/replication paths are never registered, and no `ExecuteInGameThread` or UObject write is callable.
- Shutdown first invalidates its generation, cancels each timer once, and releases every registered observation handle in reverse once; cleanup continues after errors without replacing the original failure. Shutdown is idempotent, duplicate start is rejected, and reload requires successful cleanup followed by a fresh `cgce.new` epoch.

- [ ] **Step 1: Write failing startup tests** for unsupported revision, invalid config, path escape, missing report path, audit default, world-ready retry, conflict detection, and zero write-capable hook registration.
- [ ] **Step 2: Verify RED**, implement dependency-injected read-only orchestration, verify GREEN.
- [ ] **Step 3: Write failing shutdown/reload tests** proving every registered discovery hook ID and timer is released and duplicate initialization is rejected.
- [ ] **Step 4: Verify RED**, implement lifecycle cleanup, verify GREEN and the exported-surface no-mutation check.

### Task 10: Discovery package, static verifier, and operator documentation

**Files:**
- Create: `CrossplayGuildChestExpander/Info.json`
- Create: `CrossplayGuildChestExpander/README.md`
- Create: `CrossplayGuildChestExpander/CHANGELOG.md`
- Create: `CrossplayGuildChestExpander/thumbnail.png`
- Create: `scripts/verify-package.sh`
- Create: `scripts/build-release.sh`
- Create: `tests/integration/package_spec.lua`
- Create: `docs/certification-runbook.md`
- Create: `docs/requirements-traceability.md`

**Interfaces:**
- Produces: a deterministic **Discovery Build** archive that is server-only and mutation-incapable. The release build path remains hard-blocked until Tasks 11–13.

- [ ] **Step 1: Write a failing package test** asserting one Lua `InstallRule` with `IsServer=true`, UE4SS dependency, allow-listed metadata thumbnail, no client scripts/assets/PAK/DLL, no mutation modules, and no `MinRevision=0` in any release archive. Treat `IsServer=true` only as a deployment target, not a network-safety proof.
- [ ] **Step 2: Verify RED**, create package metadata and static verifier, verify GREEN for a clearly labeled non-release Discovery Build and prove release build remains blocked without Gate A acceptance, exact manifest checksum, pinned certification artifact, and non-zero `MinRevision`.
- [ ] **Step 3: Document exact backup, audit, approval, apply, verify, update, removal, rollback, discovery, Steam/PS5/macOS certification, performance, and six-hour soak procedures.
- [ ] **Step 4: Populate requirement traceability** mapping every `FR-*`, `AT-*`, DoD item, and §32 artifact to code/test/manual evidence, with unproven runtime/platform rows marked blocked rather than passed.

### Task 11: Gate A real Windows server discovery

**Files:**
- Create after capture: `CrossplayGuildChestExpander/Scripts/bindings/<revision>.json`
- Create after capture: `artifacts/discovery/<revision>/audit-report.json`
- Create after review: `artifacts/discovery/<revision>/gate-a-acceptance.json`
- Modify: `docs/requirements-traceability.md`

**Interfaces:**
- Consumes a user-provided Windows Palworld Dedicated Server with UE4SS and a disposable backed-up test world.
- Produces PRD §32 evidence items 1–16, a verified fatal-save suppression or immediate safe-shutdown capability, an exact checksum-bound manifest, and a reviewed Gate A acceptance record containing the report checksum, manifest checksum, world ID, game revision, UE4SS version, reviewer, and timestamp. If Palworld exposes no verified way to prevent a subsequent save or force a safe stop after invariant failure, Gate A cannot authorize mutation.

- [ ] **Step 1:** Run the Discovery Build in audit-only mode on the exact target revision.
- [ ] **Step 2:** Inspect runtime types/functions and record exact paths/signatures for all 16 evidence fields, including empty-slot type, resize/add-slot candidate, dirty/replication candidates, both hooks, and in-use detection. Additionally discover and safely prove a fatal path that suppresses later normal/autosave or immediately stops the server without saving. Reject missing, ambiguous, fuzzy, unloaded, or mismatched candidates; absence of the fatal capability blocks mutation authorization.
- [ ] **Step 3:** Verify three-way guild/container ownership on representative guilds and prove general containers are excluded.
- [ ] **Step 4:** Add the exact manifest, run contract tests, independently review the report, and create a checksum-bound `gate-a-acceptance.json`. Mutation remains absent until this acceptance file passes automated validation.

### Task 12: Post-Gate-A mutation engine and fatal safety controls

**Files:**
- Create: `CrossplayGuildChestExpander/Scripts/gate_a.lua`
- Create: `CrossplayGuildChestExpander/Scripts/mutation_guard.lua`
- Create: `CrossplayGuildChestExpander/Scripts/migration.lua`
- Create: `CrossplayGuildChestExpander/Scripts/resizer.lua`
- Create: `CrossplayGuildChestExpander/Scripts/fatal_safety.lua`
- Create: `CrossplayGuildChestExpander/Scripts/persisted_verifier.lua`
- Create: `tests/integration/mutation_guard_spec.lua`
- Create: `tests/integration/migration_spec.lua`

**Interfaces:**
- `mutation_guard.authorize(context) -> authorization` requires a valid Gate A acceptance checksum; exact manifest checksum; a verified fatal-save/stop capability; fresh audit captured immediately before apply; an atomically persisted operational-report receipt for that exact audit; approval token matching that fresh audit checksum; live revision/world/profile; safety config invariants `require_operator_approval=true`, `verify_on_startup=true`, and `write_migration_ledger=true`; pinned release certification artifact for production, or the isolated certification exception below. Config booleans can never waive these requirements.
- Certification exception requires `certification_mode=true`, disposable test-world ID allow-list, candidate slot in `{120,256,358}`, valid Gate A acceptance, and an explicit checksum-bound certification approval token. It is rejected by production builds.
- Mutation adapter: `execute_in_game_thread(fn)`, `online_player_count()`, `is_any_guild_chest_in_use()`, `is_container_in_use(container)`, `resize_via_verified_function(container,target)`, `mark_dirty(container)`, `replicate(container)`, `enter_fatal_no_save_mode(reason)`.
- `persisted_verifier` records `VALIDATING_RESTART_REQUIRED`; only next-start live save/reload verification may transition to `COMPLETE`.

- [ ] **Step 1: Write failing guard tests** proving zero mutation for missing/changed Gate A acceptance, manifest checksum drift, absent/unverified fatal-save capability, stale audit/report receipt, world/revision/profile mismatch, any disabled approval/startup-verification/ledger safety flag, config-only slot escalation, missing Tier-0 certification, non-allow-listed test world, or invalid approval token.
- [ ] **Step 2: Verify RED**, implement authorization with exact checksum equality and fresh audit recapture, verify GREEN.
- [ ] **Step 3: Write failing synthetic migration tests** for 54→target empty/occupied, target/400 no-op, owner mismatch, duplicate IDs, include/exclude, use-state race, online-player/global-chest preflight, per-container immediate recheck, append exception, fingerprint mismatch, and idempotent second run.
- [ ] **Step 4: Verify RED**, implement only the exact Gate-A-approved resize/add-slot function path; blind raw `TArray` append remains unsupported unless Gate A explicitly proves its factory and persistence semantics. Execute mutation, dirty/replicate, after snapshot, and invariant validation in one `ExecuteInGameThread` callback.
- [ ] **Step 5: Write failing fatal-safety tests** proving any post-mutation invariant failure enters terminal `FAILED_AFTER_MUTATION`, calls `enter_fatal_no_save_mode`, emits `STOP_SERVER_AND_RESTORE_BACKUP`, and rejects all later mutation/save automation.
- [ ] **Step 6: Write failing persisted-state tests** proving successful in-memory apply reaches only `VALIDATING_RESTART_REQUIRED`; a next-start live snapshot matching the ledger reaches `COMPLETE`, while mismatch reaches fatal `FAILED` and blocks release.

### Task 13: Post-Gate-A replication and new-guild lifecycle

**Files:**
- Create: `CrossplayGuildChestExpander/Scripts/replication.lua`
- Create: `CrossplayGuildChestExpander/Scripts/new_guild_hook.lua`
- Modify: `CrossplayGuildChestExpander/Scripts/cgce.lua`
- Create: `tests/integration/runtime_mutation_spec.lua`
- Create: `tests/integration/new_guild_spec.lua`

**Interfaces:**
- Produces `new_guild_hook.install(app, accepted_manifest, adapter)` and uses the same guarded migration engine as existing guilds.
- Exact hooks are registered only after world readiness and unregistered by both returned hook IDs; a 60-second cached rescan backs up native-call paths that bypass UFunction hooks.

- [ ] **Step 1: Write failing runtime tests** proving mutation hooks are absent without Gate A acceptance and authorization, all UObject work is game-thread queued, and post-mutation validation remains in the same callback.
- [ ] **Step 2: Verify RED**, integrate the guarded engine and verified dirty/replication functions, verify GREEN.
- [ ] **Step 3: Write failing new-guild tests** proving exact hook registration, limited initialization retries, empty/non-empty invariant handling, common engine reuse, hook cleanup, and fallback rescan cache invalidation from live state.
- [ ] **Step 4: Verify RED**, implement lifecycle modules, verify GREEN.

### Task 14: Gate B isolated mutation, Tier-0 certification, and release

**Files:**
- Create after test: `artifacts/certification/<revision>/release-report.json`
- Create after test: `artifacts/certification/<revision>/release-certification.json`
- Modify: `CrossplayGuildChestExpander/config/config.default.json`
- Modify: `CrossplayGuildChestExpander/Info.json`
- Modify: `docs/requirements-traceability.md`

**Interfaces:**
- Consumes Gate A acceptance, a disposable-world allow-list, explicit certification approval, backed-up Windows server worlds, and Steam Windows, PS5, and macOS vanilla clients.
- Produces a checksum-pinned release certification artifact, after/reload snapshots, removal evidence, performance baselines, new-guild evidence, and final release eligibility.

- [ ] **Step 1:** Validate all Gate B admission artifacts mechanically, then run 54→120 on an allow-listed disposable world; save/restart/reload, verify every invariant and a second-run mutation count of zero.
- [ ] **Step 2:** Repeat `120→256→358`; add a slot value to the release certification artifact only after Steam Windows, PS5, and macOS all pass UI, last-slot, restart/reconnect, and cross-platform data checks. PS5 evidence must include discovery through the Community Server list while the server runs with `-publiclobby` and matching advertised/listen ports.
- [ ] **Step 3:** Create 20 new guilds and prove first-use expansion, hook/fallback behavior, zero tick stalls, and live-state cache invalidation.
- [ ] **Step 4:** Run concurrent access and the exact removal protocol: back up the world, disable the mod, restart, then prove last-slot access and item GUID/quantity preservation independently on Steam Windows, PS5, and macOS. Run the exact release thresholds: steady CPU ≤1 percentage point; memory ≤100MB; 100-guild audit ≤5s; 100 empty migrations ≤10s; single 54→358 ≤100ms; scan ≥60s; save increase ≤15%; chest-open p95 ≤baseline+300ms; reconnect increase ≤10%; six-hour soak with zero critical errors.
- [ ] **Step 5:** Generate the checksummed release report and pinned certification artifact, inject exact non-zero `MinRevision`, build the server-only archive, run package/security/full completion audits, and reject release if any manual evidence is absent.

## Plan Self-Review

- Every P0/P1 functional requirement maps to Tasks 3–14.
- Every pre-discovery synthetic/unit test category maps to Tasks 1–10.
- Tasks 1–10 contain no production mutation surface. Task 11 is the mandatory real-server Gate A.
- Mutation code begins only in Task 12 after a machine-validated Gate A acceptance record exists.
- Actual save/reload, removal, performance, PS5, and macOS claims remain explicitly unproven until Task 14 produces primary evidence.
- The apparent §32 circularity is resolved operationally as Gate A (items 1–16, read-only discovery) followed by Gate B (items 17–20, disposable test-world mutation/certification); production mutation remains disabled between them.
- Fresh audit checksum binding, fatal no-save mode, persisted-state restart verification, config-only certification escalation rejection, path containment, conflict detection, hook cleanup, new-guild evidence, and exact performance thresholds are explicit gates.
- No placeholder game revision or guessed Palworld symbol is accepted as a release manifest.
