defmodule Flatbuf.Codegen do
  @moduledoc """
  Entry point for code generation.

  Given a resolved `%Flatbuf.Schema{}` and options, produces a list of
  `{module_name, source}` pairs covering the Wire helper plus one module
  per enum, struct, and table.
  """

  alias Flatbuf.Codegen
  alias Flatbuf.Schema

  @type options :: [
          wire_module: module(),
          namespace: module() | nil
        ]

  @type artifact :: {module(), String.t()}

  @doc """
  Generate all artifacts for the schema.
  """
  @spec generate(Schema.t(), options()) :: [artifact()]
  def generate(%Schema{} = schema, opts) do
    wire_module = Keyword.fetch!(opts, :wire_module)
    codegen_opts = [wire_module: wire_module]

    wire = [Codegen.Wire.generate(wire_module)]

    enums = Enum.map(Schema.enums(schema), &Codegen.Enum.generate/1)

    structs =
      Enum.map(Schema.structs(schema), &Codegen.Struct.generate(&1, schema, codegen_opts))

    tables =
      Enum.map(Schema.tables(schema), &Codegen.Table.generate(&1, schema, codegen_opts))

    wire ++ enums ++ structs ++ tables
  end
end
