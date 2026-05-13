# Known problems / unfinished hooks

A scratchpad of issues hit while integrating flatbuf into downstream
projects. Each entry: what's broken, where, what the workaround is, and
how to fix it properly.

When an entry is resolved, leave a brief "Resolved" note with the
commit so the trail is visible without digging into history.

## Namespace override (`--namespace`)

**Resolved.** `mix flatbuf.gen --namespace NAME` rewrites every emitted
module's root namespace to `NAME`, regardless of the schema's own
`namespace` declaration. Cross-references inside generated code use
the override consistently, so no source rewriting is needed.

Also wired:

* `Codegen.generate/2` accepts `:namespace` directly.
* `mix flatbuf.gen --include PATH` now exposes flatc-style `-I` search
  paths through the CLI (previously only available programmatically).

For the Arrow case in `sprawl/arrow`, the sed workaround can be dropped
in favor of:

    mix flatbuf.gen priv/fbs/*.fbs \
      --out lib/arrow/ipc/flatbuf \
      --namespace Arrow.Ipc.Flatbuf \
      --wire-module Arrow.Ipc.Flatbuf.Wire \
      --include priv/fbs

See `test/flatbuf/namespace_override_test.exs` for the contract.

## Codegen quality: unused alias / unused variables

**Resolved.** No `mix clean && mix test` warnings on the current
codebase. Specifically:

* Union modules now only `alias Wire` when at least one variant is
  a string or struct (the only variant kinds that actually call into
  Wire); table-only unions skip the alias.
* Empty-table `decode_at/2` underscores `buf` / `pos` to silence the
  unused-variable warning the compiler would otherwise emit.
* Verifier `__verify_at__/3` uses `_depth` when the table has no
  field that recurses (no sub-tables, vectors of tables, or unions),
  matching the same convention.
* Union `__verify_variant__/4` underscores `_depth` per-variant for
  string and struct variants (only the table variant recurses).
* `bun` transitive dep was emitting "version not configured" at app
  load; pinned in `config/config.exs`.
