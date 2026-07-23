# Task 11A.3 Report

## Status

Code complete; Windows PowerShell 5.1 behavioral verification pending.

This slice adds only the isolated UE4SS inventory probe and Windows runtime
boundary. It does not modify a real server, firewall, service, watchdog,
scheduler, production Lua module, Gate A evidence, or game state.

## Contract resolution

The controller-approved runtime contract is now recorded in both the Task 3
implementation plan and authoritative stage design. It preserves the exact
41-key `Paths` schema and defines:

- Task 3-scoped fixed snapshot/probe/restore/process derived paths;
- immutable pre-launch `000-launch.json`, separate gapless `001..998` PID
  receipts, and `999-result.json`;
- exact JSON key sets, framed argument/path digests, tree digests, and no
  plaintext arguments;
- named `artifact_state` and `operation_pair_state` schemas;
- the normative selected-case × fixed-step restore matrix;
- receipt-aware executable allowlist count/digest matching; and
- the bounded ancestry-polling claim for actually observed descendants.

## RED / GREEN evidence

### RED authored first

`Runtime.Tests.ps1`, its exact runner entry, and the focused Lua handoff test
were authored before receipt-bearing runtime implementation.

Focused Lua RED:

```text
./scripts/run-tests.sh tests/integration/discovery_handoff_spec.lua
FAIL ... main.lua: No such file or directory
exit 1
```

Windows PowerShell 5.1 RED was attempted after the exact contract tests were
authored:

```text
powershell.exe -NoProfile -ExecutionPolicy Bypass -File '.\tests\windows\Run-CgceDiscoveryTests.ps1'
zsh:1: command not found: powershell.exe
exit 127
```

No macOS substitute is treated as Windows behavioral evidence.

### Available GREEN evidence

Focused Lua:

```text
./scripts/run-tests.sh tests/integration/discovery_handoff_spec.lua
PASS Windows discovery handoff > keeps the inventory probe isolated to the two UE4SS dumpers
exit 0
```

Full Lua:

```text
./scripts/run-tests.sh
lua_pass=433 lua_fail=0
exit 0
```

The Windows GREEN command was attempted after implementation and still returns
the environment limitation:

```text
powershell.exe -NoProfile -ExecutionPolicy Bypass -File '.\tests\windows\Run-CgceDiscoveryTests.ps1'
zsh:1: command not found: powershell.exe
exit 127
```

The suite contains 74 plain-PowerShell tests: Contract 22, Files 27, and
Runtime 25. No claim is made that they pass until the suite runs
under elevated Windows PowerShell 5.1.

### Failed-review correction wave

The review regressions were added before their production fixes. The RED
attempt was:

```text
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/windows/Run-CgceDiscoveryTests.ps1
zsh: command not found: powershell.exe
exit 127
```

The corrected implementation addresses every review finding:

1. An exactly empty validated process receipt directory is now the only
   receipt-aware first-launch exception; any child requires the full strict
   chain.
2. Missing probe intent returns only when all Task 3 run residue is absent.
   Completed restore journals are strictly parsed and rebound, and both
   pre-final and repeat-call paths revalidate the complete live
   active/original/quarantine terminal matrix.
3. `999-result.json`, when present, now binds the exact launch checksum,
   terminal PID checksum, ordered PID receipt array, and ordered observed
   process array. Launch, PID, and result scalar types, ranges, timestamps,
   canonical paths, counts, checksums, and timeout are fail-closed.
4. Probe intent, fixed path object, ordered snapshot bindings, snapshot
   schemas/inventories, every staging operation transition, and the final
   receipt bindings/checksums are validated against reconstructed normative
   authority rather than only their checksum chain.
5. Untouched layouts use `ORIGINAL_UNCHANGED` or
   `BEFORE_PRESENT_UNCHANGED`. The two `*_ALREADY_RESTORED` alternatives are
   accepted only from a validated restore journal and preserve its exact
   absent-or-test quarantine state.
6. A filtered CIM lookup that returns null now falls back to the immediately
   constructed `System.Diagnostics.Process` identity. A deterministic private
   seam covers the no-record path.
7. Empty executable and port validation tests now expect
   `CGCE-OPS-PROCESS-QUERY` and `CGCE-OPS-PORT-QUERY`, respectively.
8. Every injected staging operation, receipt, and final boundary after intent
   must restore exactly; the test no longer accepts manual recovery and its
   before-image assertions prove no overwrite.

### R2 failed-review correction wave

R2 regressions were also authored before production and plan changes. The
focused Lua test failed first because the Task 6 skeleton still conditioned
the restore call on probe-intent existence:

```text
./scripts/run-tests.sh tests/integration/discovery_handoff_spec.lua
FAIL requires Task 6 to invoke Task 3 restoration unconditionally
exit 1
```

The Windows RED attempt remained unavailable:

```text
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/windows/Run-CgceDiscoveryTests.ps1
zsh: command not found: powershell.exe
exit 127
```

The R2 correction addresses the six findings exactly:

1. Runtime integer validation now accepts strict-parser `Decimal` values only
   when they are integral and within the requested `Int64` bounds. CLR integer
   values remain supported; booleans, strings, fractions, and overflow values
   are rejected.
2. The Task 6 restore skeleton calls `Restore-CgceInventoryProbe`
   unconditionally after restoration checks begin. Only the helper may no-op,
   after it proves that no Task 3 residue exists.
3. Artifact and operation states now enforce exact key shape, Boolean/type
   identity, bounded integral lengths, lowercase checksums, and
   case-sensitive non-coercive comparison. Snapshot inventories reuse
   `Compare-CgceInventory` validation for path components, controls, colons,
   backslashes, sorting, and duplicates.
4. A completed process result requires 1–998 PID receipts, and receipt 001's
   executable must exactly match the launch executable. Zero-root and
   allowlisted-wrong-root journals fail closed.
5. Only a successful filtered CIM query returning null may use the immediate
   `System.Diagnostics.Process` fallback. Query exceptions and access failures
   now return `CGCE-OPS-PROCESS-QUERY`.
6. The uncontracted `BEFORE_PRESENT_UNCHANGED` case was removed. An exact
   active-before/original-absent/quarantine-absent stage-incomplete layout uses
   `BEFORE_PRESENT_ALREADY_RESTORED`; its quarantine-test alternative requires
   validated existing journal authority.

R2 GREEN evidence:

```text
./scripts/run-tests.sh tests/integration/discovery_handoff_spec.lua
PASS Windows discovery handoff > keeps the inventory probe isolated to the two UE4SS dumpers
PASS Windows discovery handoff > requires Task 6 to invoke Task 3 restoration unconditionally
exit 0

./scripts/run-tests.sh
433 passed, 0 failed
exit 0

./scripts/verify-package.sh discovery
DISCOVERY_PACKAGE_VERIFIED
exit 0
```

## Runtime coverage

The Task 3 runtime tests cover:

- exact six-function export surface, Common import, and exact runner list;
- forbidden/safe argument tokens, one-element arrays, and fixed framed digest
  vectors;
- fail-closed CIM/TCP/UDP queries, exact process images, listener ports,
  receipt-aware allowlist digest matching, and PID reuse identity;
- exact probe bytes, five snapshot shapes, intent/operation/final schemas,
  nested state-pair keys, paths, checksums, and chains;
- crashes around each staging operation/receipt/final boundary;
- crashes around each restore operation/receipt/final boundary followed by
  prefix validation and idempotent resume;
- tampered frozen plan, operation, source path, and before-state rejection;
- empty first-launch journals, strict completed process-result bindings,
  deleted PID receipts, and scalar type tampering;
- missing-intent residue, semantically re-signed stage receipts, tampered
  restore finals, and post-final live-state drift;
- untouched versus journal-authorized already-restored alternatives,
  including exact absent and retained-test quarantine states;
- null filtered-CIM fallback for an extremely short-lived root process;
- strict-parser Decimal integer acceptance with fractional, string, Boolean,
  and overflow rejection;
- artifact-state coercion/checksum-case rejection and invalid inventory path
  rejection;
- completed-result zero-root and allowlisted-wrong-root rejection;
- distinct filtered-CIM null and exception behavior;
- ambiguous layout and unrelated quarantine preservation;
- active/preserved foreign artifact blocking; and
- synthetic child launch intent/root PID/result receipts, non-zero exit,
  argument non-disclosure, checksums, and replay blocking.

## Static verification

- `python3 -m json.tool`/equivalent JSON parsing on both existing Windows
  schemas: exit 0; no schema changed in either correction wave.
- `git diff --check`: exit 0.
- Runtime/test delimiter audit: parentheses, braces, and brackets balanced.
- Runtime export audit: exact six approved functions.
- Forbidden operator scan: no firewall/service/watchdog mutation, deletion,
  dynamic evaluation, `ConvertFrom-Json`, or game mutation surface.
- Probe exact-source test: only local control flow, `pcall`, `print`,
  `DumpAllObjects()`, and `GenerateSDK()`.
- Existing `New-CgceRunPaths` exact 41-key contract remains unchanged.

## Self-review

- Re-read the Task 3 brief, approved interfaces, authoritative stage design,
  downstream Task 5 process wording, and final controller contract sections
  for derived paths, restoration matrix, activity preflight, and acceptance.
- Confirmed snapshots precede intent and all production-path staging operations
  are no-overwrite, same-volume, receipt-chained, and crash-injected.
- Confirmed restore validates the longest staging and restoration prefixes,
  frozen plan shape/order/stage bindings, exact operation/path/state matrix,
  and only continues from the exact expected before or after state. A complete
  prefix cannot bypass final-receipt or live terminal-state validation.
- Confirmed a missing stage intent cannot suppress recovery when a run journal,
  snapshot, original, quarantine, staged probe, or probe-enable line remains.
- Confirmed completed process results cannot survive deletion, reordering, or
  mutation of their exact PID receipt chain.
- Confirmed all six R2 findings against the final diff: Decimal receipt
  numbers, unconditional downstream restoration, strict artifact/inventory
  authority, nonempty root process evidence, null-only CIM fallback, and the
  unchanged documented restore-case list.
- Confirmed `Enable-CgceInventoryProbe` is the only probe-final writer and
  returns only its exact path/checksum.
- Confirmed launch intent is immutable and contains only argument count/digest;
  PID identity uses path plus UTC creation file time.
- Confirmed process timeout never kills, restores, restarts, or writes a
  success result.
- Confirmed no Task 4+ lifecycle entry point, capture/export payload, or
  production CGCE Lua module was added.

## Residual gates and concerns

Windows PowerShell 5.1 syntax, provider, CIM, `Start-Process`, robocopy,
one-element JSON, process creation-time, and no-overwrite filesystem semantics
remain unexecuted on this macOS host. The unchanged 64-test suite must report
`failures=0` on Windows before any synthetic or real operator use.

The process tracker polls `Win32_Process.ParentProcessId`. It enforces the
allowlist for every descendant it actually observes, but cannot prove complete
history for an extremely short-lived descendant that starts and exits between
polls. That limitation is explicit in the approved plan/spec; stronger
containment would require a native Job Object or durable process-start event
mechanism outside Task 11A.3.

No real Palworld server, listener, save, credential, or private evidence was
used. The pre-existing untracked `.superpowers/sdd/progress.md` remains
untouched and is excluded from the commit.
