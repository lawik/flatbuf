defmodule Flatbuf.Table do
  @moduledoc """
  Opt-in behaviour that generated FlatBuffers table modules implement
  when the project enables the `:behaviour` nicety.

  Enabling it (via `--niceties behaviour` on `mix flatbuf.gen`, or
  `niceties: [:behaviour]` in `compile.flatbuf` config) gives external
  tooling a single way to enumerate flatbuffer types:

      Code.ensure_loaded?(MyApp.Schema.Monster) and
        function_exported?(MyApp.Schema.Monster, :__flatbuf_table__, 0)

  Generated tables already expose `decode/1`, `encode/1`, and
  `verify/2` (with a default-argument head that also exports
  `verify/1`) regardless — the behaviour just makes those callbacks
  contractual and gives you a `t/0` typespec to lean on.

  The behaviour attaches to *every* generated table when the nicety is
  enabled. Any table can serve as the root of a nested_flatbuffer or a
  freestanding buffer; the schema's `root_type` declaration is a hint
  about the canonical root, not a restriction on which tables can act
  as one.
  """

  @type t :: struct()

  @typedoc """
  Root-first location of the field a verifier error refers to: field
  atoms, vector indices (integers), and union variant atoms. The path
  starts at the root table's first field; failures detected before any
  field is reached (bad root offset, bad vtable) carry `[]`.
  """
  @type verify_path :: [atom() | non_neg_integer()]

  @callback decode(binary()) :: {:ok, t()} | {:error, term()}
  @callback encode(t() | map()) :: {:ok, binary()} | {:error, term()}
  @callback verify(binary()) :: :ok | {:error, term(), verify_path()}
  @callback verify(binary(), opts :: keyword()) :: :ok | {:error, term(), verify_path()}

  @optional_callbacks verify: 2
end
