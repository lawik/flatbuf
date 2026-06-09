# flatbuf

Pure-Elixir [FlatBuffers](https://flatbuffers.dev). Schemas compile to
plain `.ex` files — generate, commit, drop the dep.

> Status: alpha. Round-trips the upstream `flatc` test corpus; design
> and spec coverage live in [`SPEC.md`](SPEC.md), known gaps in
> [Limitations](#limitations).

## Install

```elixir
{:flatbuf, "~> 0.1.0", only: [:dev, :test], runtime: false}
```

## Use

`priv/fbs/monster.fbs`:

```
namespace MyApp.Schema;

table Monster {
  hp: short = 100;
  name: string (required);
}

root_type Monster;
```

```sh
mix flatbuf.gen priv/fbs/monster.fbs --out lib --wire-module MyApp.Schema.Wire
```

```elixir
{:ok, bin} = MyApp.Schema.Monster.encode(%{hp: 80, name: "Sword"})
{:ok, m}   = MyApp.Schema.Monster.decode(bin)
:ok        = MyApp.Schema.Monster.verify(bin)
json       = MyApp.Schema.Monster.to_json(m)
```

Every table also gets `encode_size_prefixed/1` + friends, `decode_at/2`,
`build/2` for nested-buffer assembly, and per-field accessors.

Regenerate on build by adding `:flatbuf` to `compilers:` and configuring
schemas under `config :my_app, :flatbuf, schemas: [...]`. `mix
flatbuf.gen.check` is the CI gate. `mix help flatbuf.gen` has the flags.

## Limitations

- 64-bit offsets / `(vector64)` — parsed but encoded as 32-bit.
- Optional-scalar presence — `= null` decodes to `nil`, but absent and
  explicit-zero look the same on the wire.
- `force_align` on tables — works for structs and vectors, not table soffsets.
- `rpc_service` — parsed, no client/server codegen.
- `to_json/1` f32 strings — same bits as flatc, longer decimals.
- FNV-64 hashes follow the spec but aren't differentially tested against flatc.

## License

Apache-2.0.
