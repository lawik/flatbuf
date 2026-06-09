# Changelog

## Unreleased

### Added

- `Mix.Tasks.Compile.Flatbuf` — a Mix compiler that regenerates `.ex`
  files from configured `.fbs` schemas on every `mix compile`. Wire
  it in with `compilers: [:flatbuf | Mix.compilers()]` and configure
  schemas under `config :my_app, :flatbuf`. Incremental via a
  per-build manifest; drops stale outputs when schemas are removed
  from config.
- `mix flatbuf.gen.check` — CI gate that exits non-zero if running
  the gen pipeline would change any committed file.
- `Flatbuf.Table` behaviour and `--niceties` opt-in for generated
  root tables. `--niceties behaviour` attaches the behaviour;
  `--niceties jason` derives `Jason.Encoder` on the struct. Default
  remains dependency-free.
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

- Codegen crashed with a `CaseClauseError` on enum types declared
  with no variants (e.g. `enum Foo : int {}`).

## v0.1.0

- Initial extraction from `sprawl/arrow`. Phases 1 and 2 of the spec
  in `SPEC.md` are implemented: parser, resolver, codegen for
  tables/structs/enums/unions, JSON converter, verifier, and the
  `mix flatbuf.gen` task with namespace/include overrides.
