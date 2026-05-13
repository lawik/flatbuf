defmodule Flatbuf.Schema.Enum do
  @moduledoc """
  A FlatBuffers `enum` declaration.

  `variants` is a list of `{atom_name, integer_value}` pairs in source
  order; values may be implicit (incremented from the previous) or explicit.
  `bit_flags?` is true if the schema declared `(bit_flags)`.
  """

  @type t :: %__MODULE__{
          name: String.t(),
          namespace: String.t() | nil,
          short_name: String.t(),
          underlying_type: Flatbuf.Schema.scalar(),
          variants: [{atom(), integer()}],
          attributes: map(),
          docs: [String.t()],
          bit_flags?: boolean()
        }

  defstruct name: nil,
            namespace: nil,
            short_name: nil,
            underlying_type: :i32,
            variants: [],
            attributes: %{},
            docs: [],
            bit_flags?: false
end
