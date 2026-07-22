# Task 2 Report — Strict JSON and SHA-256 primitives

## Files

| Path | Purpose |
|---|---|
| `CrossplayGuildChestExpander/Scripts/json.lua` | Strict recursive-descent JSON codec with canonical object-key ordering and `json.null`. |
| `CrossplayGuildChestExpander/Scripts/sha256.lua` | Pure Lua 5.4 bitwise SHA-256 implementation exposing lowercase hexadecimal output. |
| `tests/unit/json_spec.lua` | JSON decode/encode and rejection behavior coverage. |
| `tests/unit/sha256_spec.lua` | SHA-256 NIST-vector coverage. |

## TDD evidence

### JSON RED

Command:

```sh
./scripts/run-tests.sh tests/unit/json_spec.lua
```

Exit status: `1`

Output:

```text
FAIL tests/unit/json_spec.lua
tests/unit/json_spec.lua:2: module 'CrossplayGuildChestExpander.Scripts.json' not found:
	no field package.preload['CrossplayGuildChestExpander.Scripts.json']
	no file './CrossplayGuildChestExpander/Scripts/json.lua'
	no file './CrossplayGuildChestExpander/Scripts/json/init.lua'
	no file '/usr/local/share/lua/5.4/CrossplayGuildChestExpander/Scripts/json.lua'
	no file '/usr/local/share/lua/5.4/CrossplayGuildChestExpander/Scripts/json/init.lua'
	no file '/usr/local/lib/lua/5.4/CrossplayGuildChestExpander/Scripts/json.lua'
	no file '/usr/local/lib/lua/5.4/CrossplayGuildChestExpander/Scripts/json/init.lua'
	no file './CrossplayGuildChestExpander/Scripts/json.lua'
	no file './CrossplayGuildChestExpander/Scripts/json/init.lua'
	no file '/usr/local/lib/lua/5.4/CrossplayGuildChestExpander/Scripts/json.so'
	no file '/usr/local/lib/lua/5.4/loadall.so'
	no file './CrossplayGuildChestExpander/Scripts/json.so'
	no file '/usr/local/lib/lua/5.4/CrossplayGuildChestExpander.so'
	no file '/usr/local/lib/lua/5.4/loadall.so'
	no file './CrossplayGuildChestExpander.so'
stack traceback:
	[C]: in function 'require'
	tests/unit/json_spec.lua:2: in main chunk
	[C]: in function 'xpcall'
	tests/run.lua:38: in main chunk
	[C]: in ?
```

### JSON GREEN

Command:

```sh
./scripts/run-tests.sh tests/unit/json_spec.lua
```

Exit status: `0`

Output:

```text
PASS json.decode > decodes nested objects and arrays
PASS json.decode > decodes JSON string escapes and Unicode escapes
PASS json.decode > decodes JSON numbers
PASS json.decode > decodes booleans and preserves null with its sentinel
PASS json.decode > rejects duplicate object keys
PASS json.decode > rejects trailing input
PASS json.decode > rejects non-finite decoded numbers
PASS json.encode > encodes objects with deterministic lexicographic key ordering
PASS json.encode > encodes null with its explicit sentinel
PASS json.encode > rejects non-finite numbers
PASS json.encode > rejects cyclic tables
```

### Empty-array regression RED/GREEN

The initial implementation represented a Lua empty table as a JSON object. A regression test was added to preserve the shape of a decoded empty JSON array.

RED command:

```sh
./scripts/run-tests.sh tests/unit/json_spec.lua
```

Exit status: `1`

Output:

```text
FAIL retains an empty array decoded from JSON
tests/unit/json_spec.lua:59: expected "[]", got "{}"
stack traceback:
	[C]: in function 'error'
	./tests/support/assertions.lua:13: in function 'tests.support.assertions.equal'
	tests/unit/json_spec.lua:59: in function <tests/unit/json_spec.lua:58>
	[C]: in function 'xpcall'
	tests/run.lua:20: in function 'it'
	tests/unit/json_spec.lua:58: in function <tests/unit/json_spec.lua:49>
	[C]: in function 'xpcall'
	tests/run.lua:12: in function 'describe'
	tests/unit/json_spec.lua:49: in main chunk
	[C]: in function 'xpcall'
	tests/run.lua:38: in main chunk
	[C]: in ?
PASS json.decode > decodes nested objects and arrays
PASS json.decode > decodes JSON string escapes and Unicode escapes
PASS json.decode > decodes JSON numbers
PASS json.decode > decodes booleans and preserves null with its sentinel
PASS json.decode > rejects duplicate object keys
PASS json.decode > rejects trailing input
PASS json.decode > rejects non-finite decoded numbers
PASS json.encode > encodes objects with deterministic lexicographic key ordering
PASS json.encode > encodes null with its explicit sentinel
PASS json.encode > rejects non-finite numbers
PASS json.encode > rejects cyclic tables
```

GREEN command:

```sh
./scripts/run-tests.sh tests/unit/json_spec.lua
```

Exit status: `0`

Output:

```text
PASS json.decode > decodes nested objects and arrays
PASS json.decode > decodes JSON string escapes and Unicode escapes
PASS json.decode > decodes JSON numbers
PASS json.decode > decodes booleans and preserves null with its sentinel
PASS json.decode > rejects duplicate object keys
PASS json.decode > rejects trailing input
PASS json.decode > rejects non-finite decoded numbers
PASS json.encode > encodes objects with deterministic lexicographic key ordering
PASS json.encode > encodes null with its explicit sentinel
PASS json.encode > retains an empty array decoded from JSON
PASS json.encode > rejects non-finite numbers
PASS json.encode > rejects cyclic tables
```

### SHA-256 RED

Command:

```sh
./scripts/run-tests.sh tests/unit/sha256_spec.lua
```

Exit status: `1`

Output:

```text
FAIL tests/unit/sha256_spec.lua
tests/unit/sha256_spec.lua:2: module 'CrossplayGuildChestExpander.Scripts.sha256' not found:
	no field package.preload['CrossplayGuildChestExpander.Scripts.sha256']
	no file './CrossplayGuildChestExpander/Scripts/sha256.lua'
	no file './CrossplayGuildChestExpander/Scripts/sha256/init.lua'
	no file '/usr/local/share/lua/5.4/CrossplayGuildChestExpander/Scripts/sha256.lua'
	no file '/usr/local/share/lua/5.4/CrossplayGuildChestExpander/Scripts/sha256/init.lua'
	no file '/usr/local/lib/lua/5.4/CrossplayGuildChestExpander/Scripts/sha256.lua'
	no file '/usr/local/lib/lua/5.4/CrossplayGuildChestExpander/Scripts/sha256/init.lua'
	no file './CrossplayGuildChestExpander/Scripts/sha256.lua'
	no file './CrossplayGuildChestExpander/Scripts/sha256/init.lua'
	no file '/usr/local/lib/lua/5.4/CrossplayGuildChestExpander/Scripts/sha256.so'
	no file '/usr/local/lib/lua/5.4/loadall.so'
	no file './CrossplayGuildChestExpander/Scripts/sha256.so'
	no file '/usr/local/lib/lua/5.4/CrossplayGuildChestExpander.so'
	no file '/usr/local/lib/lua/5.4/loadall.so'
	no file './CrossplayGuildChestExpander.so'
stack traceback:
	[C]: in function 'require'
	tests/unit/sha256_spec.lua:2: in main chunk
	[C]: in function 'xpcall'
	tests/run.lua:38: in main chunk
	[C]: in ?
```

### SHA-256 GREEN

Command:

```sh
./scripts/run-tests.sh tests/unit/sha256_spec.lua
```

Exit status: `0`

Output:

```text
PASS sha256.hex > matches the empty-string NIST test vector
PASS sha256.hex > matches the abc NIST test vector
PASS sha256.hex > matches the multi-block NIST test vector
```

### Full suite GREEN

Command:

```sh
./scripts/run-tests.sh
```

Exit status: `0`

Output:

```text
PASS json.decode > decodes nested objects and arrays
PASS json.decode > decodes JSON string escapes and Unicode escapes
PASS json.decode > decodes JSON numbers
PASS json.decode > decodes booleans and preserves null with its sentinel
PASS json.decode > rejects duplicate object keys
PASS json.decode > rejects trailing input
PASS json.decode > rejects non-finite decoded numbers
PASS json.encode > encodes objects with deterministic lexicographic key ordering
PASS json.encode > encodes null with its explicit sentinel
PASS json.encode > retains an empty array decoded from JSON
PASS json.encode > rejects non-finite numbers
PASS json.encode > rejects cyclic tables
PASS sha256.hex > matches the empty-string NIST test vector
PASS sha256.hex > matches the abc NIST test vector
PASS sha256.hex > matches the multi-block NIST test vector
PASS test harness > supports equality and expected errors
PASS test harness assertions > supports deep equality
```

## Self-review

- `json.decode` is a strict recursive-descent parser: it accepts only JSON whitespace and grammar, rejects duplicate keys and trailing data, detects malformed numeric grammar and non-finite results, validates raw UTF-8, and requires paired UTF-16 surrogate escapes.
- `json.encode` emits compact deterministic JSON by sorting string object keys, escapes control characters, rejects invalid UTF-8, nil, unsupported values, non-finite numbers, sparse arrays, non-string object keys, and cyclic tables. `json.null` is the explicit JSON-null representation.
- Empty decoded arrays retain their JSON array shape through an internal weak-key marker; a plain empty Lua table remains the canonical empty JSON object because the supplied interface has no separate array constructor.
- `sha256.hex` uses Lua 5.4 bitwise operations only, writes SHA-256 length padding in big-endian form, and returns eight zero-padded lowercase 32-bit words.
- No external runtime dependency or mutation-related code was added. `git diff --check` was clean before each code commit.

## Commits

- `02c0945` — `feat: add strict JSON and SHA-256 primitives`
- `19eaa60` — `fix: preserve decoded empty JSON arrays`

## Concerns

- The requested `json.encode(table)` interface cannot distinguish a newly created empty Lua array from a newly created empty Lua object. The codec preserves decoded `[]` values as arrays, while an unmarked `{}` encodes as `{}`. A future array-constructor API would be needed only if callers must construct an empty JSON array directly.

## Review follow-up — integer canonicalization and adversarial coverage

Review identified that `string.format("%.17g", integer)` coerces Lua 5.4 integers through floating-point formatting. In particular, `9007199254740993` was encoded as `9007199254740992`. The encoder now emits `tostring(value)` whenever `math.type(value) == "integer"`, retaining every signed 64-bit integer exactly.

The JSON suite now also covers malformed number grammar, invalid raw UTF-8, unpaired high and low Unicode surrogates, sparse arrays, non-string object keys, and invalid UTF-8 encoding. SHA-256 now covers binary input and 55-, 56-, 63-, and 64-byte padding boundaries.

The SHA boundary expectations were independently generated with OpenSSL, not the implementation under test:

```sh
./third_party/lua-5.4.8/src/lua -e 'io.write(string.char(0, 1, 2, 3, 254, 255))' | openssl dgst -sha256
./third_party/lua-5.4.8/src/lua -e 'io.write(string.rep("a", 55))' | openssl dgst -sha256
./third_party/lua-5.4.8/src/lua -e 'io.write(string.rep("a", 56))' | openssl dgst -sha256
./third_party/lua-5.4.8/src/lua -e 'io.write(string.rep("a", 63))' | openssl dgst -sha256
./third_party/lua-5.4.8/src/lua -e 'io.write(string.rep("a", 64))' | openssl dgst -sha256
```

```text
SHA2-256(stdin)= 7ea646958715ed687aa9ac2f5d785feb1a93411f4f25fdd6c7fcc6ab07fdf0e3
SHA2-256(stdin)= 9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318
SHA2-256(stdin)= b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a
SHA2-256(stdin)= 7d3e74a05d7db15bce4ad9ec0658ea98e3f06eeecf16b4c6fff2da457ddc2f34
SHA2-256(stdin)= ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb
```

### Review follow-up RED

Command:

```sh
./scripts/run-tests.sh tests/unit/json_spec.lua
```

Exit status: `1`

Output:

```text
FAIL preserves Lua 5.4 integers exactly
tests/unit/json_spec.lua:86: expected "9007199254740993", got "9007199254740992"
stack traceback:
	[C]: in function 'error'
	./tests/support/assertions.lua:13: in function 'tests.support.assertions.equal'
	tests/unit/json_spec.lua:86: in function <tests/unit/json_spec.lua:85>
	[C]: in function 'xpcall'
	tests/run.lua:20: in function 'it'
	tests/unit/json_spec.lua:85: in function <tests/unit/json_spec.lua:72>
	[C]: in function 'xpcall'
	tests/run.lua:12: in function 'describe'
	tests/unit/json_spec.lua:72: in main chunk
	[C]: in function 'xpcall'
	tests/run.lua:38: in main chunk
	[C]: in ?
PASS json.decode > decodes nested objects and arrays
PASS json.decode > decodes JSON string escapes and Unicode escapes
PASS json.decode > decodes JSON numbers
PASS json.decode > decodes booleans and preserves null with its sentinel
PASS json.decode > rejects duplicate object keys
PASS json.decode > rejects trailing input
PASS json.decode > rejects non-finite decoded numbers
PASS json.decode > rejects malformed number grammar
PASS json.decode > rejects invalid raw UTF-8
PASS json.decode > rejects unpaired Unicode surrogates
PASS json.encode > encodes objects with deterministic lexicographic key ordering
PASS json.encode > encodes null with its explicit sentinel
PASS json.encode > retains an empty array decoded from JSON
PASS json.encode > rejects non-finite numbers
PASS json.encode > rejects cyclic tables
PASS json.encode > rejects sparse arrays and non-string object keys
PASS json.encode > rejects invalid UTF-8 strings
```

### Review follow-up GREEN

Focused JSON command:

```sh
./scripts/run-tests.sh tests/unit/json_spec.lua
```

Exit status: `0`

Output:

```text
PASS json.decode > decodes nested objects and arrays
PASS json.decode > decodes JSON string escapes and Unicode escapes
PASS json.decode > decodes JSON numbers
PASS json.decode > decodes booleans and preserves null with its sentinel
PASS json.decode > rejects duplicate object keys
PASS json.decode > rejects trailing input
PASS json.decode > rejects non-finite decoded numbers
PASS json.decode > rejects malformed number grammar
PASS json.decode > rejects invalid raw UTF-8
PASS json.decode > rejects unpaired Unicode surrogates
PASS json.encode > encodes objects with deterministic lexicographic key ordering
PASS json.encode > encodes null with its explicit sentinel
PASS json.encode > retains an empty array decoded from JSON
PASS json.encode > preserves Lua 5.4 integers exactly
PASS json.encode > rejects non-finite numbers
PASS json.encode > rejects cyclic tables
PASS json.encode > rejects sparse arrays and non-string object keys
PASS json.encode > rejects invalid UTF-8 strings
```

Focused SHA-256 command:

```sh
./scripts/run-tests.sh tests/unit/sha256_spec.lua
```

Exit status: `0`

Output:

```text
PASS sha256.hex > matches the empty-string NIST test vector
PASS sha256.hex > matches the abc NIST test vector
PASS sha256.hex > matches the multi-block NIST test vector
PASS sha256.hex > hashes binary input
PASS sha256.hex > handles SHA-256 padding boundaries
```

Full-suite command:

```sh
./scripts/run-tests.sh
```

Exit status: `0`

Output:

```text
PASS json.decode > decodes nested objects and arrays
PASS json.decode > decodes JSON string escapes and Unicode escapes
PASS json.decode > decodes JSON numbers
PASS json.decode > decodes booleans and preserves null with its sentinel
PASS json.decode > rejects duplicate object keys
PASS json.decode > rejects trailing input
PASS json.decode > rejects non-finite decoded numbers
PASS json.decode > rejects malformed number grammar
PASS json.decode > rejects invalid raw UTF-8
PASS json.decode > rejects unpaired Unicode surrogates
PASS json.encode > encodes objects with deterministic lexicographic key ordering
PASS json.encode > encodes null with its explicit sentinel
PASS json.encode > retains an empty array decoded from JSON
PASS json.encode > preserves Lua 5.4 integers exactly
PASS json.encode > rejects non-finite numbers
PASS json.encode > rejects cyclic tables
PASS json.encode > rejects sparse arrays and non-string object keys
PASS json.encode > rejects invalid UTF-8 strings
PASS sha256.hex > matches the empty-string NIST test vector
PASS sha256.hex > matches the abc NIST test vector
PASS sha256.hex > matches the multi-block NIST test vector
PASS sha256.hex > hashes binary input
PASS sha256.hex > handles SHA-256 padding boundaries
PASS test harness > supports equality and expected errors
PASS test harness assertions > supports deep equality
```
