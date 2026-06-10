defmodule Flatbuf.Schema.Field do
  @moduledoc """
  A single field in a `table` or `struct`.

  `vtable_slot` is the byte offset within the table's vtable (4, 6, 8, ...).
  It's `nil` for struct fields, which use inline offsets in
  `Flatbuf.Schema.Struct.layout`.
  """

  @type t :: %__MODULE__{
          name: atom(),
          type: Flatbuf.Schema.type_spec(),
          default: any(),
          vtable_slot: non_neg_integer() | nil,
          attributes: map(),
          docs: [String.t()],
          line: pos_integer() | nil
        }

  defstruct name: nil,
            type: nil,
            default: nil,
            vtable_slot: nil,
            attributes: %{},
            docs: [],
            line: nil
end
