# Changelog

## Unreleased

### Added

- Union underlying types: `union U : int32 { ... }` (any integral
  scalar or a previously declared enum). Discriminators are read and
  written at the underlying type's full width, matching what `flatc`'s
  generated C++/TS code does on the wire. Note that `flatc`'s own JSON
  tooling does not implement the feature (it refuses such schemas for
  `--json` and mis-writes 1-byte discriminators for `--binary`), so
  text-level interop with `flatc` is not possible for these schemas.
- Property-based round-trip tests (StreamData): generators derived
  from the schema IR produce arbitrary valid values and round-trip
  them through encode/decode/verify and through `flatc` (SPEC §10.4).
- Generated root tables expose `file_extension/0` when the schema
  declares `file_extension`, parallel to `file_identifier/0`.
- `verify/2` and `verify_size_prefixed/2` accept `max_depth:`
  (default 64) to bound recursion into nested tables.
- Encode-direction differential suite: buffers produced by the
  generated encoders are now verified against `flatc` across the
  feature matrix (scalars, strings, vectors, structs, fixed arrays,
  enums/bit_flags, unions incl. vectors of unions, nesting,
  file identifiers, size prefixes, key sorting, shared strings,
  force_align). Previously only the decode direction was covered.
- Schema validation in the resolver, mirroring `flatc` semantics:
  duplicate field/variant names, explicit `(id: N)` rules
  (all-or-none, consecutive from 0, unions take two ids), default
  value typing and range checks, enum value ranges (incl. `bit_flags`
  shifts), `required` rejected on scalar fields, `force_align`
  power-of-two/bounds checks, fixed arrays restricted to structs,
  union variant cap (255), empty structs and struct defaults
  rejected, nested vectors rejected. Errors carry the offending name
  and source line.
- Lexer: `\b`, `\f`, `\/`, `\uXXXX` (with surrogate pairs) and
  `\xHH` string escapes; `.5`/`1.` float literals; malformed or
  non-UTF-8 input returns tagged errors instead of raising.
- `root_type` now resolves with the same lookup rules `flatc` uses
  (name-as-written first, then current-namespace-qualified).
- GitHub Actions CI: lint, offline test, full-corpus test (fixtures
  and `flatc` cached), and dialyzer jobs.
- `Mix.Tasks.Compile.Flatbuf` — a Mix compiler that regenerates `.ex`
  files from configured `.fbs` schemas on every `mix compile`. Wire
  it in with `compilers: [:flatbuf | Mix.compilers()]` and configure
  schemas under `config :my_app, :flatbuf`. A per-build manifest
  gates writes (unchanged outputs aren't rewritten) and drops stale
  outputs when schemas are removed from config.
- `mix flatbuf.gen.check` — CI gate that exits non-zero if running
  the gen pipeline would change any committed file.
- `Flatbuf.Table` behaviour and `--niceties` opt-in for generated
  root tables. `--niceties behaviour` attaches the behaviour;
  `--niceties jason` derives `Jason.Encoder` on the struct (the
  consumer must depend on `:jason`). Default remains dependency-free.
- File identifier emission. When a schema declares
  `file_identifier "XXXX";`, the root encode helpers write the
  4-byte marker into the buffer header, and `file_identifier/0`
  surfaces the value on the generated module.
- Size-prefixed buffer support. Every root table now exposes
  `encode_size_prefixed/1`, `decode_size_prefixed/1`, and
  `verify_size_prefixed/1`.
- Required-field enforcement. Fields marked `(required)` in the
  schema cause `encode/1` to fail with
  `{:error, {:flatbuf_required, :name}}` when missing, and `verify/1`
  to fail with `{:error, {:missing_required, :name}}` when the
  buffer's vtable doesn't list the slot.

### Changed

- **Breaking (generated code):** verifier errors are now three-element
  tuples `{:error, reason, path}` where `path` is a root-first list of
  field atoms, vector indices, and union variant atoms locating the
  failure (e.g. `[:inventory, 3, :name]`); buffer-level failures carry
  `[]`. Reasons keep their tagged shapes; field identity that the path
  now carries was dropped from `:union_vector_*` reasons. Regenerate
  committed output and update any `{:error, _}` matches on `verify`
  results.
- Deprecated fields are skipped on encode (their vtable slots stay
  reserved), matching `flatc`'s generated builders — previously they
  were written. Decode still surfaces a deprecated field's value when
  a buffer contains it; `to_json/1` omits deprecated fields.
- Codegen threads the namespace override explicitly instead of via
  the process dictionary, and the wire template uses a validating
  multi-hole fill (internal; emitted sources are byte-identical).
- `Flatbuf.Codegen.generate/2` accepts a `:niceties` option.
- The generated `encode/1` now catches the required-field throw and
  returns it as a tagged error tuple instead of crashing the caller.
- Generated sources are piped through `Code.format_string!/1` before
  being returned/written, so emitted files pass
  `mix format --check-formatted` as-is. Regenerating previously
  committed output will produce a one-time formatting diff.
- The generated `decode/1` no longer catches every exception. It
  rescues only buffer-shaped failures (`MatchError`, `ArgumentError`,
  `FunctionClauseError`) and returns
  `{:error, {:malformed_buffer, exception}}`; other exceptions
  propagate. Use `verify/1` first on untrusted input.

### Fixed

- The `alignment_test` upstream fixture round-trips: the harness had
  been pairing the binary with a stale orphaned JSON from an older
  schema revision. The two remaining pinned fixtures are annotated
  with one-line reasons (`evolution_v1`: `flatc` segfaults generating
  text for its own buffer; `test_64bit`: 64-bit offsets unsupported
  and `flatc` has no JSON oracle for them), and recorded errors no
  longer embed machine-specific paths.
- Scalar values are validated on the encode path. Out-of-range or
  wrong-typed values used to be silently truncated into the wire
  (`encode(%{a: 70_000})` on a `ushort` produced `4464`); they now
  return `{:error, {:scalar_out_of_range | :invalid_scalar, field,
  kind, value}}`. Covers table fields, vectors, struct members,
  fixed arrays, enum underlying values, and hash fields.
- Optional scalar/enum fields (`= null`) no longer crash `encode/1`
  when absent, and explicitly-passed type-default values (`0`,
  `false`, first enum variant) are now written instead of dropped —
  absence and explicit defaults are distinguishable on the wire.
- The verifier bounds-checks inline fields (scalars, enums, inline
  structs, union discriminators) against the table's inline area. A
  crafted vtable could previously direct reads past the buffer while
  `verify/1` returned `:ok`.
- Vector-of-union verification checks both parallel vectors,
  requires equal element counts
  (`{:error, {:union_vector_count_mismatch, ...}}`), and no longer
  raises on count-inflated buffers.
- `nil` (NONE) elements in vectors of unions encode as
  discriminator 0 / offset 0 (the layout `flatc`'s binary layer
  accepts) instead of raising `ArithmeticError`; decode yields `nil`.
- A table whose only depth-recursing field is a vector of unions
  generated a `__verify_at__/3` that failed to compile.
- `:nstandard` was an unconditional runtime dependency; it is now
  dev/test-only, so consumers pull no transitive deps from
  `:flatbuf`.
- Unknown `--niceties` values (e.g. `behavior`) raised silently no
  effect; they are now rejected with the valid values listed.
- `Mix.Tasks.Compile.Flatbuf` tolerates a corrupted manifest,
  reports a missing `:schemas` config key with a friendly message,
  and no longer rewrites byte-identical artifacts (and their mtimes)
  when an unrelated schema changes.
- A fresh clone's `mix test` is green: corpus-gated smoke tests skip
  (instead of failing) with a notice pointing at
  `mix flatbuf.fetch_fixtures` / `mix flatbuf.fetch_flatc`.
- Codegen crashed with a `CaseClauseError` on enum types declared
  with no variants (e.g. `enum Foo : int {}`).

## v0.1.0

- Initial extraction from `sprawl/arrow`. Phases 1 and 2 of the spec
  in `SPEC.md` are implemented: parser, resolver, codegen for
  tables/structs/enums/unions, JSON converter, verifier, and the
  `mix flatbuf.gen` task with namespace/include overrides.
