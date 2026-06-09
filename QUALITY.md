# Code quality review

Originally a snapshot from a review on 2026-05-14; updated 2026-06-09
after working through the punch list. All gates are green:

| Check | Status |
|---|---|
| `mix compile --warnings-as-errors --force` | clean |
| `mix format --check-formatted` | clean |
| `mix credo --strict` | clean (see note on exclusions below) |
| `mix dialyzer` | clean |
| `mix test` | 196 pass, 0 fail (full corpus present) |

## Punch list (resolved)

- [x] Dead `is_root?` plumbing in `codegen/table.ex` dropped — the
  always-true parameter and its dead branches are gone (dialyzer clean).
- [x] `Resolver.topo_sort/visit` switched from `MapSet` to plain
  `key => true` maps — sidesteps the `call_without_opaque` warning;
  rationale comment at the call site.
- [x] `setup_all` skip in `reflection_self_test.exs` replaced with a
  compile-time `@moduletag skip:` — no more 1 fail / 3 invalid when
  the corpus is missing.
- [x] Every emitted artifact is piped through `Code.format_string!/1`
  in `Flatbuf.Codegen.generate/2`; a test asserts formatter
  idempotency over four representative schemas.
- [x] Generated `decode/1` rescue narrowed to
  `MatchError`/`ArgumentError`/`FunctionClauseError`, returned as
  `{:error, {:malformed_buffer, e}}`; everything else propagates.
- [x] `()` added to the four zero-arity defs in
  `mix/tasks/compile.flatbuf.ex`.
- [x] `build_verify_at` uses `Enum.map_join/3`.
- [x] `parse_niceties/1` hoisted into `Flatbuf.Gen`, both mix tasks
  call it.
- [x] Empty-enum regression (`enum Foo : int {}` field crashed
  `default_enum_value/2`) fixed + regression test.
- [x] README condensed; CHANGELOG records the generated-code behavior
  changes (formatting pass, narrower decode error contract).

## Decisions (deliberately not "fixed")

- **Credo complexity/nesting hotspots**: rather than splitting
  `codegen/table.ex` & friends, `.credo.exs` excludes
  `Refactor.CyclomaticComplexity` and `Refactor.Nesting` for
  `lib/flatbuf/codegen/`, the lexer, the resolver, and the mix tasks.
  Those modules are dominated by big pattern-match switches over the
  FlatBuffers type grammar; splitting them spreads one decision across
  many functions without making anything clearer. Rationale is
  commented in `.credo.exs`. Revisit only if those files start
  accumulating non-switch logic.
- **`throw`/`catch` with tagged tuples** in lexer/parser/resolver —
  standard idiom for deeply recursive parsers, keep.
- Spellweaver unknowns are legitimate technical terms; add to the
  cspell dictionary if they nag.

## Still open (optional, low priority)

- [ ] `Process.put`-based namespace threading in
  `lib/flatbuf/codegen/{table,struct,union}.ex` — works, but a
  threaded `%State{}` or closure would be cleaner. Not a correctness
  issue.
- [ ] `lib/flatbuf/codegen/wire.ex` fills its template with a single
  `String.replace(@template, "<%= MODULE %>", ...)` — fine for one
  hole, fragile if more get added.
- [ ] Longer-term: build generated code as AST + `Macro.to_string/1`
  instead of string templates + post-hoc formatting.
