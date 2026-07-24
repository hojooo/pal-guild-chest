# Crossplay Guild Chest Expander — Discovery Build

This package is a non-release, read-only discovery milestone for a Palworld
Windows Dedicated Server. It contains no resize, append, dirty, replication,
or other mutation implementation. Its production loader intentionally stops
with `CGCE-LOADER-COMPOSITION-UNAVAILABLE` until verified runtime ports exist.

`IsServer=true` controls where the official loader deploys the Lua files. It
does not prove network safety or compatibility with Steam Windows, PS5, or
Mac clients. Those three vanilla clients are required for the first release,
but all platform compatibility claims remain **BLOCKED** pending real-device
Gate B certification. Xbox is optional and must not be advertised without its
own evidence.

## Distribution status

- Version: `1.1.0-discovery`
- Release eligible: no
- Mutation capability: no
- `MinRevision=0`: permitted only for this clearly labeled Discovery Build
- Author/copyright holder and license: not selected; `Author=TBD` is a
  non-distribution placeholder
- Public Workshop upload: prohibited at this milestone

## Install for controlled discovery

1. Stop the Windows Dedicated Server.
2. Make an offline, restorable copy of the **entire world save directory** and
   verify that the copy can be read.
3. Install the required UE4SS package.
4. Place this package under the server Workshop root with `Info.json` directly
   below the item directory.
5. Add `ActiveModList=CrossplayGuildChestExpander` to
   `Mods/PalModSettings.ini`, leaving `bGlobalEnableMod=true`.
6. Keep `mode=audit`, `requested_target_slots=54`, and all safety flags enabled.
   The packaged `config/config.default.json` is reference material in this
   Discovery milestone; the sole official Lua target remains `./Scripts`.
7. Restart the server and confirm that the loader reports the intentional
   composition block. Do not interpret installation success as compatibility.

Supported read-only command contracts are `status`, `audit`, `guilds`,
`verify`, and `export-report` when trusted runtime dependencies are injected.
`apply` always returns `MUTATION_BUILD_UNAVAILABLE` in this build.

## Discovery and audit

Run discovery only on a backed-up, disposable or isolated test world. Preserve
the probe request, raw observation, canonical operational report, exact server
revision evidence, and linked implementation bytes under the ignored local
directory `private-artifacts/discovery/<revision>/`. Never commit raw guild,
world, player, or container identifiers. A successful probe is
non-authoritative; only the separate Gate A validator can issue a private,
checksum-bound acceptance receipt after human review.

## Update

Stop the server, make and verify a new whole-world backup, retain the previous
package and evidence, then replace the package. A changed game revision
invalidates the old runtime manifest and every compatibility claim. Restart in
audit/discovery mode only. Never reuse a manifest merely because symbol names
look similar.

## Disable and remove

Stop the server, back up the whole world, remove
`ActiveModList=CrossplayGuildChestExpander`, and restart. The Discovery Build
does not change slot arrays, so it has nothing to shrink or roll back. Future
mutation-capable releases must never auto-shrink an expanded chest; removal is
allowed only after the Steam Windows, PS5, and Mac vanilla removal test passes.

## Incident rollback

Stop interactions, do not force a normal save after a fatal invariant failure,
preserve logs and reports, stop the server, restore the verified official
backup, remove conflicting mods, and reproduce in audit-only mode. If a
verified no-save or immediate safe-stop path is unavailable, Gate A remains
blocked and no mutation build may be produced.

## Known limitations

- No real Palworld revision or runtime symbol manifest has been accepted.
- No save/reload, removal, performance, soak, or client-device test has run.
- Other storage or hook mods may conflict; pre-Gate-A collision coverage is
  partial and can never authorize apply.
- The official server loader currently supports server-side mods only on the
  Windows Dedicated Server. Mac in this project means the required vanilla
  macOS **client**, not a macOS server.

See `docs/windows-discovery-operator-runbook.md` for the Task 11A Windows
backup/clone/restore/private-export gates, `docs/discovery-runbook.md` for
Task 11B/Gate A evidence, and `docs/certification-runbook.md` for later client
certification procedures. Task 11A source implementation does not authorize a
real maintenance run until the elevated Windows PowerShell 5.1 synthetic suite
reports `failures=0`.
