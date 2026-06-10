defmodule Flatbuf.Schema.Union do
  @moduledoc """
  A FlatBuffers `union` declaration.

  `variants` is a list of `{atom_name, type_spec, discriminator_int}`
  triples in declaration order. Discriminator 0 is reserved for `NONE`
  (the absent state); variants get 1, 2, … starting from the first
  declared, unless the schema assigns explicit values (`A = 555`).

  `underlying_type` is the integral scalar that carries the
  discriminator on the wire (`union U : int { … }`, since upstream
  v23.5.8). It defaults to the historical `:u8`; an explicit underlying
  type widens both the table's type field and the element size of a
  vector-of-union's types vector. A signed underlying type permits
  negative discriminator values.

  Variant `type_spec` is one of `{:table, fqn}`, `{:struct, fqn}` (since
  upstream v1.12), or `:string` (also since v1.12).
  """

  @type underlying :: :i8 | :u8 | :i16 | :u16 | :i32 | :u32 | :i64 | :u64

  @type variant :: {atom(), Flatbuf.Schema.type_spec(), integer()}

  @type t :: %__MODULE__{
          name: String.t(),
          namespace: String.t() | nil,
          short_name: String.t(),
          underlying_type: underlying(),
          variants: [variant()],
          attributes: map(),
          docs: [String.t()]
        }

  defstruct name: nil,
            namespace: nil,
            short_name: nil,
            underlying_type: :u8,
            variants: [],
            attributes: %{},
            docs: []
end
