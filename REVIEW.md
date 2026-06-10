# Library review — 2026-06-09

> **Resolution status (2026-06-10):** the findings below were worked
> through in four streams (wire correctness, schema front-end,
> tooling/packaging, encode-oracle suite) merged the following day.
> Fixed: C1–C5, the resolver validation layer, the lexer crashes and
> escape gaps, `root_type` lookup, `:nstandard` packaging, niceties
> validation, manifest robustness, fresh-clone-green tests, CI
> workflows, the encode-direction oracle suite, and the SPEC/README/
> CHANGELOG drift. A third round the same day closed the remaining
> open items: property-based tests, verifier error paths +
> configurable depth, union underlying types, the `alignment_test`
> pin (harness bug), deprecated-field semantics (including an encode
> fix), `file_extension/0`, and the codegen maintainability items.
> Full suite: 424 tests + 12 properties / 0 failures (323 + 12
> offline); all gates clean. Still open (tracked in QUALITY.md):
> 64-bit offsets (`test_64bit` stays pinned, scope estimated),
> `evolution_v1` (pinned — flatc segfaults on its own buffer; not
> ours to fix), the longer-term AST-codegen idea, and `elixir:
> "~> 1.19"` kept deliberately (formatter-version stability for
> `flatbuf.gen.check`). The text below is the unedited point-in-time
> review.

A quality / completeness / sanity review of `flatbuf` at f374490. Method:
re-ran every quality gate locally, deep-read all of `lib/`, the test
suite, and the docs, and live-reproduced the headline bugs against
generated code. Findings marked **[repro]** were reproduced by executing
code in this review; **[read]** were traced in source; **[gap]** are
claimed-but-absent features or doc drift.

## Verdict

The "alpha" label is honest and the local engineering hygiene is real —
but the two pillars the README leans on (round-trips the upstream
corpus; verifier makes untrusted input safe) are weaker than advertised.
The **decode** path is well tested against `flatc`; the **encode** path
has effectively never been validated against the reference
implementation, and it has two real bugs in ordinary usage (silent
scalar truncation; `= null` optional scalars crash `encode/1`). The
verifier has a soundness hole on inline fields. The schema resolver
performs almost none of the validation SPEC §6.2 promises. And none of
the quality claims are enforceable by anyone but the author: there is no
CI, and a fresh clone's `mix test` is red.

None of this is fatal — the architecture is clean, the bugs are
localized, and the fix list below is tractable. But the gap between the
documents' claims and the artifact is currently the project's biggest
liability.

## Gates re-verified locally

| Check | Claimed (QUALITY.md) | Observed |
|---|---|---|
| `mix compile --warnings-as-errors --force` | clean | clean ✓ |
| `mix format --check-formatted` | clean | clean ✓ |
| `mix credo --strict` | clean | clean ✓ (447 mods/funs, no issues) |
| `mix dialyzer` | clean | clean ✓ (0 errors, 0 skips) |
| `mix test` | 196 pass, 0 fail (full corpus) | **95 tests, 6 failures, 7 skipped** without corpus |

The 6 failures are `test/flatbuf_test.exs` — its `need_corpus!` helper
calls `flunk` instead of skipping (test/flatbuf_test.exs:19-23), unlike
every other corpus-gated file. So the out-of-box experience of `git
clone && mix test` is a red suite. The 196-test green run exists only
with the corpus fetched and flatc downloaded, and was last verified only
on the author's machine — the committed fixture manifest literally
contains `/home/lawik/sprawl/flatbuf/...` inside a recorded error
(test/fixtures/fixture_manifest.exs:30). **There is no CI configuration
in the repository at all.**

## Correctness bugs (encode / decode / verify)

### C1 — No scalar range validation; silent truncation on encode. HIGH [repro]

SPEC §6.6: "Encoding validates `required` presence and scalar ranges
before writing." The range half is absent. `encode(%{a: 70_000})` on a
`ushort` field returns `{:ok, bin}` that decodes back as `4464`
(70000 mod 65536); negative values wrap into unsigned fields the same
way. The write path (`Wire.push_u16/2` and friends,
lib/flatbuf/codegen/wire.ex:425-430; struct encoder,
lib/flatbuf/codegen/struct.ex:235-251) constructs binaries with no
checks, and Elixir binary construction truncates silently. This is
silent data corruption in ordinary usage.

### C2 — Optional scalars (`= null`) make `encode/1` raise on their own default. HIGH [repro]

A table with `b: int = null` cannot be encoded without explicitly
supplying `b`: `encode(%{})` (or `encode(%T{})`, since the struct
default is `nil`) raises `ArgumentError` instead of returning a tagged
error. Cause: `default_value/2` maps `= null` to `nil`
(lib/flatbuf/codegen/table.ex:165) but the omission sentinel passed to
`add_field_scalar` is `literal_for_scalar(nil, kind)` = `0`
(table.ex:1171, table.ex:1056-1094), so `nil == 0` is false and
`push_i32(b, nil)` raises (wire.ex:588-595). The generated `encode/1`
only catches the `:flatbuf_required` throw, so the exception escapes the
`{:ok, _} | {:error, _}` contract. Fix: the push-default for a `:null`
field must be `nil`, so `nil == nil` omits the slot.

### C3 — Verifier does not bounds-check inline field offsets. HIGH [read, agent-reproduced]

`verify_field/2` emits no check for `{:scalar,_}`, `{:enum,_}`, and
`{:struct,_}` fields, with a comment claiming "the vtable header check
already bounded the inline area" (table.ex:1245-1258). It didn't: the
header check bounds `table_pos + inline_size` where `inline_size` is the
attacker-controlled second u16 of the vtable (wire.ex:320-341), and the
per-slot voffsets are never checked against `inline_size` or the buffer
end. A buffer with a slot voffset of `0xFF00` passes `verify/1` and then
raises out of the public zero-copy accessors (which have no rescue).
This breaks the core verifier contract — SPEC §6.5.1 — and the "verify
first, then use accessors on untrusted input" guidance in the docs.
Fix: per present inline slot, check `voffset + elem_size <= inline_size`.

### C4 — Vector-of-union: decoder and verifier disagree on the element count. MEDIUM [read, agent-reproduced]

The decoder takes the count from the **types** vector (table.ex:439);
the verifier takes it from the **values** vector (table.ex:1288) and
never asserts the two parallel vectors are equal length. A buffer with
mismatched counts passes `verify/1` while being malformed; with
`values_count > types_count` the verifier itself can read past the
verified region of the types vector via `read_u8` (table.ex:1289-1300)
and raise instead of returning `{:error, _}`. Fix: assert
`types_count == values_count` and iterate one authoritative count.

### C5 — `nil` (NONE) element in a vector-of-unions crashes `encode/1`. MEDIUM [agent-reproduced]

`build_subobject_for_field` deliberately maps a `nil` element to a
`{0, nil}` discriminator/address pair (table.ex:854-855) — NONE elements
are intended to work — but `Wire.create_offset_vector/2` then computes
`acc.size + 4 - nil` (wire.ex:554) and raises `ArithmeticError`,
uncaught. Either emit a 0 uoffset for `nil` addrs or reject the input
with a tagged error.

### C6 — Verifier gaps vs SPEC §6.5. LOW-MEDIUM [read]

- No alignment checks anywhere in the verify path (SPEC §6.5.2). Not a
  memory-safety issue on the BEAM, but a buffer this verifier accepts
  may be rejected by a conformant C++ reader.
- No visited-set; depth limit hardcoded at 64, not configurable
  (SPEC §6.5.6). In practice uoffsets are forward-only so true cycles
  can't occur — the SPEC text overpromises rather than the code
  underdelivering, but they should agree.
- Error shape is flat `{:error, reason}` with no path to the failing
  field; SPEC §6.5.7 promises a path.
- `decode_at/2` recursion has no depth guard (bounded by buffer size in
  practice; cheap to add).

Verified correct while looking for the above: file_identifier placement
and 4-byte enforcement, string null-terminator write+verify, vtable
dedup and soffset arithmetic, endianness/signedness of all primitives,
`start_table` alignment, vector length overflow (bignums make the C-style
multiplication overflow a non-issue).

## Schema front-end (lexer / parser / resolver)

The happy path is solid — unions correctly take two vtable slots
(explicit `id` included), struct cycles are caught, namespace walk-up
matches flatc, forward and cross-file references work, struct
layout/alignment is right. The problem is that SPEC §6.2's validation
layer mostly does not exist. All of the following degenerate schemas are
**accepted silently**:

| Input | Result | Severity |
|---|---|---|
| `a:int (id:0); b:int (id:0);` | both fields get slot 4 — wire corruption | HIGH |
| `(id: -1)` | slot 2, aliasing the vtable inline-size word | HIGH |
| `table T { a:int; a:int; }` | duplicate field accepted; ditto enum/union variant dups | HIGH |
| `ubyte = 300`, `int = "hi"` | stored as-is; the string default later crashes codegen with `CaseClauseError` | HIGH |
| `enum E:byte { A = 300 }`, non-ascending values, bit_flags overflow | accepted | MEDIUM |
| `required` on a scalar, `force_align: 3` (non-power-of-2) | accepted | MEDIUM |
| `table T { a:[int:3]; }` (fixed array in a table) | accepted despite parser comment "resolver enforces" struct-only (parser.ex:207-210) | MEDIUM |

SPEC.md:166-177 explicitly claims each of these checks. The committed
conformance manifest even pins one consequence as green:
`name_clash_test/invalid_test2.fbs => :ok`
(test/fixtures/conformance_manifest.exs:44) — a schema upstream rejects,
this resolver accepts, recorded as expected.

Additional front-end findings:

- **Lexer crashes on non-UTF-8 input** — `Lexer.tokenize(<<0xFF>>)`
  raises `FunctionClauseError` (lexer.ex:130, no fallback clause), and
  `Parser.parse/1` only catches its own throws, so a Latin-1 `.fbs`
  file crashes `mix flatbuf.gen` with a stack trace instead of an error
  tuple. HIGH for robustness, trivial to fix. [agent-reproduced]
- String escapes support only `\n \t \r \\ \" \' \0`
  (lexer.ex:169-181); `\uXXXX`, `\xHH`, `\b`, `\f` fail to lex despite
  SPEC's "escape sequences per JSON". One legal upstream schema already
  fails to parse and is pinned as an expected failure:
  `union_underlying_type_test.fbs` (conformance_manifest.exs:86).
- Octal literals claimed in SPEC but absent; C-style `017` silently
  parses as decimal 17. `.5` / `1.` float forms rejected.
- `root_type` resolves in the current namespace only — it never gets
  the walk-up lookup that field references get (resolver.ex:129-132),
  so `table G {...} namespace Foo; root_type G;` fails spuriously.
- Source spans are oversold: tokens carry line-only (no column/file),
  field CST nodes carry no location at all, and resolver errors
  (`{:unknown_type, name}` etc.) carry zero source location — painful
  in a multi-file include graph.

## Tooling & packaging

- **`{:nstandard, "~> 0.3"}` is an unconditional prod runtime
  dependency** (mix.exs:103). It is pure dev tooling (an igniter-based
  setup task). Every consumer would ship it in releases — jarring for a
  library whose pitch is "generate, commit, drop the dep". Should be
  `only: [:dev, :test], runtime: false`. One-line fix, do it before any
  publish. HIGH.
- **`mix flatbuf.gen.clean` does not exist** despite SPEC.md:82.
  Relatedly, SPEC.md:85 claims `flatbuf.gen` and the compiler share a
  manifest; `flatbuf.gen` has no manifest code at all, so renaming a
  table via the CLI path strands stale `.ex` files.
- **"Incremental via a per-build manifest" is overstated**
  (CHANGELOG.md:10-12): `compile.flatbuf` re-runs the full
  parse/resolve/codegen/format pipeline on every `mix compile`; digests
  only gate file writes. (Upside discovered while checking: included
  `.fbs` changes *are* picked up, precisely because nothing is actually
  skipped.) Also the `artifacts_changed? -> true` clause
  (compile.flatbuf.ex:122) force-rewrites every artifact when any digest
  changes, bumping mtimes and triggering needless downstream recompiles.
- **Niceties are unvalidated**: `--niceties behavior` (or any typo)
  silently does nothing (gen.ex:78-82 `String.to_atom` on raw input, no
  membership check). And the niceties↔dependency story is undocumented
  where it matters: with `--niceties behaviour` plus the README's
  recommended `only: [:dev, :test]` dep line, consumers get "behaviour
  Flatbuf.Table is undefined" warnings in prod compiles (hard failure
  under `--warnings-as-errors`); `--niceties jason` is a hard compile
  error unless the consumer depends on `:jason`, which flatbuf doesn't
  declare even as optional and no doc mentions.
- `Flatbuf.Gen.plan` docs say duplicate modules collapse "last writer
  wins" (gen.ex:28-29); `Enum.uniq_by` keeps the **first** (gen.ex:50).
- Corrupted manifest crashes `mix compile`/`mix clean`
  (`:erlang.binary_to_term/1` without rescue, compile.flatbuf.ex:204,
  :82); missing `:schemas` config raises a raw `KeyError` instead of a
  friendly `Mix.raise` (compile.flatbuf.ex:181).
- **Release hygiene**: version is 0.1.0 while CHANGELOG has a large
  Unreleased section — bump before publishing. `elixir: "~> 1.19"` is
  restrictive for a library; the only 1.19-ism found is the
  test-env-only `test_ignore_filters`. `.gitignore:26` points at
  `lib/mix/tasks/flatbuf.fetch_fixtures.ex`; the task lives under
  `test/support/`.
- `mix flatbuf.gen.check` itself is sound (pure read-and-compare, no
  writes, tested). One latent issue: drift is compared against
  `Code.format_string!` output, so a different Elixir minor in CI than
  the one that generated committed files can report false drift.

## Test & verification story

This is the area where claims and reality diverge most.

- **Encoder wire-compatibility is essentially unverified.** The
  flatc-encode → Elixir-decode direction has 15 green fixtures across
  multiple language ports. The Elixir-encode → flatc-decode direction is
  exactly **one test on a trivial two-field table**
  (test/flatbuf/oracle_test.exs:43-50). No buffer containing a union,
  vector, struct, enum, nested table, shared string, sorted key vector,
  size prefix, or forced alignment produced by this encoder has ever
  been fed to flatc. SPEC §10.2 promises both directions. Roughly 40 of
  the 82 offline-green tests are own-encode → own-decode round-trips,
  which prove self-consistency, not wire compatibility — a symmetric
  encoder/decoder bug passes all of them. **This is the single most
  important gap to close**, and it would likely have caught C1/C2.
- **The conformance/fixture manifests pin outcomes, not correctness.**
  They assert "same result as last recorded", and the recorded results
  include failures blessed as green: 3 of 18 fixtures pinned as errors
  (`alignment_test`, `evolution_v1`, `test_64bit` —
  fixture_manifest.exs:11-30), the `union_underlying_type_test.fbs`
  parse failure, and the `invalid_test2.fbs` false-accept. README.md:6
  "Round-trips the upstream `flatc` test corpus" is therefore
  overstated: 15/18, decode-direction. Also "conformance" tests run
  parser/resolver only (test/support/upstream.ex:39-45) — zero codegen
  or wire code is exercised by those 83 tests.
- **SPEC §10 describes a test plan that largely doesn't exist**:
  no StreamData property tests (item 4 — no dep, no `property` blocks),
  no snapshot tests of generated source (item 7), no
  `Dockerfile.test` (item 2), corpus is a gitignored tag-pinned sparse
  clone, not a SHA-pinned submodule (item 1), fuzz tests use plain
  rescue, not the claimed `:erlang.trace/3` harness (item 6). The flatc
  binary is auto-downloaded mid-test with no checksum verification, and
  the release tag is duplicated in two files (flatc.ex:23,
  fetch_fixtures.ex:21) — drift risk.
- **Misleading fuzz test names**: "huge u32 length values are rejected"
  and "random-bytes buffers are rejected"
  (verifier_fuzz_test.exs:89,129) assert only `:ok or {:error, _}` —
  they pass if verify returns `:ok`. No-crash is a fine fuzz property;
  the names claim rejection.
- **Features with no dedicated test**: `deprecated` fields (zero direct
  tests), optional scalars offline, `bit_flags` offline, vectors of
  unions in the encode direction, `decode_at/2` (advertised in README,
  never called by any test), `build/2` (incidental use only),
  `file_extension`. Front-end unit tests are thin (7 lexer / 5 parser /
  6 resolver tests, happy-path only — none of the §"Schema front-end"
  failures above had a test to catch them).

## Documentation drift (consolidated)

SPEC.md ends with "if a change invalidates a claim here, the spec is
updated in the same PR". Currently failing that rule: §6.1 "built on
`nimble_parsec`" (hand-written lexer/parser; no such dep), §5.1
`flatbuf.gen.clean` + shared manifest, §5.1 `config :flatbuf` (actual:
`config :consumer_app, :flatbuf`), §4 `Flatbuf.Encoder`/`Decoder`
protocols (don't exist) and `use Flatbuf.Table` (actual: `@behaviour`),
§4/§6.4 default wire module `<RootNamespace>.Flatbuf.Wire` (actual:
`Flatbuf.Generated.Wire`), §6.2 validation list, §6.5 verifier
alignment/cycle/path claims, §6.6 scalar range validation, §10 test
plan items 1/2/4/6/7. QUALITY.md's "196 pass" needs the corpus +
network caveat; README's corpus claim needs the 15/18 qualifier.

## Recommended order of attack

1. **Make `mix test` green on a fresh clone** (convert
   `flatbuf_test.exs` flunks to skips with a printed hint, or make
   `test_helper.exs` announce the missing corpus) and **add CI** that
   runs the offline suite always and the corpus suite with cached
   fixtures. Until this exists, every quality claim is self-reported.
2. **Fix C1 + C2** (range validation; `nil` push-default for `= null`
   fields) — both are ordinary-usage encode bugs.
3. **Fix C3** (verifier inline-slot bounds) and C4/C5 — C3 is the
   security-relevant one given the "verify untrusted input" pitch.
4. **Build an encode-direction oracle suite**: feed Elixir-encoded
   buffers for every feature schema (unions, vectors, structs, nested,
   size-prefixed, force_align, key-sorted) through `flatc --json` and
   compare. Highest-leverage single addition to the test suite.
5. **Move `:nstandard` to dev/test**, validate niceties input, document
   the niceties dependency caveats, bump version + roll CHANGELOG
   before any `hex.publish`.
6. **Resolver validation pass**: duplicate field/variant names,
   explicit-id contiguity/range, default representability, enum
   ranges, `required`-on-scalar, `force_align` power-of-2, arrays in
   tables, plus the lexer UTF-8 crash. Each is small; together they
   close most of the SPEC §6.2 gap.
7. **Reconcile the documents** with reality (list above) — or with the
   fixes, whichever direction each claim should resolve.

## What's genuinely good

Worth saying explicitly: the five-layer architecture with pure
parser/resolver/codegen and I/O quarantined in the Mix layer is exactly
right and made this review easy; the generated code is readable,
formatted, and genuinely dependency-free in the default configuration;
the backward builder with vtable dedup is correct and cleanly written;
`flatbuf.gen.check` is a well-executed CI gate; PROBLEMS.md/QUALITY.md
as living documents are a good practice — the punch-list items QUALITY.md
marks resolved were all verified actually resolved. The foundation is
sound; the work remaining is validation, verification, and truth in
advertising.
