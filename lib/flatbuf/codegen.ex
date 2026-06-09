defmodule Flatbuf.Codegen do
  @moduledoc """
  Entry point for code generation.

  Given a resolved `%Flatbuf.Schema{}` and options, produces a list of
  `{module_name, source}` pairs covering the Wire helper plus one module
  per enum, struct, and table.
  """

  alias Flatbuf.Codegen
  alias Flatbuf.Schema

  @type nicety :: :behaviour | :jason

  @type options :: [
          wire_module: module(),
          namespace: String.t() | nil,
          niceties: [nicety()]
        ]

  @type artifact :: {module(), String.t()}

  @doc """
  Generate all artifacts for the schema.

  Options:

    * `:wire_module` (required) — module name for the emitted wire
      helper. Every generated table aliases this module.
    * `:namespace` (optional) — string like `"Arrow.Ipc.Flatbuf"`. When
      set, every generated module's name uses the override as its
      root, with the schema type's short name appended. The original
      namespace in the `.fbs` file is ignored.
    * `:niceties` (optional, default `[]`) — list of atoms enabling
      opt-in protocols/behaviours on generated *root* tables:
        * `:behaviour` — `@behaviour Flatbuf.Table`.
        * `:jason` — `@derive Jason.Encoder` on the table struct.
  """
  @spec generate(Schema.t(), options()) :: [artifact()]
  def generate(%Schema{} = schema, opts) do
    wire_module = Keyword.fetch!(opts, :wire_module)
    namespace = Keyword.get(opts, :namespace)
    niceties = Keyword.get(opts, :niceties, [])
    codegen_opts = [wire_module: wire_module, namespace: namespace, niceties: niceties]

    wire = [Codegen.Wire.generate(wire_module)]

    enums = Enum.map(Schema.enums(schema), &Codegen.Enum.generate(&1, codegen_opts))

    structs =
      Enum.map(Schema.structs(schema), &Codegen.Struct.generate(&1, schema, codegen_opts))

    unions =
      Enum.map(Schema.unions(schema), &Codegen.Union.generate(&1, schema, codegen_opts))

    tables =
      Enum.map(Schema.tables(schema), &Codegen.Table.generate(&1, schema, codegen_opts))

    Enum.map(wire ++ enums ++ structs ++ unions ++ tables, fn {mod, source} ->
      {mod, format_source(source)}
    end)
  end

  # Pipe each emitted source through `Code.format_string!/1`. The
  # template-and-EEx flavor of codegen here happily produces
  # inconsistent indentation, bracketed keyword lists, and
  # 700-char-wide type specs — running the formatter once at the
  # end is much cheaper than getting every emit site to do the
  # right thing.
  defp format_source(source) do
    IO.iodata_to_binary([Code.format_string!(source), ?\n])
  end
end
