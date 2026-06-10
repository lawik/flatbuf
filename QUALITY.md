# Code quality review

Originally a snapshot from a review on 2026-05-14; a second, deeper
review on 2026-06-09 produced [`REVIEW.md`](REVIEW.md), and the fixes
landed 2026-06-10. All gates are green:

| Check | Status |
|---|---|
| `mix compile --warnings-as-errors --force` | clean |
| `mix format --check-formatted` | clean |
| `mix credo --strict` | clean (see note on exclusions below) |
| `mix dialyzer` | clean |
| `mix test` (full corpus + flatc) | 365 pass, 0 fail |
| `mix test` (fresh clone, offline) | 264 pass, 0 fail, 13 skipped with notice |

CI (`.github/workflows/ci.yml`) runs lint, the offline profile, the
full-corpus profile, and dialyzer.

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

## Still open (optional, low priority)

- [ ] Property-based round-trip tests (StreamData) — SPEC §10.4.
- [ ] Verifier errors carry no path to the failing field (flat tagged
  tuples); depth limit is fixed at 64.
- [ ] Three upstream fixtures remain pinned as expected failures
  (`alignment_test`, `evolution_v1`, `test_64bit`) — 64-bit offsets
  and flatc JSON-layer gaps; see `test/fixtures/fixture_manifest.exs`.
- [ ] Union underlying types (`union U : int32 {}`) unsupported.
- [ ] `deprecated` fields and `file_extension` have only incidental
  test coverage.
- [ ] `Process.put`-based namespace threading in
  `lib/flatbuf/codegen/{table,struct,union}.ex` — works, but a
  threaded `%State{}` or closure would be cleaner.
- [ ] `lib/flatbuf/codegen/wire.ex` fills its template with a single
  `String.replace` — fine for one hole, fragile if more get added.
- [ ] Longer-term: build generated code as AST + `Macro.to_string/1`
  instead of string templates + post-hoc formatting.
