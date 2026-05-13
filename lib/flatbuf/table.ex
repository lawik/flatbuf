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
  `verify/1` regardless — the behaviour just makes those callbacks
  contractual and gives you a `t/0` typespec to lean on.

  The behaviour attaches to *every* generated table when the nicety is
  enabled. Any table can serve as the root of a nested_flatbuffer or a
  freestanding buffer; the schema's `root_type` declaration is a hint
  about the canonical root, not a restriction on which tables can act
  as one.
  """

  @type t :: struct()

  @callback decode(binary()) :: {:ok, t()} | {:error, term()}
  @callback encode(t() | map()) :: {:ok, binary()} | {:error, term()}
  @callback verify(binary()) :: :ok | {:error, term()}
end
