# CGCE Repository Instructions

## Project Context

- This repository implements Crossplay Guild Chest Expander, a Windows-only Palworld Dedicated Server mod for vanilla Steam Windows, PS5, and macOS clients.
- Runtime code targets Lua 5.4 and UE4SS v3.0.1 until a later release is explicitly selected and revalidated.
- `PRD-Crossplay-Guild-Chest-Expander-Windows-PS5-v1.1.md` defines product behavior. `docs/superpowers/plans/2026-07-22-cgce-implementation.md` defines implementation order and gates.

## Architecture Rules

- Keep game-independent logic in small pure-Lua modules under `CrossplayGuildChestExpander/Scripts/` and inject UE4SS behavior through adapters.
- Tasks 1–10 are discovery-only. Do not add any UObject write, resize, append, dirty, replication, or apply transition before a checksum-bound Gate A acceptance artifact exists.
- Never guess or fuzzy-match Palworld class, property, or function names. Unsupported revisions and ambiguous bindings fail closed.
- The release package must be server-only. Do not add client scripts, PAKs, DLLs, custom RPCs, UI assets, or input bindings.
- Treat live save/container state as authoritative; ledger and cache data may not suppress startup live-state verification.

## Coding Conventions

- Use Lua 5.4 syntax supported by the vendored test runtime. Avoid implementation-specific extensions.
- Modules return one explicit table. Keep filesystem, clock, UE4SS globals, and mutation operations behind injected interfaces.
- JSON used for checksums must be canonical and deterministic. Security and validation failures use stable machine-readable error codes.

## Testing And Verification

- Build the test runtime once with `make -C third_party/lua-5.4.8 all`.
- Run the full suite with `./scripts/run-tests.sh`.
- Run one test file with `./scripts/run-tests.sh tests/unit/<name>_spec.lua`.
- New behavior follows RED → GREEN. Record both commands and results in the active `.superpowers/sdd/task-<N>-report.md`.
- `third_party/lua-5.4.8` is test tooling only and must never enter a CGCE release archive.

## Security And Data Rules

- Never commit real Palworld saves, credentials, administrator passwords, approval tokens, or player identifiers.
- Bind approvals to world ID, exact revision, fresh audit checksum, target slots, and deployment profile.
- Any post-mutation invariant failure is terminal and requires a verified no-save/safe-stop capability plus backup restoration guidance.

## Ask The Developer

- Ask before selecting the project license or copyright holder.
- Ask before accepting a different UE4SS release, weakening a Gate A/B requirement, or changing required client platforms.
- Exact Palworld symbols must come from a real read-only Discovery Build report, never developer memory or internet guesses.

## Known Traps

- `MinRevision` is a minimum-version filter, not exact revision binding.
- `IsServer=true` controls deployment target; it does not prove vanilla-client or network compatibility.
- `ExecuteInGameThread` queues asynchronously. Mutation and immediate post-validation must share one callback.
- UE4SS `TArray` access alone does not prove safe append, slot construction, persistence, or replication.
