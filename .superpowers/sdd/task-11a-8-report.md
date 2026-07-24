# Task 11A.8 Deterministic Handoff Report

## Scope

Task 8 adds a tracked-source verifier and deterministic macOS builder for the
Windows discovery handoff.

## RED

Command:

```text
./scripts/run-tests.sh tests/integration/discovery_handoff_spec.lua
```

Observed failure before builder/verifier source was added:

```text
FAIL builds only the exact tracked Windows handoff deterministically
scripts/verify-discovery-handoff.sh: No such file or directory
```

Final review added an archive-level ordinal manifest assertion. It reproduced
a second RED because the initial builder emitted the declaration order:

```text
FAIL builds only the exact tracked Windows handoff deterministically
expected true, got false
```

## GREEN

Command:

```text
./scripts/run-tests.sh tests/integration/discovery_handoff_spec.lua
```

Result:

```text
PASS Windows discovery handoff > builds only the exact tracked Windows handoff deterministically
```

The behavior test creates a temporary Git repository, commits the exact input
set, runs the verifier, builds two archives at different paths with the same
basename, compares ZIP and sidecar bytes, checks the exact archive entries, and
proves rogue DLL and dirty included-source rejection.

Implemented:

- exact tracked allowlist and symlink/unallowlisted-file rejection;
- operator-source remote-control and probe mutation-token rejection;
- deterministic sorted source manifest;
- fixed permissions and timestamps;
- path-independent SHA-256 sidecar;
- dirty included-source rejection before building.

## Remaining clean-source gate

The real worktree contains the current implementation changes, so the
tracked-clean verifier/build gate must be repeated after those included paths
are committed. The temporary clean-repository behavior test passed and does
not modify the project worktree.
