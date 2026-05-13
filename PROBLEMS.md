# Known problems / unfinished hooks

A scratchpad of issues hit while integrating flatbuf into downstream
projects. Each entry: what's broken, where, what the workaround is, and
how to fix it properly.

## Namespace override option declared but not wired through

**Where:** `lib/flatbuf/codegen.ex:15`

The `options()` type lists `namespace: module() | nil` and the SPEC
(section 5.1) advertises `--namespace NAME` on `mix flatbuf.gen`, but
neither path is implemented:

- `Mix.Tasks.Flatbuf.Gen.run/1` doesn't parse `--namespace` (only
  `--out`, `--wire-module`, `--force`).
- `Flatbuf.Codegen.generate/2` accepts the option but ignores it. Every
  code-emitting module (`Codegen.Table`, `Codegen.Enum`, `Codegen.Union`,
  `Codegen.Struct`) builds the module name straight from the type's
  fully-qualified name as set by the `.fbs` file's `namespace`
  declaration — see `fqn_to_module/1` in each codegen module and
  `Flatbuf.Schema.Resolver.qualify/2`.

**Workaround (used in `sprawl/arrow`):** rewrite the `namespace` line
*and any fully-qualified type references* in the vendored `.fbs` source
before running codegen. For Arrow:

    sed -i 's/^namespace org.apache.arrow.flatbuf;$/namespace Arrow.Ipc.Flatbuf;/' priv/fbs/*.fbs
    sed -i 's/org\.apache\.arrow\.flatbuf\./Arrow.Ipc.Flatbuf./g' priv/fbs/*.fbs

That has to be re-run after every refresh from upstream Apache Arrow.

**Proper fix:** thread the option through. Probably:

1. Add `namespace: :string` to the OptionParser strict list in
   `Mix.Tasks.Flatbuf.Gen.run/1` and pass it into `Codegen.generate/2`.
2. In each `Codegen.*.generate/2,3`, take the override and prepend it to
   the FQN (or replace the leading namespace component) before
   `Macro.camelize`. Need to also rewrite cross-references inside the
   generated module bodies so they point at the same renamed targets.
3. Decide the semantics when the `.fbs` has no `namespace` (today the
   FQN is the bare type name; with `--namespace Foo` we'd presumably
   want `Foo.TypeName`).

## Codegen quality: unused alias / unused variables

**Where:** every generated module under
`lib/flatbuf/codegen/{table,struct,union,enum}.ex` emits
`alias <wire>, as: Wire` even when the resulting module doesn't reference
it (e.g. union modules dispatch to variant modules and never touch Wire
directly), and emits empty `decode_at(buf, pos)` bodies for
zero-field tables, leaving `buf` and `pos` unused.

**Downstream stance:** `sprawl/arrow` *does not* relax its lint settings
to accommodate this. Its `mix check` keeps `compile --warnings-as-errors`
and currently fails on these warnings — accepted as a known-failing
state pending the fix here, rather than papered over downstream.

**Proper fix:** in each codegen module, only emit the Wire alias when
the resulting body references it. For empty-table `decode_at`, underscore
the unused params (`_buf`, `_pos`).
