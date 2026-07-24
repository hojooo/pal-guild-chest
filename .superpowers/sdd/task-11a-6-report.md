# Task 11A.6 RED Contract/Files Recovery Slice Report

## Scope and status

This is the Task 11A.6 Step 1 RED-only Contract/Files slice. It adds the
recovery authority tests before any Task 11A.6 production implementation.
No production module, restore entry point, plan/spec, package, harness, or
user-owned `.superpowers/sdd/progress.md` file was modified.

## Added Contract coverage

- `shared inventory tree digest freezes framing ordering and strict entries`
- `recovery intent accepts only the exact source preimage and fixed step schema`
- `recovery state inactivity matches Runtime over process PID and port fixtures`
- `recovery probe completion matches Runtime over journal and terminal fixtures`
- `recovery state writers reject state-only and sentinel-only manual barriers`
- `recovery blocker owns exact ACTIVE and BLOCKED revision-plus-two deltas`
- `recovery completion requires exact 000 010 020 999 authority`

The digest test freezes the `CGCE-TREE-1` vector
`412f6bcca9f94ba03373a6180ba1749034ab11912708a725605af2b32bc06c6b`,
strictly sorted entries, duplicate rejection, and exact entry fields. The
recovery tests assert persisted state bytes, return matrices, and filesystem
bytes rather than source-text implementation details. The inactivity case uses
an actual renamed `cmd.exe` server-path process plus a loopback listener; it
does not add a production test hook.

## Added Files coverage

- `recovery matrix freezes the exact phase case and two-step contract`
- `recovery matrix resumes only intent-bound before or after states`
- `recovery matrix rejects foreign quarantine without mutation`

The module export contract now also reserves `Assert-CgceRecoveryMatrix`.

## RED verification

Portable focused command:

```text
./scripts/run-tests.sh tests/integration/discovery_handoff_spec.lua
```

Result: the runner reported the intended new RED failure while the five
pre-existing handoff checks passed:

```text
FAIL defines Task 6 fixed-purpose recovery exports and restore entry point
tests/integration/discovery_handoff_spec.lua:334: expected true, got false
```

The failure is expected: Contract does not yet export
`Get-CgceInventoryTreeSha256`, `Write-CgceRecoveryRunState`,
`Block-CgceRecoveryRunState`, or `Complete-CgceRecoveryRunState`, and the
Restore entry point does not yet exist.

Windows behavior gate command (attempted exactly as required):

```text
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\windows\Run-CgceDiscoveryTests.ps1
```

Result: exit `127` / unavailable on this macOS host.

```text
zsh: command not found: powershell.exe
```

This does not claim behavioral execution. An elevated Windows PowerShell 5.1
run remains required after the Task 11A.6 production implementation.

## Files changed

- `tests/windows/Contract.Tests.ps1`
- `tests/windows/Files.Tests.ps1`
- `tests/integration/discovery_handoff_spec.lua`
- `.superpowers/sdd/task-11a-6-report.md`

## Self-review

- Verified scope excludes all production and user-owned progress files.
- Confirmed every required Contract and Files test name is present.
- Confirmed tests target observable state, filesystem, digest, and returned
  matrix behavior, with no new production test seam.
- The portable RED assertion fails specifically because the planned public
  exports are absent; Windows test execution is intentionally not represented
  as a pass.

## Review correction

The first RED fixture set was rejected in review because several cases could
fail vacuously before reaching their claimed authority. The following
corrections supersede the earlier fixture description:

- Contract deliberately imports Files and Runtime before invoking their
  public parity surfaces; missing Task 6 production remains the only intended
  command-not-found RED.
- Recovery fixtures now keep a pristine `CREATED/ACTIVE` genesis and write a
  distinct current source state. Original inventory checksums and tree digests
  come from the actual strict inventory bytes and live original tree.
- Initial recovery CAS coverage now spans all seven source phases under both
  `ACTIVE` and `BLOCKED`, asserting exact source bindings, `N+1`, output-free
  behavior, and byte/value-preserved outcome, errors, and evidence.
- The Files matrix covers all nine allowed phase/case rows and all twelve
  disallowed pairs. Every allowed row asserts both complete steps, exact paths,
  operations, sequences, and all five artifact-state fields.
- Resume coverage uses a complete intent identity, valid receipt prefix, and
  exact artifact objects at before-010, after-010, before-020, after-020, and
  completed-020 boundaries. An already-active original is accepted only with
  that bound intent and prefix, never as a fresh matrix choice.
- Runtime/Contract inactivity parity uses a complete partial launch/PID chain
  containing a durable unlisted PID, a real bounded-readiness process fixture,
  and a separately reserved ephemeral listener port. Both allow and block
  verdicts are compared and every rejection preserves state bytes.
- Probe-completion parity invokes the future read-only Runtime validator and
  Contract completion against matching absent-probe allow and residue-block
  fixtures.
- Manual state and schema-valid sentinel barriers each exercise initial CAS,
  blocker, and completion. The state-only intent is created after the manual
  error exists, and the sentinel is validated against Runtime's exact schema.
- Blocker success asserts exact prior errors/evidence, one exact append,
  `N+2`, and no success output. Rejections cover invalid/LF/CRLF codes,
  pre-CAS, already-`N+2`, stale revision, changed evidence/errors, and
  missing/mismatched intent with byte preservation.
- Completion now has a fully valid `000/010/020/999` positive journal reaching
  `RESTORED`, plus missing, gap, foreign-child, and tampered-chain negatives.
  An always-throw completion implementation cannot satisfy the positive case.

Corrected portable RED command:

```text
./scripts/run-tests.sh tests/integration/discovery_handoff_spec.lua
```

The portable contract is now split into two independently actionable failures:

```text
FAIL defines Task 6 Contract and Files public recovery surfaces
tests/integration/discovery_handoff_spec.lua:334: expected true, got false

FAIL defines the Task 6 restore entry point surface
tests/integration/discovery_handoff_spec.lua:5: tools/windows-discovery/Restore-CgceProduction.ps1: No such file or directory
```

The five pre-existing portable handoff cases still pass. The Windows command
was attempted again after correction; the availability limitation recorded
above is unchanged, so no behavioral Windows result is claimed.

## Final review closure

A second static gate found five remaining ways an incomplete validator could
pass. The RED slice now closes them:

- Intent rejection uses fresh fixtures for source phase/outcome/revision/time/
  errors, source-state checksum, genesis/original inventory/tree authority,
  selected case, paths, and exact intent/step/artifact key drift.
- A whole-state comparator checks every source field across initial, blocked,
  and completed writers while allowing only the specified phase, revision,
  timestamp, append-only error, and restored-checksum deltas.
- Probe parity now includes a real non-null public Runtime stage and complete
  `010..090/999` probe restore journal. Both Runtime and Contract must allow
  that authority and return the same stable rejection for a one-change inner
  journal tamper or terminal filesystem tamper.
- Files resume rejection now covers a missing `010` prefix, wrong previous
  checksum, foreign child, intent path/case/artifact drift, already-active
  state without intent, and ambiguous live state. Every case compares a full
  recursive file/directory snapshot before and after rejection.
- Every production completion negative starts from a valid
  `000/010/020/999` authority and applies one missing, gap, foreign-child, or
  semantic-tamper perturbation, then proves the complete fixture tree remains
  byte-for-byte unchanged after rejection.

The non-null probe fixture deliberately uses the public Runtime enable/restore
APIs rather than handwritten probe receipts. Its PowerShell 5.1 behavior still
requires the unavailable Windows gate; the portable result cannot validate
Windows process, filesystem, or module semantics.

## RED slice B: Runtime/Lifecycle recovery tests

This append adds only the Task 11A.6 Runtime and Lifecycle RED tests. No
production module, restore entry point, plan/spec, package, harness, portable
test, or user-owned `.superpowers/sdd/progress.md` file was modified.

### Added Runtime coverage

- `probe restored validator is read-only over absent and completed authorities`
- `probe restore rechecks inactivity before every mutation`
- `probe restore manual barriers prevent the next move or receipt`

The new validator test reserves the exact output-free public API and checks
absent authority, a completed source-bound restore journal, semantic receipt
tampering, and terminal residue without allowing any repair. Its snapshots
include the run state, genesis, markers, process/probe receipt trees, staged
and quarantined probe artifacts, before images, and output artifacts.

The mutation-guard tests freeze the unchanged public restore parameter set;
they inject a state-bound executable process, TCP listener, or UDP listener
through only the Runtime module-private test seams immediately before restore
root creation, intent publication, each cleanup operation/receipt, and the
final receipt. The tests compare the exact captured filesystem/authority state
at each injection point.

The manual-barrier fixtures construct a state/genesis/active-marker authority
with the state-bound executable and listener port. They separately install a
persisted `CGCE-OPS-MANUAL-RECOVERY` state error or a schema-valid,
`000-launch.json`-bound process sentinel. Each is asserted at next move, next
receipt, resume, and completed paths with no subsequent write.

### Added Lifecycle coverage

- `restore bootstrap rejects oversized genesis and manifest before import`
- `restore bootstrap rejects a wrong-origin preloaded handoff module`
- `restore bootstrap accepts relocated byte-identical handoff`
- `restore bootstrap rejects either-direction handoff RunRoot overlap`
- `restore bootstrap rejects a re-signed module tree with no side effect`
- `restore returns the exact original and quarantines the clone`
- `restore resumes every intent operation inventory state and marker boundary`
- `completed marker uses the read-only probe validator and performs no repair`
- `restore completed-marker replay emits one terminal line and writes nothing`

Lifecycle tests use the existing synthetic prepare/invoke child fixture only;
they do not invoke a real Palworld server, save, or firewall. They reserve
`RestoreScript` and `RepositoryRestoreScript` fixture properties and require
one stdout terminal line, empty stderr, and exact exit `0` or `1`. The success
case freezes the restored original, clone quarantine, inactive-original
absence, backup preservation, marker completion, restored inventory, and the
four restore-journal leaves. Crash cases enumerate the required intent, CAS,
010/020, inventory, final receipt, state, and marker boundaries.

### RED verification

Portable focused command:

```text
./scripts/run-tests.sh tests/integration/discovery_handoff_spec.lua
```

Result: the two existing Task 11A.6 portable RED surfaces remain deliberately
unimplemented; the five pre-existing handoff cases passed.

```text
FAIL defines Task 6 Contract and Files public recovery surfaces
FAIL defines the Task 6 restore entry point surface
PASS five existing Windows discovery handoff checks
```

Required Windows command (attempted exactly):

```text
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\windows\Run-CgceDiscoveryTests.ps1
```

Result: exit `127` on this macOS host:

```text
zsh:1: command not found: powershell.exe
```

`git diff --check` passed. This is not a Windows behavioral pass; an actual
Windows PowerShell 5.1 run is still required after the production slice.

### Static self-review

- Reviewed the changed tests for PowerShell 5.1 compatibility: no ternary,
  null-coalescing, null-conditional, class, or PowerShell 7-only syntax was
  introduced. Here-string replacement is assigned in two statements so the
  closing delimiter remains valid in Windows PowerShell 5.1.
- Runtime assertions are state/filesystem/terminal observable assertions, not
  mock-call assertions. The absent planned export causes the intended RED
  failure now; positive completed authority, semantic-negative authority, and
  no-write comparisons prevent an always-throw future implementation from
  satisfying the full test.
- Lifecycle child assertions distinguish terminal stdout, stderr, and exact
  exit status, and replay snapshots exclude test wrapper/stderr artifacts.
  The bootstrap, relocation, and re-signed-tree cases use copied handoff
  bytes and side-effect sentinels rather than a real server.

## RED slice B correction

Independent review found that the initial Lifecycle insertion was accidentally
placed inside an existing child-module here-string. The corrective commit moves
the helper/test block to the top-level suite and restores the pre-existing root
PID crash fixture. It also replaces the Runtime partial fixture with the
prepared inventory fixture, publishes the active marker from pristine genesis
before the staged current state, captures whole-fixture authority snapshots,
uses terminal filesystem residue, and distinguishes process from TCP/UDP
activity error codes. The earlier commit is superseded by this correction and
is not an approved RED gate.

Correction verification repeated the same portable focused command: the two
intended absent Task 11A.6 recovery surfaces still fail and the five existing
handoff checks pass. The required Windows command was retried and again exits
`127` because `powershell.exe` is unavailable on this macOS host. `git diff
--check` passes after the structural correction. These results remain RED/static
evidence only, not Windows behavioral execution.

### Fixture-order correction

Effective-code review found that the Runtime recovery fixture created the active
marker before writing the byte-identical pristine current state required by the
marker writer. The fixture now atomically writes the same `CREATED` state to
both genesis and current paths, asserts their checksums match, and only then
creates the marker before publishing its staged current state. Semantic final
receipt and terminal filesystem-residue validator negatives now assert their
exact stable codes. Root/intent mutation-barrier cases also compare the full
authority/filesystem snapshot before and after rejection.

Lifecycle correction adds strict restored-inventory read/compare and checksum
binding, a zero-output public probe-validator assertion after successful
restore, exact terminal-matrix manual-recovery rejection, and separate
operation move/receipt crash-cursor names with persisted phase, journal,
layout, inventory, and marker assertions before resume.

The Lifecycle snapshot now records both recursive directories and file bytes,
so empty-directory writes are visible. Bootstrap oversized and overlap cases
compare the entire authority snapshot, not only state bytes. Successful restore
compares the quarantined clone against the independently captured clone
inventory; crash cursors assert the expected persisted phase/revision as well
as receipt prefix, layout, inventory, and marker authority.

Final review correction: oversized bootstrap snapshots are captured only after
the deliberate attack/rebind, so they prove no subsequent repair. Relocated
handoff now receives the same restored-inventory, clone/backup, marker, and
read-only probe assertions as normal success. Crash layouts explicitly compare
active/quarantine/inactive inventories, and a separate ambiguous quarantine
layout is required to return `CGCE-OPS-MANUAL-RECOVERY` without a write.

Cursor rows now also strict-read restored inventory when present, bind its
checksum only after the `RESTORED` state transition, and assert `ACTIVE`/
error-free state plus the exact active or completed marker authority.
