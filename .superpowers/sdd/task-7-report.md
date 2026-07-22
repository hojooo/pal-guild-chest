# Task 7 Report — Discovery commands, bounded scheduling, and connectivity preflight

## Scope

- Added a discovery-only command router with exactly five injected read ports: `status`, `audit`, `guilds`, `verify`, and `report_path`.
- Added bounded immediate-first retry scheduling with generation guards, one outstanding timer, detached status, idempotent cancellation, and exactly-once terminal delivery.
- Added fallback rescan interval validation and conservative cache decisions that always require startup live inspection.
- Added a quote-, escape-, and nested-parenthesis-aware parser for dense argv and `OptionSettings=(...)` or tuple RHS input.
- Added diagnostic-only Steam Windows, PS5, and Mac connectivity checks plus a pure byte-preserving, idempotent four-key `OptionSettings` merge.
- Added no UE4SS integration, filesystem write, shell interpretation, mutation port, UObject write, container resize/append, dirty/replication request, or apply transition.

## TDD evidence

### Cycle 1 — Command router RED

Command:

```sh
./scripts/run-tests.sh tests/unit/command_router_spec.lua
```

Exit status: `1`

Observed failure:

```text
FAIL tests/unit/command_router_spec.lua
tests/unit/command_router_spec.lua:2: module 'CrossplayGuildChestExpander.Scripts.command_router' not found
```

The command contract loaded before `command_router.lua` existed.

### Cycle 1 — Command router GREEN

Command:

```sh
./scripts/run-tests.sh tests/unit/command_router_spec.lua
```

Exit status: `0`; final result: `8` command-router tests passed.

Coverage includes all five read-only commands, the mandatory revision/mode/target/state envelope, detached JSON-safe output, exact lowercase one-line parsing, no shell/quote/argument interpretation, sanitized port failures, strict five-port construction, empty-array preservation, explicit shared-null rejection, and zero-port `MUTATION_BUILD_UNAVAILABLE` handling for `cgce apply` and attempted arguments.

### Cycle 2 — Scheduler and cache RED

Command:

```sh
./scripts/run-tests.sh tests/unit/scheduler_spec.lua
```

Exit status: `1`

Observed failure:

```text
FAIL tests/unit/scheduler_spec.lua
tests/unit/scheduler_spec.lua:2: module 'CrossplayGuildChestExpander.Scripts.scheduler' not found
```

The bounded scheduler contract loaded before `scheduler.lua` existed.

### Cycle 2 — Scheduler and cache GREEN

Command:

```sh
./scripts/run-tests.sh tests/unit/scheduler_spec.lua
```

Exit status: `0`; final result: `15` scheduler/cache tests passed.

Coverage includes immediate `READY`, async `PENDING`, exact `EXHAUSTED` bounds, a 1,000-attempt synchronous fake without recursion or duplicate terminal delivery, idempotent `CANCELLED`, sanitized probe/schedule/cancel/terminal failures, callback-returned errors, reentrant cancellation, returned-timer cleanup, scalar/array detachment, invalid options, the 60-second default, the 30-second minimum, mandatory startup inspection, exact fallback cache matching, malformed cache handling, and deterministic revision/target/fingerprint/owner drift reasons.

### Cycle 3 — Connectivity parser and merge RED

Command:

```sh
./scripts/run-tests.sh tests/unit/platform_preflight_spec.lua
```

Exit status: `1`

Observed failure:

```text
FAIL tests/unit/platform_preflight_spec.lua
tests/unit/platform_preflight_spec.lua:3: module 'CrossplayGuildChestExpander.Scripts.platform_preflight' not found
```

The connectivity contract loaded before `platform_preflight.lua` existed.

### Cycle 3 — Connectivity parser and merge GREEN

Command:

```sh
./scripts/run-tests.sh tests/unit/platform_preflight_spec.lua
```

Exit status: `0`; final result: `10` preflight/merge tests passed.

Coverage includes full assignment and RHS tuple parsing, quoted commas/equals/parentheses, escapes, nested tuples, dense argv, case-insensitive duplicate-key rejection, controls, malformed quoting/tuples, matching integer ports, required Steam/PS5/Mac values, optional Xbox, `bAllowClientMod=False`, `LogFormatType=Json`, secret-free normalized diagnostics, `AllowConnectPlatform`/`IsServer` non-evidence, `UNPROVEN` certification, unknown-platform rejection, byte preservation, deterministic missing-key append, Xbox preservation/addition, and second-merge byte identity.

## Review-driven regression cycles

### Semantic status envelope RED → GREEN

Command:

```sh
./scripts/run-tests.sh tests/unit/command_router_spec.lua
```

The new regression first failed with `expected nil, got table` for revision `0`. The router now requires a positive integer revision and target, exact `audit|apply` mode, and a non-empty state. The focused suite returned to GREEN.

### JSON semantic detachment RED → GREEN

Commands:

```sh
./scripts/run-tests.sh tests/unit/command_router_spec.lua
./scripts/run-tests.sh tests/unit/scheduler_spec.lua
```

Both regressions first observed:

```text
expected "{\"findings\":[]}", got "{\"findings\":{}}"
```

Detachment now validates through canonical JSON encode/decode, preserving empty arrays. The mutable shared `json.null` sentinel is explicitly rejected instead of silently changing it to an object or returning shared state.

### Reentrant scheduler cancellation RED → GREEN

Command:

```sh
./scripts/run-tests.sh tests/unit/scheduler_spec.lua
```

The first regressions observed `timer_pending=true` after a probe or schedule callback reentrantly called `cancel()`. State/generation guards now re-check every injected-call return, prevent post-terminal scheduling, and cancel a timer token returned after a reentrant terminal transition.

### Returned cancellation error RED → GREEN

Command:

```sh
./scripts/run-tests.sh tests/unit/scheduler_spec.lua
```

The regression first observed `expected "FAILED", got "CANCELLED"` when the cancel adapter returned an error rather than throwing. Both thrown and returned callback errors now fail closed with sanitized `SCHEDULER_CALLBACK_FAILED` status.

### Deferred terminal delivery RED → GREEN

Command:

```sh
./scripts/run-tests.sh tests/unit/scheduler_spec.lua
```

The cleanup-failure regression first observed `expected "FAILED", got "CANCELLED"` in the terminal callback. Nested delivery scopes now defer terminal notification until probe/schedule/cancel callbacks and returned-token cleanup are complete. Final status and the exactly-once terminal callback both report `FAILED`, with no pending timer.

An independent read-only re-review reran the prior reproductions and found the final scheduler clean: deferral depth is balanced on every exit, final status and callback state agree, and no timer survives a terminal outcome.

## Final verification

Focused Task 7 suite:

```sh
./scripts/run-tests.sh tests/unit/command_router_spec.lua tests/unit/scheduler_spec.lua tests/unit/platform_preflight_spec.lua
```

Exit status: `0`; `33` tests passed with `0` failures.

Repository default full suite:

```sh
./scripts/run-tests.sh
```

Exit status: `0`; `161` current unit and integration tests passed with `0` failures. This run included concurrent Task 6 approval/logger files present in the shared workspace; the immutable Task 7 focused evidence is the `33` tests above. An earlier pre-concurrency full run also passed all then-present `148` tests.

Lua 5.4 syntax verification:

```sh
third_party/lua-5.4.8/src/luac -p CrossplayGuildChestExpander/Scripts/command_router.lua CrossplayGuildChestExpander/Scripts/scheduler.lua CrossplayGuildChestExpander/Scripts/platform_preflight.lua tests/unit/command_router_spec.lua tests/unit/scheduler_spec.lua tests/unit/platform_preflight_spec.lua
```

Exit status: `0`.

Staged whitespace review before the implementation commit:

```sh
git diff --cached --check
```

Exit status: `0`.

Manual merge smoke verification exercised empty tuples, surrounding spaces, nested/escaped values, existing known keys, and full assignment/RHS forms; all five samples were byte-idempotent on a second merge.

## Self-review

- Re-read Task 7, PRD §§3.1, 10.2, 10.10, 13.5, 14, and 17.5 against all six changed implementation/test files.
- `command_router.new` copies exactly five named functions into private storage. Unknown/malformed/apply inputs call no port; `apply` never consults status, mode, token, target, or state.
- Command parsing uses exact string matching only. It does not trim, split a shell line, interpret quoting, expand variables, or execute external input.
- Successful command payloads round-trip through the deterministic JSON module, detach from port-owned state, preserve empty arrays, reject cycles/non-finite/invalid values, and never expose port exceptions.
- The scheduler copies injected callbacks before starting, probes immediately, permits at most one timer, guards each callback generation, and invalidates late callbacks. A synchronous fake cannot recur past the bound.
- Terminal delivery is delayed across nested injected operations so cleanup determines the final state before the single `on_terminal` call. Callback details are never copied into errors.
- Cache fallback returns `SKIP` only for a completed cache whose revision, target, fingerprint, and owner exactly match. Startup always returns `INSPECT`, even for that exact cache.
- The preflight parser tracks quote, escape, and parenthesis state. Only top-level commas and equals signs delimit entries; duplicate CLI/INI keys and malformed values fail closed.
- Reports contain normalized booleans, validated port numbers, known platform evidence, and fixed diagnostics only. Raw argv, full `OptionSettings`, passwords, public IP strings, malformed values, and callback errors are never copied into diagnostics.
- `CrossplayPlatforms` recognizes only `Steam`, `Xbox`, `PS5`, and `Mac`; required release evidence is Steam/PS5/Mac, while Xbox remains optional.
- `AllowConnectPlatform` and `IsServer` are parsed only as unrelated preserved settings and never satisfy any connectivity check.
- A green preflight remains `diagnostic_only=true` and `certification="UNPROVEN"`; it cannot substitute for Gate B community-list, join, UI, persistence, or real-device evidence.
- `merge_option_settings` accepts no filesystem port, edits only four known value spans, preserves all unrelated bytes, appends missing keys in fixed order, preserves/adds Xbox only by policy, rejects unknown platform values, and is byte-idempotent.
- Static surface review found no filesystem, shell, UE4SS, game-thread, write, resize, append, dirty, replication, or apply export in the three production modules.

## Commit

- `cd6827b` — `feat: add discovery commands and preflight`

## Concerns and deferred evidence

- Connectivity preflight proves configuration shape only. It does not prove firewall/NAT reachability, PS5 Community Server visibility, PS5 join, macOS join, vanilla-client UI behavior, persistence, or cross-client concurrency; those remain Gate B evidence.
- `scheduler.retry` is engine-independent and tested only with injected fakes. Task 8 must bind it to verified read-only world-ready callbacks without widening the adapter surface.
- Cache decisions are advisory scheduling outcomes. Startup live inspection remains authoritative, and later ledger/report code must not reinterpret `SKIP` as certification or mutation authority.
- The shared JSON null sentinel is rejected in detached command/scheduler results because returning it would share mutable global state. Callers must omit optional values or use an explicit domain representation.
- No generalized LLM Wiki capture was warranted; this work implements project-specific contracts already captured in the PRD and implementation plan.
