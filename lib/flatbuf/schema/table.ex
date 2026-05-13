defmodule Flatbuf.Schema.Table do
  @moduledoc """
  A FlatBuffers `table` declaration.

  `name` is fully-qualified (e.g. `"MyGame.Sample.Monster"`).
  `short_name` is just the last segment.
  """

  alias Flatbuf.Schema.Field

  @type t :: %__MODULE__{
          name: String.t(),
          namespace: String.t() | nil,
          short_name: String.t(),
          fields: [Field.t()],
          attributes: map(),
          docs: [String.t()]
        }

  defstruct name: nil,
            namespace: nil,
            short_name: nil,
            fields: [],
            attributes: %{},
            docs: []
end
