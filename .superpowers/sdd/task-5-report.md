# Task 5 Report — Discovery-safe state machine and read-only audit engine

## Scope

- Added an explicit discovery-only state graph with terminal execution epochs and no apply-capable node or edge.
- Added the generic `audit_blocked` outcome required for later report/persistence/read-back failures to fail closed without being mislabeled as audit conflicts.
- Added a strict read-only audit context with exactly three ports: `list_guilds`, `resolve_guild_chest`, and `snapshot_container`.
- Added deterministic guild projection, relationship validation, filtering, duplicate detection, detached Task 4 snapshot validation, canonical unsigned checksums, and recursively read-only audit results.
- Added exported-surface and dynamic trap coverage proving the current discovery build exposes and accesses no write-capable adapter operation.
- Added no UE4SS integration, UObject write, container size change, dirty/replication request, game-thread callback, or Palworld symbol guess.

## TDD evidence

### Cycle 1 — Discovery state graph RED

Command:

```sh
./scripts/run-tests.sh tests/unit/state_machine_spec.lua
```

Exit status: `1`

Observed failure:

```text
FAIL tests/unit/state_machine_spec.lua
tests/unit/state_machine_spec.lua:2: module 'CrossplayGuildChestExpander.Scripts.state_machine' not found
```

The transition-table tests loaded before `state_machine.lua` existed.

### Cycle 1 — Discovery state graph GREEN

Command:

```sh
./scripts/run-tests.sh tests/unit/state_machine_spec.lua
```

Exit status: `0`

Result at the first green point: `11` state-machine tests passed. They covered direct/waiting paths, preflight and audit blockers, audit/apply-mode discovery outcomes, terminal epochs, invalid events/contexts, apply rejection from every state, strict constructor context, and unreachable mutating states.

### Additional dependency cycle — Generic audit blocker RED

Task 9 integration analysis established that post-audit validation, report persistence, and read-back failures need a generic blocker rather than the conflict-specific event.

Command:

```sh
./scripts/run-tests.sh tests/unit/state_machine_spec.lua
```

Exit status: `1`

Observed failure:

```text
FAIL blocks generic post-audit validation and persistence failures
tests/unit/state_machine_spec.lua:17: expected "BLOCKED", got "AUDIT"
```

### Additional dependency cycle — Generic audit blocker GREEN

Command:

```sh
./scripts/run-tests.sh tests/unit/state_machine_spec.lua
```

Exit status: `0`

Result: `12` state-machine tests passed after adding only `AUDIT + audit_blocked -> BLOCKED`. No mutation state or edge was added.

### Cycle 2 — Read-only audit RED

Command:

```sh
./scripts/run-tests.sh tests/integration/audit_spec.lua
```

Exit status: `1`

Observed failure:

```text
FAIL tests/integration/audit_spec.lua
tests/integration/audit_spec.lua:2: module 'CrossplayGuildChestExpander.Scripts.audit' not found
```

The audit contract tests loaded before `audit.lua` existed.

### Cycle 2 — Read-only audit GREEN

Command:

```sh
./scripts/run-tests.sh tests/integration/audit_spec.lua
```

Exit status: `0`

Result: `14` audit tests passed. Coverage includes all-guild sorted projection, exact filter semantics, duplicate IDs before filtering, owner mismatch, unresolved/non-guild references, uninitialized guilds, malformed projections, sanitized port failures, unknown/write-capable context rejection, write traps, `54 -> expand`, `358/400 -> noop`, deterministic unsigned checksums, and recursive read-only/detached views.

### Cycle 3 — Discovery surface RED

Command:

```sh
./scripts/run-tests.sh tests/integration/discovery_surface_spec.lua
```

Exit status: `1`

Observed failure:

```text
FAIL does not let callers inject a state or replace transition behavior
tests/integration/discovery_surface_spec.lua:70: expected false, got true
```

The initial machine stored its current state in a caller-writable table field, so external code could inject an arbitrary state despite the transition table being safe.

### Cycle 3 — Discovery surface GREEN

Command:

```sh
./scripts/run-tests.sh tests/integration/discovery_surface_spec.lua
```

Exit status: `0`

Result: `4` surface tests passed after moving state into a private weak-key store and making the returned machine proxy read-only. Raw field injection no longer changes the authoritative state. The same suite verifies current production exports, forbidden state identifiers, and write-capable audit traps.

## Final verification

Focused Task 5 unit test:

```sh
./scripts/run-tests.sh tests/unit/state_machine_spec.lua
```

Exit status: `0`; `12` tests passed.

Focused Task 5 integration tests:

```sh
./scripts/run-tests.sh tests/integration/audit_spec.lua tests/integration/discovery_surface_spec.lua
```

Exit status: `0`; `18` tests passed.

Repository default full suite:

```sh
./scripts/run-tests.sh
```

Exit status: `0`; `91` unit tests passed with `0` failures. The repository runner defaults to `tests/unit/*.lua`, so the Task 5 integration files were also run explicitly as shown above.

Staged whitespace review before the implementation commit:

```sh
git diff --cached --check
```

Exit status: `0`.

## Self-review

- Re-read Task 5, PRD §§9–13, FR-003–007, FR-010, FR-013, FR-016–017, AT-004–006, AT-014, and the Discovery Build completion criteria against the changed files.
- The state graph contains only `DISABLED`, `PREFLIGHT`, `WAITING`, `AUDIT`, `AUDIT_COMPLETE`, `AWAITING_APPROVAL`, `BLOCKED`, and `UNSUPPORTED`; `apply` always returns `CGCE-STATE-MUTATION-BUILD-UNAVAILABLE` without changing state.
- `audit_blocked` is a fail-closed discovery transition for later non-conflict failures and does not confer apply authority.
- Audit context values and every guild/resolution/snapshot projection are strict and copied; port-owned containers, unknown fields, functions, and raw object references never enter the report.
- Duplicate configured container IDs and all relationship/snapshot blockers are evaluated for every discovered guild before action filtering, so exclusions cannot hide a blocker.
- Missing configured IDs do not call either downstream port and remain non-blocking `not_initialized` records.
- The resolver is called only with a configured guild chest ID. There is no API for enumerating general containers, and the general-container fixture remains untouched.
- Checksum input is canonical unsigned JSON with no timestamp; the signed canonical JSON is cached before recursive proxy wrapping. `to_table` decodes a fresh detached copy from that cache.
- Underlying port exceptions and unknown context values are never copied into structured errors, reports, or canonical JSON.
- No implementation line guesses a Palworld class, property, function, or revision-specific symbol.

## Commits

- `4708257` — `feat: add read-only discovery audit`

## Concerns and deferred evidence

- Guild, resolved-container, and snapshot projections are synthetic contracts only. Exact Palworld traversal and field evidence remain Gate A discovery work and cannot be inferred from these tests.
- This task proves audit safety and identity relationships but cannot prove that a resolved runtime container is the actual normal guild chest without the real read-only adapter and Gate A evidence.
- The surface test enumerates all production modules present through Task 5. Later discovery-only tasks must extend the list when adding production modules through Task 10.
- No generalized LLM Wiki capture was warranted; this work implements project-specific safety contracts already captured in the PRD and implementation plan.
