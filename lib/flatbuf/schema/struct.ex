defmodule Flatbuf.Schema.Struct do
  @moduledoc """
  A FlatBuffers `struct` declaration.

  Structs have fixed inline layout; `layout` is the list of per-field
  positions, sizes, and alignments computed during resolution. `size` and
  `align` are the totals.
  """

  alias Flatbuf.Schema.Field

  @type field_layout :: %{
          field: Field.t(),
          offset: non_neg_integer(),
          size: non_neg_integer(),
          align: non_neg_integer()
        }

  @type t :: %__MODULE__{
          name: String.t(),
          namespace: String.t() | nil,
          short_name: String.t(),
          fields: [Field.t()],
          layout: [field_layout()],
          size: non_neg_integer(),
          align: non_neg_integer(),
          attributes: map(),
          docs: [String.t()]
        }

  defstruct name: nil,
            namespace: nil,
            short_name: nil,
            fields: [],
            layout: [],
            size: 0,
            align: 1,
            attributes: %{},
            docs: []
end
