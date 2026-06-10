# Code quality review

Originally a snapshot from a review on 2026-05-14; a second, deeper
review on 2026-06-09 produced [`REVIEW.md`](REVIEW.md), fixes landed
2026-06-10, and the remaining open items were worked through the same
day (round 3). All gates are green:

| Check | Status |
|---|---|
| `mix compile --warnings-as-errors --force` | clean |
| `mix format --check-formatted` | clean |
| `mix credo --strict` | clean (see note on exclusions below) |
| `mix dialyzer` | clean |
| `mix test` (full corpus + flatc) | 424 tests + 12 properties, 0 fail |
| `mix test` (fresh clone, offline) | 323 tests + 12 properties, 0 fail, 13 skipped with notice |

CI (`.github/workflows/ci.yml`) runs lint, the offline profile, the
full-corpus profile, and dialyzer.

## Round 3 punch list (resolved)

- [x] Property-based round-trip tests: IR-driven StreamData generators
  over kitchen-sink/union/struct schemas, four directions including
  `flatc` (SPEC §10.4 implemented).
- [x] Verifier errors carry a root-first path to the failing field
  (`{:error, reason, path}`), and `verify/2` takes `max_depth:`
  (default 64). Breaking change for generated code, recorded in the
  CHANGELOG.
- [x] Union underlying types (`union U : int32`) implemented with
  full-width discriminators — probed against `flatc`'s generated-code
  contract; its JSON tooling doesn't support the feature at all.
- [x] `alignment_test` fixture un-pinned (the harness paired a stale
  orphaned upstream JSON); the two remaining pins carry one-line
  reasons and no machine-specific noise.
- [x] `deprecated` fields: dedicated suite, and a real fix — encode
  now skips deprecated fields (slots stay reserved) instead of
  writing them.
- [x] `file_extension/0` emitted on root tables, mirroring
  `file_identifier/0`, with tests.
- [x] `Process.put` namespace threading replaced by explicit argument
  threading (emitted sources verified byte-identical).
- [x] Wire template filled via a validating multi-hole substitution
  that raises on missing or leftover placeholders.

## Round 2 punch list (resolved — details in REVIEW.md and CHANGELOG)

- [x] Scalar range/type validation on every encode path (was: silent
  truncation into the wire).
- [x] `= null` optional scalars/enums encode correctly (was: raise on
  their own default; explicit type-default values were dropped).
- [x] Verifier bounds-checks inline fields and union-vector pairs
  (was: crafted vtables passed `verify/1` then crashed accessors).
- [x] NONE elements in vectors of unions encode/decode/verify.
- [x] Resolver validation layer: duplicate names, explicit-id rules,
  default representability, enum ranges, `required`-on-scalar,
  `force_align` bounds, arrays-in-structs-only, union variant cap,
  empty structs, nested vectors — all with line-carrying errors,
  semantics probed against `flatc` 25.12.19.
- [x] Lexer never raises on malformed/non-UTF-8 input; JSON escapes
  plus `\xHH`; `.5`/`1.` floats.
- [x] Encode-direction differential suite vs `flatc` across the
  feature matrix (was: one trivial table).
- [x] `:nstandard` moved to dev/test (was: shipped to every consumer).
- [x] Unknown `--niceties` rejected with the valid set listed.
- [x] `compile.flatbuf`: corrupt-manifest tolerance, friendly missing
  `:schemas` error, no spurious rewrites of unchanged artifacts.
- [x] Fresh-clone `mix test` green (corpus tests skip with a notice).
- [x] SPEC/README/CHANGELOG reconciled with the implementation.

## Round 1 punch list (resolved 2026-06-09)

- [x] Dead `is_root?` plumbing in `codegen/table.ex` dropped.
- [x] `Resolver.topo_sort/visit` switched from `MapSet` to plain maps.
- [x] `setup_all` skip in `reflection_self_test.exs` replaced with a
  compile-time `@moduletag skip:`.
- [x] Every emitted artifact piped through `Code.format_string!/1`;
  formatter idempotency asserted.
- [x] Generated `decode/1` rescue narrowed to buffer-shaped failures.
- [x] `()` added to zero-arity defs in `mix/tasks/compile.flatbuf.ex`.
- [x] `build_verify_at` uses `Enum.map_join/3`.
- [x] `parse_niceties/1` hoisted into `Flatbuf.Gen`.
- [x] Empty-enum regression fixed + test.
- [x] README condensed; CHANGELOG records generated-code changes.

## Decisions (deliberately not "fixed")

- **Credo complexity/nesting hotspots**: `.credo.exs` excludes
  `Refactor.CyclomaticComplexity` and `Refactor.Nesting` for
  `lib/flatbuf/codegen/`, the lexer, the resolver, and the mix tasks.
  Those modules are dominated by big pattern-match switches over the
  FlatBuffers type grammar; splitting them spreads one decision across
  many functions without making anything clearer. Revisit only if
  those files start accumulating non-switch logic.
- **`throw`/`catch` with tagged tuples** in lexer/parser/resolver —
  standard idiom for deeply recursive parsers, keep.
- **No verifier alignment checks** — misaligned reads are safe on the
  BEAM and nothing we emit is misaligned; documented as a deviation in
  SPEC §6.5.
- **`mix flatbuf.gen` is manifest-free** — stale-output cleanup is the
  compiler's job; documented in SPEC §5.1 instead of duplicating the
  manifest machinery.
- **`evolution_v1` stays pinned** — `flatc`'s lax JSON parser writes a
  union value with a NONE discriminator and then segfaults trying to
  textify its own buffer; there is no reference output in any `flatc`
  mode, so no faithful coverage is possible. Reason recorded in the
  manifest.

## Still open (optional, low priority)

- [ ] 64-bit offsets / `(vector64)` encoding (`test_64bit` fixture
  stays pinned). Diagnosed scope: attribute plumbing in the schema
  front-end, u64 reads in wire/table decode + verify, and the big
  piece — FlatBufferBuilder64 semantics (64-bit region written before
  the 32-bit space) on the encode side; roughly 600–900 LOC, plus
  binary-level test support because `flatc` has no JSON oracle for
  64-bit buffers. Not to be started casually.
- [ ] Longer-term: build generated code as AST + `Macro.to_string/1`
  instead of string templates + post-hoc formatting. The string
  pipeline is now stable (formatter idempotency + byte-identity
  harness + oracle suites pin it), so this is an architectural
  preference, not a defect.
