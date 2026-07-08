# flatbuf

Pure-Elixir [FlatBuffers](https://flatbuffers.dev). Schemas compile to
plain `.ex` files — generate, commit, drop the dep.

> Status: alpha. Decodes the upstream `flatc` test corpus and the
> encoders are differentially tested against `flatc` across the
> feature matrix; see [Limitations](#limitations) for what's out of
> scope and what's not done yet.

Heavy use of LLM in development. Don't assume human intent.

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

`--niceties behaviour` and `--niceties jason` opt into
`@behaviour Flatbuf.Table` / `@derive Jason.Encoder` on generated
modules. Both add a compile-time requirement to *your* project:
`jason` needs `:jason` in your deps, and `behaviour` needs `:flatbuf`
available wherever the generated code compiles (so not with the
dev/test-only dep line above). The default output is dependency-free.

Regenerate on build by adding `:flatbuf` to `compilers:` and configuring
schemas under `config :my_app, :flatbuf, schemas: [...]`. `mix
flatbuf.gen.check` is the CI gate. `mix help flatbuf.gen` has the flags.

## Limitations

By design:

- No runtime schema interpretation. All schema knowledge is compiled
  into the emitted modules; there is no generic walk-a-buffer-with-a-
  schema decoder.
- No in-place mutation API. Elixir binaries don't mutate; a
  "rebuild with this field changed" helper would only fake the
  semantics, so we don't ship the pretense.
- No FlexBuffers (a separate, schema-less format — out of scope).
- `rpc_service` — parsed and surfaced as data, no client/server
  codegen or transport.
- The verifier does not alignment-check offsets. Misaligned reads are
  safe on the BEAM, and nothing this library emits is misaligned —
  but a buffer we accept could in principle be rejected by a stricter
  C++ verifier. Verifier errors are `{:error, reason, path}`;
  recursion depth is bounded (`max_depth:` option, default 64).
- `mix flatbuf.gen` is manifest-free: it writes what you ask for, and
  renames leave old files behind. Use the `:flatbuf` Mix compiler if
  you want stale-output cleanup.
- `force_align` on tables — ignored (as `flatc` does); honored on
  structs and vectors.
- Encoding ignores unknown keys in input maps; missing keys take the
  schema defaults.

Not done yet:

- 64-bit offsets / `(vector64)` — parsed but encoded as 32-bit.
- Union underlying types (`union U : int32 { ... }`) — supported with
  full-width discriminators (what `flatc`'s generated code does), but
  `flatc`'s own JSON tooling doesn't implement the feature, so no
  text-level interop for such schemas.
- `to_json/1` f32 strings — same bits as flatc, longer decimals.
- FNV-64 hashes follow the spec but aren't differentially tested against flatc.
- Property tests and the `flatc` differential suites need the test
  corpus and a `flatc` binary; a fresh clone runs the offline subset
  and prints how to fetch them.

## License

Apache-2.0.
