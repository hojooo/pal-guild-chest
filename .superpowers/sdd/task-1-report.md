# Task 1 Report — Repository bootstrap and executable Lua test harness

## Scope completed

- Vendored the official Lua 5.4.8 source distribution at `third_party/lua-5.4.8/`.
- Verified the downloaded archive before extraction:

  ```text
  4f18ddae154e793e46eeab727c59ef1c0c2b744e7b94219710d76f530629ae  /private/tmp/lua-5.4.8.tar.gz
  ```

- Built the local, test-only runtime with `make -C third_party/lua-5.4.8 all`.
- Added the executable Lua test runner and assertion helpers.
- Added a self-test covering equality, expected errors, and the declared deep-equality interface.
- Documented third-party provenance, checksum, build command, and the rule that Lua is excluded from the CGCE release package.

## Files

| Path | Purpose |
|---|---|
| `.gitignore` | Ignores only locally built Lua test-runtime artifacts. |
| `third_party/lua-5.4.8/**` | Official, checksum-verified Lua 5.4.8 source distribution. |
| `third_party/README.md` | Lua provenance, SHA-256, build instructions, and test-only/release-exclusion statement. |
| `tests/run.lua` | Minimal global `describe` / `it` runner with non-zero failure exit. |
| `tests/support/assertions.lua` | `equal`, `deep_equal`, and `raises` assertions. |
| `tests/unit/test_harness_spec.lua` | Harness self-test. |
| `scripts/run-tests.sh` | Repository-root runner using `third_party/lua-5.4.8/src/lua`. |
| `.superpowers/sdd/task-1-report.md` | This TDD and verification record. |

## RED

Command:

```sh
./scripts/run-tests.sh tests/unit/test_harness_spec.lua
```

Exit status: `127`

Output:

```text
zsh:1: no such file or directory: ./scripts/run-tests.sh
```

This is the expected pre-implementation failure: the test runner did not yet exist.

## GREEN

Focused command:

```sh
./scripts/run-tests.sh tests/unit/test_harness_spec.lua
```

Exit status: `0`

Output:

```text
PASS test harness > supports equality and expected errors
PASS test harness assertions > supports deep equality
```

Full-suite command:

```sh
./scripts/run-tests.sh
```

Exit status: `0`

Output:

```text
PASS test harness > supports equality and expected errors
PASS test harness assertions > supports deep equality
```

Runtime rebuild check:

```sh
make -C third_party/lua-5.4.8 all
```

Exit status: `0` (`Nothing to be done for 'all'.` after the initial successful build.)

## Self-review

- The test was created and observed failing before the runner or assertions were created.
- `tests/run.lua` loads explicit files or the unit-test glob, prints passing suite/test paths, records failures, and exits non-zero on any failed load or test.
- `assertions.equal`, `assertions.deep_equal`, and `assertions.raises` are all exposed from the required module path.
- The shell entrypoint always executes the repository-pinned Lua binary and gives an actionable error if that runtime has not been built.
- The vendored source is from the required official archive and its archive digest matches the required SHA-256 exactly.
- Only build products (`*.o`, `*.a`, `lua`, and `luac`) are ignored; the Lua source tree remains vendored and trackable.
- No external test framework or unrelated dependency was added.

## Commit

Pending at report creation; updated after commit.

## Concerns

- `CrossplayGuildChestExpander/LICENSE` is intentionally omitted. The brief requires the file but does not specify a license or copyright holder; choosing either would be a legal/package-policy decision outside this task. Add it after the owner approves the license text.
- The third-party README establishes the release-exclusion policy. The later release-packaging task must enforce that policy mechanically when `build-release.sh` is introduced.
