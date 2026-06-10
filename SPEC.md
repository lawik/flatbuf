# `flatbuf` — Elixir FlatBuffers, full-spec, compile-time codegen

A pure-Elixir implementation of Google FlatBuffers (https://flatbuffers.dev) targeting **full coverage of the FlatBuffers specification**, with a strict architectural rule: **all schema-to-Elixir work happens at compile time** and **emits standalone `.ex` files** that can run without the `:flatbuf` dependency at runtime.

This document is the working spec. It exists to (a) lock the architectural shape before any code lands, (b) enumerate everything that the FlatBuffers spec requires us to support so nothing gets quietly deferred, and (c) describe a phasing order so the first usable slice arrives early without painting us into a corner on the harder features.

---

## 1. Goals

1. **Full FlatBuffers specification coverage.** Schema language, wire format, verifier semantics, JSON conversion, reflection. Everything `flatc` does on the serialization side, we do too. RPC service declarations are parsed and emitted as data; we do not implement a transport.
2. **Compile-time, file-emitting codegen.** Schemas are translated to `.ex` files by a Mix task (and optionally a Mix compiler). The generated files are normal Elixir source — readable, debuggable, jump-to-definition-friendly, suitable for checking in.
3. **No runtime dependency on `:flatbuf` for generated code.** A project can `mix flatbuf.gen` the schema, commit the output, and remove `:flatbuf` from their `mix.exs`. The emitted code includes a small generated wire-helper module under the user's chosen namespace; nothing in it references the `:flatbuf` library.
4. **Differential correctness against `flatc`.** Every wire-format claim we make is verified by round-tripping through the reference compiler in the test suite.
5. **Idiomatic Elixir on the surface.** Generated modules expose ordinary functions taking and returning maps/structs and binaries. The zero-copy reader story is still there — it sits underneath — but the default ergonomics match what Elixir authors expect from `protobuf` or `Jason`.

## 2. Non-goals

- **No runtime schema interpretation.** We are not building a generic decoder that takes a schema and a buffer at runtime and walks them. All schema knowledge is specialized into emitted Elixir at compile time.
- **No in-place mutation API.** The reference C++ implementation lets callers mutate a buffer in place. Elixir binaries don't mutate, and a "rebuild the buffer with this field changed" helper would only fake the semantics. We won't ship that pretense. (If it turns out a real use case wants it, it's a future addition.)
- **No FlatBuffers RPC transport.** We parse `rpc_service` declarations and surface them as data (so other tooling can build on top), but we do not implement an RPC layer.
- **No FlexBuffers in v1.** FlexBuffers is a separate, schema-less format that ships in the same upstream repo. It deserves its own library; mentioning it here only to be clear it's out of scope for `flatbuf`.

## 3. Architecture

```
+---------------+    +---------------+    +-------------------+    +---------------+
| .fbs source   | -> | Schema parser | -> | Schema IR         | -> | Code generator|
+---------------+    +---------------+    | (semantic model)  |    +-------+-------+
                                          +-------------------+            |
                                                                           v
                                                                +----------------------+
                                                                | Emitted .ex files    |
                                                                |  - per-table modules |
                                                                |  - per-struct modules|
                                                                |  - per-enum modules  |
                                                                |  - per-union modules |
                                                                |  - <Root>.Wire helper|
                                                                +----------------------+
```

Five layers, with a clean cut between each:

1. **Parser** (`Flatbuf.Schema.Parser`) — `.fbs` text → concrete syntax tree. A hand-written lexer plus recursive-descent parser (no parser-combinator dependency). No semantic checks at this layer.
2. **Resolver** (`Flatbuf.Schema.Resolver`) — CST → fully-resolved IR. Resolves `include` statements, namespaces, name references, attribute validation, default-value typing, vtable slot assignment, enum value computation, union variant tagging. Produces a `%Flatbuf.Schema{}` value that is the single source of truth for codegen.
3. **Codegen** (`Flatbuf.Codegen.*`) — IR → strings of Elixir source. Subdivided per emitted artifact: `Codegen.Table`, `Codegen.Struct`, `Codegen.Enum`, `Codegen.Union`, `Codegen.Wire`. No I/O here.
4. **Mix integration** (`Mix.Tasks.Flatbuf.Gen`, `Mix.Tasks.Compile.Flatbuf`) — finds schema files, calls the pipeline, writes `.ex` files, manages caching/manifest so unchanged schemas don't re-emit.
5. **Optional runtime niceties** (`Flatbuf.*` protocols/behaviours) — opt-in, lives in the library, generated code only references them when the user configures it.

The hard rule between layers 1–3 and 4–5: layers 1–3 are pure functions over data. They have no notion of Mix, file I/O, or the surrounding project. This makes them straightforward to test on string inputs and to reuse from other contexts (a future Livebook integration, for instance).

## 4. Runtime dependency model

The defining constraint: **emitted code is self-contained**.

**What the generated code references:**
- Standard library only (`Bitwise`, binary syntax, `:erlang`).
- A single generated helper module — `Flatbuf.Generated.Wire` unless overridden with `--wire-module` — containing primitive read/write operations on binaries. This module is itself emitted as a `.ex` file, owned by the user's project, regenerated when its (very stable) source template changes.
- Nothing from `:flatbuf`. Not even an `alias`. A user can delete `:flatbuf` from their deps and the generated code keeps compiling and running.

**What lives in `:flatbuf` and never leaves it:**
- Parser, resolver, codegen, mix tasks.
- The verifier generator (because it's part of codegen).
- The optional protocols and behaviours described below.

**Opt-in runtime niceties** (configured per generator run, default off):
- `Flatbuf.Table` behaviour — `@callback decode(binary) :: {:ok, struct} | {:error, term}` plus encode/verify. Lets external tooling enumerate flatbuffer types by `Code.ensure_loaded?/1` + `function_exported?/3`.
- `Jason.Encoder` derivation for generated structs (requires the consumer to depend on `:jason`).
- (Future, unimplemented: `Flatbuf.Encoder` / `Flatbuf.Decoder` protocols for generic dispatch, and an `Inspect` impl.)

When enabled, generated modules get `@behaviour Flatbuf.Table` / `@derive Jason.Encoder`, which adds the corresponding compile-time dependency. When disabled (default), the generated code is pristine and dep-free. Niceties currently apply to the whole generator run; per-schema-file control is a future refinement.

## 5. Public API surface

### 5.1 Mix tasks

```
mix flatbuf.gen SCHEMA.fbs [SCHEMA.fbs ...] [--out PATH] [--namespace NAME]
                           [--niceties protocols,behaviours]
                           [--wire-module NAME] [--force]

mix flatbuf.gen.check         # exit nonzero if regeneration would change files (for CI)
```

A `Mix.Tasks.Compile.Flatbuf` compiler is also provided for users who don't want to check generated code in: register `compilers: [:flatbuf | Mix.compilers()]` in `mix.exs` and configure schema paths under `config :my_app, :flatbuf`.

The compiler keeps a manifest file (`_build/<env>/lib/<app>/.mix/compile.flatbuf`) tracking the schema hash → emitted file list; writes are gated on content changes and stale outputs get cleaned up. `mix flatbuf.gen` is manifest-free — it writes what you ask for and renames leave old files behind (use the compiler if you want stale-output cleanup).

### 5.2 Shape of generated modules

For `namespace MyGame.Sample; table Monster { hp:short = 100; name:string; }`:

```elixir
defmodule MyGame.Sample.Monster do
  @moduledoc "Generated from monster.fbs. Do not edit."

  defstruct hp: 100, name: nil, ...

  @type t :: %__MODULE__{hp: integer(), name: String.t() | nil, ...}

  @doc "Decode a full buffer (root_type Monster) into a struct."
  @spec decode(binary()) :: {:ok, t()} | {:error, term()}
  def decode(buf), do: ...

  @doc "Encode a struct or map into a complete buffer."
  @spec encode(t() | map()) :: {:ok, binary()} | {:error, term()}
  def encode(value), do: ...

  @doc "Verify a buffer is structurally valid as a Monster."
  @spec verify(binary()) :: :ok | {:error, term()}
  def verify(buf), do: ...

  # Zero-copy field accessors. Take (buffer, table_offset). Cheap.
  def hp(buf, offset), do: ...
  def name(buf, offset), do: ...
end
```

`decode/1` materializes a struct (eager). The per-field accessors stay available for users who want zero-copy reads. Both styles coexist; neither is hidden.

For builders, the generated module exposes both a high-level `encode/1` and a lower-level `Builder` API for assembling nested tables without intermediate structs:

```elixir
{:ok, builder} = MyGame.Sample.Monster.Builder.new()
{:ok, name_off} = MyGame.Sample.Monster.Builder.string(builder, "Sword")
{:ok, builder}  = MyGame.Sample.Monster.Builder.put(builder, :name, name_off)
{:ok, builder}  = MyGame.Sample.Monster.Builder.put(builder, :hp, 80)
{:ok, buf}      = MyGame.Sample.Monster.Builder.finish(builder)
```

(Final API shape is a 7.2 open question; the above is illustrative.)

## 6. Component breakdown

### 6.1 Schema parser — `Flatbuf.Schema.Parser`

`.fbs` grammar, per the upstream reference (`flatbuffers/docs/source/Schemas.md` and `flatbuffers/src/idl_parser.cpp`). Hand-written lexer + recursive-descent parser.

Tokens:
- Identifiers, integer literals (decimal, hex `0x`, binary `0b`; leading-zero literals are decimal, matching `flatc` 25.x), float literals (incl. `nan`, `inf`, `-inf`, leading/trailing-dot forms), string literals (JSON escapes incl. `\uXXXX` with surrogate pairs, plus `\xHH`), boolean literals, `null`. Malformed and non-UTF-8 input produce tagged errors, never exceptions.
- Reserved keywords: `table`, `struct`, `enum`, `union`, `namespace`, `root_type`, `attribute`, `file_identifier`, `file_extension`, `include`, `rpc_service`, `true`, `false`, `null`.

Productions:
- File: zero-or-more top-level declarations.
- Top-level: `include "path";` | `namespace dotted.name;` | `attribute "name";` | type decl | `root_type Name;` | `file_identifier "XXXX";` | `file_extension "xxx";` | `rpc_service` block.
- `table Name { field_decl* }` — fields with optional defaults and attribute lists.
- `struct Name { field_decl* }` — same syntax, restricted semantics (no defaults, no scalars-only-and-structs).
- `enum Name : underlying_type { ident (= int)? (, ident (= int)?)* }`.
- `union Name (: underlying_type)? { TypeRef (= int)? (, TypeRef (= int)?)* }` — variants may be table types, struct types (post-1.12), or `string` (post-1.12); the optional underlying type (an integral scalar or declared enum) widens the discriminator.
- `field_decl : type (= default)? (attribute_list)? ;`.
- Type references: scalars, `string`, `[T]` (vector of T), user-defined name (resolved later), `[T]:N` (fixed-size array, struct-fields only).
- Attribute list: `( name (: value)? (, ...)* )`.
- Doc comments: `///` lines aggregated and attached to the following declaration. `//` line comments and `/* */` block comments are discarded.

Parser produces a CST that preserves source spans for error reporting.

### 6.2 Resolver — `Flatbuf.Schema.Resolver`

Walks the CST and produces a normalized `%Flatbuf.Schema{}`. Responsibilities:

- **Include resolution.** Recursively load `include "..."` paths relative to the including file, with cycle detection.
- **Namespace handling.** `namespace` declarations apply to all subsequent declarations until the next `namespace`. Types are addressed by their fully-qualified name.
- **Name resolution.** Every `TypeRef` in a field declaration is resolved to a concrete declaration. Forward references are allowed within a file.
- **Vtable slot assignment.** Default slot order is declaration order (slot 4, 6, 8, ... — voffset_t aligned). Explicit `(id: N)` attributes override; we validate that explicit ids are contiguous and non-conflicting.
- **Default value typing.** A `= 100` on a `short` field is typed as i16; on a `float` field as f32; on an enum field as a variant. Validation of representability.
- **Enum value computation.** Implicit increment from previous, hex literal support, `bit_flags` attribute mode (powers of two).
- **Union variant tagging.** Each variant gets a discriminator (0 is `NONE`); the default discriminator type is `u8` (1..255 variants), and an explicit underlying type (`union U : int32`) widens it — discriminators are read/written at the underlying type's full width, matching `flatc`'s generated-code contract. Union fields in tables expand into two vtable slots: the type scalar and the value offset.
- **Attribute validation.** Semantically load-bearing attributes are validated: `id` (all-or-none, consecutive, unions take two), `required` (rejected on scalars), `force_align` (power of two, within bounds), `bit_flags` (shift range), `hash`, `key`, `shared`, `nested_flatbuffer`, `deprecated`. Language-binding attributes (`native_*`, `cpp_*`, `csharp_partial`, `private`, `streaming`, `idempotent`, ...) and user-declared attributes are passed through unchecked.
- **Struct layout.** Compute field offsets and total size with the FlatBuffers alignment rules (each field aligned to its natural size; struct aligned to its largest member; `force_align` overrides).
- **Root type, file identifier, file extension.** Stored on the schema record.

The resolver is also where well-formedness errors get raised with source spans: duplicate field names, unknown types, struct fields with disallowed types (vectors, strings, tables), invalid union variants, default values out of range, `required` on scalar fields, etc.

### 6.3 Code generator — `Flatbuf.Codegen.*`

One sub-module per emitted artifact kind. Each takes the IR and returns `{module_name, source_string}`. The mix layer takes those strings and writes files.

- `Codegen.Wire` — emits the `<Root>.Flatbuf.Wire` module with primitives: `read_u8/2`, `read_u16/2`, ..., `read_f64/2`, `read_string/2`, `read_vector_offset/2`, `read_vtable_field/3`, `align_to/2`, plus the builder primitives `write_u8/3` etc. and `Builder` state record. Same module template every project; only the module name varies.
- `Codegen.Enum` — straight-shot: a module with `defstruct`-less constants, encoder/decoder helpers, `bit_flags` set operations when applicable.
- `Codegen.Struct` — fixed-layout reader/writer. Each field at its computed offset.
- `Codegen.Table` — the workhorse. Emits:
  - `defstruct` with typed `@type t`.
  - Per-field accessors (zero-copy, take `(buf, offset)`).
  - `decode/1` that materializes the struct (walks vtable, recurses into nested tables/vectors/unions).
  - `encode/1` that calls into the `Builder` and finishes a complete buffer.
  - `verify/1` that bounds-checks every offset, vector length, and string length the table reaches transitively.
  - `Builder` companion module (`<Table>.Builder`) for nested assembly.
- `Codegen.Union` — discriminator + variant dispatch. Generated as a module with `decode/3` (taking discriminator + value offset + buf) and an `encode/2` that returns `{discriminator, offset}`.
- `Codegen.Reflection` — emit a constant containing the schema as a `reflection.fbs`-shaped term. Available for tools that want to introspect (and used for self-tests; see §10).

### 6.4 Wire helper — `<Root>.Flatbuf.Wire`

Generated, not hand-shipped. Contains all binary primitives. Roughly:

```elixir
def read_u32(buf, offset),
  do: <<v::little-32>> = binary_part(buf, offset, 4); v

def read_vtable_field(buf, table_offset, slot) do
  vt_rel = <<rel::little-signed-32>> = binary_part(buf, table_offset, 4); rel
  vt_offset = table_offset - vt_rel
  vt_size = read_u16(buf, vt_offset)
  if slot >= vt_size, do: 0,
    else: read_u16(buf, vt_offset + slot)
end

def read_string(buf, offset) do
  uoffset = read_u32(buf, offset)
  abs = offset + uoffset
  len = read_u32(buf, abs)
  binary_part(buf, abs + 4, len)
end
```

Same module template every project. We do not inline these helpers into each table module — that would massively bloat output and hurt readability. We emit one Wire module per project namespace and let everyone in that project share it.

### 6.5 Verifier

Generated alongside the reader. For each table, walks every field that has an offset (strings, vectors, sub-tables, unions, nested flatbuffers) and checks:

1. The offset's target is within the buffer, including inline fields: every present vtable slot (scalar, enum, inline struct, union discriminator) is checked against the table's inline area.
2. For vectors: the length is sane (`length * elem_size + 4 <= buffer_end - vec_offset`).
3. For strings: the null terminator is present after the length-counted bytes, and the byte slice is within bounds.
4. For unions: the discriminator selects a variant we know, and the variant's offset is verified per its type. Vector-of-union fields must have both parallel vectors present with equal element counts.
5. For sub-tables: recurse, with a depth limit (`max_depth:` option on `verify/2`, default 64). uoffsets are forward-only on this wire, so true cycles cannot occur; the depth limit bounds recursion on adversarial chains.
6. For `required` fields: the vtable slot is non-zero.

Deliberate deviation: the verifier does not alignment-check targets. Misaligned reads are safe on the BEAM (no faults, no UB); a buffer we accept could in principle be rejected by a stricter C++ verifier, but nothing we *emit* is misaligned.

Verifier errors are `{:error, reason, path}` where `reason` is a tagged tuple, e.g. `{:inline_field_out_of_bounds, voffset, len, inline_size}`, and `path` is a root-first list of field atoms, vector indices, and union variant atoms locating the failure, e.g. `[:inventory, 3, :name]` (buffer-level failures carry `[]`).

### 6.6 Object API (decode/encode of structs)

This is what most users will reach for first. `decode/1` and `encode/1` on each table module. Built on top of the zero-copy accessors for the read side, on top of `Builder` for the write side.

Decoding policy:
- Missing optional fields → default value (or `nil` for non-scalar references).
- `required` field missing → `{:error, {:missing_required, ...}}`.
- Vectors decode to lists. (Streams as a future addition under niceties.)
- Strings decode to binaries.
- Nested tables decode recursively.
- Unions decode to `{variant_module, decoded}` tuples.
- Enums decode to atoms when defined as a closed set; numeric otherwise (e.g. `bit_flags` set).

Encoding accepts maps for ergonomics — users don't have to construct the struct first. Unknown keys are ignored; missing keys take defaults. Encoding validates `required` presence and scalar ranges/types before writing, returning tagged error tuples.

### 6.7 JSON converter

`flatc` ships JSON↔binary conversion. We do the same, generated per-schema so the JSON shape matches the upstream convention exactly (this is the basis of our differential testing — see §10).

Generated as a module with `to_json/1` and `from_json/1` on each table. Optionally registers `Jason.Encoder` impls when the niceties flag is on.

## 7. Feature coverage matrix

Every row here is in scope. The "Phase" column orders implementation work — see §9.

### 7.1 Wire-format features

| Feature | Phase |
|---|---|
| Little-endian primitive encoding (u8/u16/u32/u64, i8/i16/i32/i64, f32/f64, bool) | 1 |
| Strings (length-prefixed, null-terminated) | 1 |
| Tables (vtable, soffset_t, voffset_t slot layout) | 1 |
| Structs (fixed inline layout, alignment) | 1 |
| Vectors of scalars | 1 |
| Vectors of strings | 1 |
| Vectors of tables | 2 |
| Vectors of structs | 2 |
| Enums (closed set) | 1 |
| Enums with `bit_flags` | 2 |
| Unions (table variants) | 2 |
| Unions (with string variant) | 2 |
| Unions (with struct variant) | 2 |
| Vectors of unions | 3 |
| Fixed-size arrays in structs (`[T]:N`) | 2 |
| Optional scalars (`?` types — explicit presence) | 2 |
| File identifier (4-byte marker at offset 4) | 2 |
| File extension | 2 |
| Size-prefixed buffers | 2 |
| Nested flatbuffers (`nested_flatbuffer` attribute) | 3 |
| 64-bit offsets / `(vector64)` for large vectors | 3 |
| `force_align` on structs | 2 |
| `force_align` on tables/vectors | 3 |
| `required` field enforcement | 2 |
| `deprecated` field handling (skip in encode, accept in decode) | 2 |
| `key` attribute (sortable-by, binary-search helpers) | 3 |
| `shared` strings (string deduplication in builder) | 3 |
| `hash` attribute (compile-time hash of name) | 3 |

### 7.2 Schema-language features

| Feature | Phase |
|---|---|
| Tables, structs, enums | 1 |
| Unions | 2 |
| Union underlying types (`union U : int32`) | 3 |
| `namespace` declarations | 1 |
| `include "path";` with recursive resolution | 1 |
| `root_type` declaration | 1 |
| `file_identifier`, `file_extension` | 2 |
| Default values (int, float, bool, enum, null) | 1 |
| Doc comments (`///`) preserved into `@doc` | 1 |
| Attribute declarations (`attribute "name";`) | 2 |
| Built-in attributes (full list in §6.2) | 2 |
| `rpc_service` blocks (parsed, surfaced as data, no transport) | 3 |
| Integer literals: decimal, hex, binary, octal | 1 |
| Float literals incl. `nan`, `inf`, `-inf` | 1 |
| Forward references within a file | 1 |
| Cross-file references via `include` | 1 |

### 7.3 Tooling

| Feature | Phase |
|---|---|
| `mix flatbuf.gen` | 1 |
| Per-schema niceties config (protocols/behaviours opt-in) | 2 |
| `Mix.Tasks.Compile.Flatbuf` mix compiler | 2 |
| Manifest-based incremental regeneration | 2 |
| `mix flatbuf.gen.check` (CI gate) | 2 |
| JSON converter codegen | 2 |
| Reflection-fbs emission | 3 |

## 8. Wire format reference (concise)

For implementors. Authoritative source: `flatbuffers/docs/source/Internals.md`.

- **Endianness:** little-endian everywhere.
- **Primitive sizes:** u8/i8/bool=1, u16/i16=2, u32/i32/f32=4, u64/i64/f64=8.
- **Alignment:** every value is aligned to its own size. Structs aligned to their largest member (or `force_align` if larger).
- **uoffset_t:** unsigned 32-bit, *relative*, points forward to a target. Found at table fields that reference sub-objects (strings, vectors, tables) and at the root.
- **soffset_t:** signed 32-bit, used at the start of a table to point *backward* to its vtable. `vtable_position = table_position - soffset`.
- **voffset_t:** unsigned 16-bit, used inside vtables to indicate field offset within a table (0 = field absent).
- **Vtable layout:** `[u16 vtable_size_bytes, u16 inline_table_size_bytes, u16 slot0_offset, u16 slot1_offset, ...]`. Vtables are deduplicated across a buffer when identical.
- **Table layout:** `[i32 soffset_to_vtable, ...field bytes packed per vtable slot offsets...]`.
- **Struct layout:** no vtable. Fields packed inline at their computed offsets. Total size known at compile time.
- **String layout:** `[u32 length, length bytes, u8 null_terminator]`. Null terminator is not counted in the length.
- **Vector layout:** `[u32 element_count, count * element_size bytes (each aligned to element alignment)]`.
- **Root:** `[u32 uoffset_to_root_table, optional 4-byte file_identifier, ...]`. The root uoffset is at buffer offset 0 (or 4 for size-prefixed buffers).
- **Size-prefixed buffer:** `[u32 total_size, ...standard root layout...]`. Size excludes itself.
- **64-bit offsets:** new in flatbuffers 23.x. Vectors annotated `(vector64)` use u64 length and u64 offsets. Restricted to byte-vectors and vectors of scalars; cannot appear in unions or as root.
- **Union layout in tables:** every union field occupies *two* vtable slots — first a u8 discriminator, then a uoffset to the variant value. Vtable slot for the discriminator is at slot N, value at slot N+2. Vectors of unions are similarly two parallel vectors: a `[u8]` of discriminators and a `[uoffset]` of values, exposed in the schema as a single field.

## 9. Phasing

We commit to all three phases. The order exists to deliver a usable thing fast and to surface architectural problems early — not to defer features indefinitely.

### Phase 1 — Vertical slice that reads and writes `monster_test.fbs` minus unions

Goal: end-to-end pipeline working on the canonical schema, exercising tables, structs, scalars, strings, vectors, enums, namespaces, includes, and defaults. Differential test against `flatc` on the simple Monster fields.

Deliverables:
- Parser covering everything except `union`, `rpc_service`, `attribute` decls, `file_identifier`, `file_extension`, fixed-size arrays, optional scalars, `bit_flags`.
- Resolver for the same subset.
- Codegen for tables, structs, enums, and the Wire helper.
- `mix flatbuf.gen` (manual invocation; manifest comes later).
- Object API decode/encode for everything in scope.
- Test suite: vendored `monster_test.fbs`, decode upstream `monsterdata_test.mon`, encode and round-trip via `flatc --json`.

### Phase 2 — Full schema language, full table features, mix integration, verifier, JSON

Goal: feature-complete for the typical FlatBuffers schema. Verifier present. JSON converter present. Niceties opt-in. Mix compiler available.

Deliverables:
- Unions (all variant kinds), optional scalars, fixed-size arrays, `bit_flags`, `required`, `deprecated`, `force_align` on structs, all built-in attributes the resolver needs to know about.
- File identifier and size-prefixed buffers.
- Verifier generation for all generated types.
- JSON converter generation.
- `Mix.Tasks.Compile.Flatbuf` compiler with manifest-based incremental regeneration.
- `mix flatbuf.gen.check` for CI.
- Niceties config (protocols/behaviours opt-in per schema).
- Property-based test harness (StreamData) plumbed against `flatc`.

### Phase 3 — Long-tail features and ergonomics

Goal: everything that's spec but rare, plus the rough edges polished.

Deliverables:
- Vectors of unions.
- 64-bit offsets / `(vector64)`.
- Nested flatbuffers (`nested_flatbuffer` attribute).
- `key` attribute with generated binary-search helpers.
- `shared` strings (builder-side dedup).
- `force_align` on tables and vectors.
- `rpc_service` data surface.
- Reflection-fbs emission, self-test via reflection.
- Verifier fuzz corpus (custom; upstream has none).
- Performance pass on the builder (the reverse-construction path is the obvious hot loop).

## 10. Testing & conformance plan

The library is correct iff `flatc` says it is. Concretely:

1. **Upstream corpus.** The `flatbuffers` test schemas and binaries, fetched by `mix flatbuf.fetch_fixtures` as a shallow sparse clone into the gitignored `test/fixtures/upstream/`, pinned to a release tag. Without the corpus, `mix test` runs the offline subset and prints a notice; CI runs both profiles.
2. **`flatc` as oracle.** The matching `flatc` release is auto-downloaded per platform by `mix flatbuf.fetch_flatc` (override with `$FLATBUF_FLATC`). Tests shell out via `System.cmd/3`. Two directions, both covered:
   - Elixir encode → `flatc --json --raw-binary` → compare JSON to the source (the encode-oracle suite spans the feature matrix: scalars, strings, vectors, structs, fixed arrays, enums/bit_flags, unions incl. vectors, nesting, file identifiers, size prefixes, key sorting, shared strings, force_align).
   - `flatc --binary` → Elixir decode → compare against the source JSON (the fixture round-trip suite over the upstream corpus, including buffers produced by other language ports).
3. **Byte-exact comparison is opt-in only.** Vtable layout and string interning are implementation-defined. Default to semantic (JSON-level) comparison; mark byte-exact tests explicitly when the layout is deterministic.
4. **Property-based tests.** StreamData generators driven by the schema IR — given a resolved schema, produce arbitrary valid value maps (full scalar ranges, unions, vectors, optionals) and round-trip them: encode→decode equality against a predicted result, encode→verify, encode→`flatc --json`, and `flatc --binary`→decode. Catches encoder/decoder asymmetry beyond the hand-picked oracle cases.
5. **Reflection self-test.** Parse `reflection.fbs` with our parser, generate Elixir for it, then have our parser parse `monster_test.fbs`, emit a `reflection.fbs`-shaped binary using our generated `reflection.fbs` codec, and ask our generated codec to decode it. Closes the loop on both parser and codegen.
6. **Verifier fuzz.** Custom corpus — truncated buffers, oob offsets, oversized lengths, byte flips, vtables claiming sizes past buffer end. Every input must return `:ok` or an error tuple, never crash or read OOB (asserted with plain rescue/catch around `verify/1`).
7. **Codegen drift.** `mix flatbuf.gen.check` fails CI when regenerating committed output would change it, and a formatter-idempotency test pins the emitted style. (Golden-file snapshots of generated source remain a possible addition.)

## 11. Open design questions

Decisions to make before Phase 2; flagged here so they don't get made by accident.

1. **Builder API shape.** Imperative-with-token (`{:ok, builder} = ...; ...; finish(builder)`), monadic pipe (`builder |> string("x") |> put(:name, ...) |> finish()`), or callback-style (`Monster.build(fn b -> ... end)`). Last is most ergonomic; first is closest to upstream and easiest to debug. Probably ship both with the callback wrapping the imperative core.
2. **Generated struct vs map.** Default to struct (typed, `@type t` works). Allow `--no-struct` for users who want raw maps and don't want a compile dependency between schema modules and their callers.
3. **Wire module ownership.** One Wire module per `--namespace` root vs. one per `.fbs` file. Probably per root, to avoid duplication; needs a clear story for projects that span multiple roots.
4. **Atom enums.** Decode small closed-set enums to atoms. But atoms are not GC'd — what about enums with thousands of values (rare but legal)? Threshold? Configurable?
5. **Behaviour vs. protocol for the niceties layer.** Behaviours give compile-time check of `decode/encode` presence; protocols give polymorphism. We probably want both, with the protocol delegating to the behaviour callback when implemented.
6. **`Inspect` impl content.** The full decoded struct, or a buffer-summary like `#FlatBuffer<Monster, 124 bytes>`? Configurable, default to the latter — printing a large nested flatbuffer accidentally is a real footgun.
7. **`encode/1` accepting `nil` for absent fields vs. omitting the key.** Both should work; need to make sure the chosen shape is consistent with how `decode/1` returns absent fields.
8. **Source span propagation in errors.** Parser errors get spans; resolver errors should too; verifier errors at runtime get a path (`[:monster, :inventory, 3]`) instead of a span. Document the distinction.

---

End of spec. Reviewing/amending this file is the prerequisite for any non-trivial PR — if a change to `flatbuf` invalidates a claim here, the spec is updated in the same PR.
