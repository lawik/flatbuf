defmodule Flatbuf.Schema.Union do
  @moduledoc """
  A FlatBuffers `union` declaration.

  `variants` is a list of `{atom_name, type_spec, discriminator_int}`
  triples in declaration order. Discriminator 0 is reserved for `NONE`
  (the absent state); variants get 1, 2, … starting from the first
  declared.

  Variant `type_spec` is one of `{:table, fqn}`, `{:struct, fqn}` (since
  upstream v1.12), or `:string` (also since v1.12).
  """

  @type variant :: {atom(), Flatbuf.Schema.type_spec(), pos_integer()}

  @type t :: %__MODULE__{
          name: String.t(),
          namespace: String.t() | nil,
          short_name: String.t(),
          variants: [variant()],
          attributes: map(),
          docs: [String.t()]
        }

  defstruct name: nil,
            namespace: nil,
            short_name: nil,
            variants: [],
            attributes: %{},
            docs: []
end
