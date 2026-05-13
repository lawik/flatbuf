# flatbuf

Pure-Elixir [FlatBuffers](https://flatbuffers.dev) with compile-time,
file-emitting codegen.

Schemas (`.fbs` files) are translated to standalone Elixir modules: one
module per table, struct, enum, and union, plus a single wire-helper
module. The generated source is normal Elixir — readable, debuggable,
jump-to-definition-friendly — and depends on **nothing** at runtime.
You can `mix flatbuf.gen`, commit the output, and drop `:flatbuf` from
your `deps` without breaking anything.

The spec coverage and design rationale live in [`SPEC.md`](SPEC.md).

> Status: alpha. The wire format is implemented; the test suite
> round-trips against the upstream `flatc` corpus. Phase 3 features
> (vectors of unions, 64-bit offsets, `nested_flatbuffer`,
> `key`/`shared`/`hash` attributes) are not yet implemented.

## Installation

Add `:flatbuf` to `deps`:

```elixir
def deps do
  [
    {:flatbuf, "~> 0.1.0", only: [:dev, :test], runtime: false}
  ]
end
```

`only: [:dev, :test]` is the recommended placement — the library is a
codegen tool. Generated modules don't reference it.

## Quick start

Given `priv/fbs/monster.fbs`:

```text
namespace MyApp.Schema;

table Monster {
  hp: short = 100;
  name: string (required);
}

root_type Monster;
file_identifier "MONS";
```

Generate Elixir source:

```sh
mix flatbuf.gen priv/fbs/monster.fbs --out lib --wire-module MyApp.Schema.Wire
```

The output is two files: `lib/my_app/schema/wire.ex` and
`lib/my_app/schema/monster.ex`. From your code:

```elixir
{:ok, bin} = MyApp.Schema.Monster.encode(%{hp: 80, name: "Sword"})
{:ok, %MyApp.Schema.Monster{} = m} = MyApp.Schema.Monster.decode(bin)
:ok = MyApp.Schema.Monster.verify(bin)
```

## Mix tasks

### `mix flatbuf.gen`

Write `.ex` files from schemas. Run it by hand, or wire it into your
build via the compiler (below) so generated code doesn't need to be
checked in.

```text
mix flatbuf.gen SCHEMA.fbs [SCHEMA.fbs ...]
                [--out PATH]
                [--wire-module NAME]
                [--namespace NAME]
                [--include PATH]
                [--niceties LIST]
                [--force]
```

Key flags:

- `--out PATH` — output directory (default `lib`).
- `--namespace NAME` — replace the schema's own namespace when
  emitting modules. Useful for vendoring an upstream schema (e.g.
  Apache Arrow) under your project's tree.
- `--include PATH` — extra search path for `include "..."`
  (repeatable; mirrors `flatc -I`).
- `--niceties LIST` — opt-in: `behaviour`, `jason`. See below.

### `mix flatbuf.gen.check`

CI gate. Re-runs codegen in memory and exits non-zero if any committed
file would change. Drop it into CI after your tests step:

```sh
mix flatbuf.gen.check priv/fbs/monster.fbs --out lib --wire-module MyApp.Schema.Wire
```

### `Mix.Tasks.Compile.Flatbuf`

A Mix compiler for projects that prefer regenerated-on-build over
committed-output. Wire it into `mix.exs`:

```elixir
def project do
  [
    # ...
    compilers: [:flatbuf | Mix.compilers()]
  ]
end
```

And configure schema paths in `config/config.exs`:

```elixir
config :my_app, :flatbuf,
  schemas: ["priv/fbs/monster.fbs"],
  out: "lib/my_app/schema",
  namespace: "MyApp.Schema",
  wire_module: "MyApp.Schema.Wire",
  include: ["priv/fbs"],
  niceties: [:behaviour]
```

The compiler stores a manifest under
`_build/<env>/lib/<app>/.mix/compile.flatbuf` and only regenerates a
schema when its source, options, or output have drifted. Schemas
removed from `:schemas` have their previous outputs cleaned up on the
next compile.

## Generated API

Every emitted table gets these functions (any table can serve as the
root of a nested_flatbuffer or freestanding buffer):

- `decode/1`, `decode_size_prefixed/1` — eagerly materialize a struct.
- `encode/1`, `encode_size_prefixed/1` — build a buffer from a struct
  or map. `(required)` fields are enforced; missing one returns
  `{:error, {:flatbuf_required, :field_name}}`.
- `verify/1`, `verify_size_prefixed/1` — bounds-check every offset
  before any reader follows it. Missing required fields are reported
  as `{:error, {:missing_required, :field_name}}`.
- `to_json/1`, `from_json/1` — flatc-shaped JSON, for diffing against
  the reference compiler.
- `decode_at/2`, `build/2`, and per-field accessors — used by parent
  tables and available directly for zero-copy reads.
- `file_identifier/0` — the schema's 4-byte identifier, if declared.

## Niceties

Off by default. Enable per-schema with `--niceties`:

- `behaviour` — every emitted table implements `Flatbuf.Table`. Lets
  external tooling enumerate flatbuffer types via
  `Code.ensure_loaded?` + `behaviour_info/1`.
- `jason` — every emitted table struct `@derive`s `Jason.Encoder`.
  Encodes the decoded shape (atoms + scalars + nested structs)
  through the standard `Jason` pipeline. For flatc-shaped output,
  use the generated `to_json/1` instead.

When neither is enabled (the default), generated tables reference no
external libraries. The library only ships the behaviour module
itself; the `:jason` derive only activates when the dep is present.

## Testing against `flatc`

The conformance suite round-trips every binary/JSON pair in the
upstream `google/flatbuffers` test corpus through our generated code,
with outcomes tracked in `test/fixtures/fixture_manifest.exs`. Set up
the corpus once:

```sh
mix flatbuf.fetch_fixtures
mix flatbuf.fetch_flatc
mix test
```

The manifest is committed; a regression flips a known-good fixture to
`{:error, ...}` and CI fails.

## License

Apache-2.0.
