defmodule Flatbuf.Codegen.Enum do
  @moduledoc """
  Emits an Elixir module for a FlatBuffers `enum` declaration.

  The module exposes `value/1` (atom → integer), `from_value/1` (integer
  → atom or nil), and `all/0` (list of variants). Variants keep their
  source-spelled atoms — `:Red`, not `:red` — to avoid surprising casing
  conversions.
  """

  alias Flatbuf.Schema.Enum, as: SchemaEnum

  @spec generate(SchemaEnum.t()) :: {module(), String.t()}
  def generate(%SchemaEnum{} = enum) do
    module_name = Enum.map_join(String.split(enum.name, "."), ".", &Macro.camelize/1)
    module_atom = Module.concat([module_name])

    variant_clauses =
      Enum.map_join(enum.variants, "", fn {name, value} ->
        """
            def value(#{inspect(name)}), do: #{value}
        """
      end)

    from_value_clauses =
      Enum.map_join(enum.variants, "", fn {name, value} ->
        """
            def from_value(#{value}), do: #{inspect(name)}
        """
      end)

    all_list = Enum.map_join(enum.variants, ", ", fn {name, _} -> inspect(name) end)
    types = Enum.map_join(enum.variants, " | ", fn {n, _} -> inspect(n) end)

    source = """
    defmodule #{module_name} do
      @moduledoc "Generated from FlatBuffers enum #{enum.name}. Do not edit."

      @type t :: #{types}

      @doc "Return the integer value of a variant."
      @spec value(t()) :: integer()
    #{variant_clauses}
      @doc "Return the variant for an integer value, or `nil`."
      @spec from_value(integer()) :: t() | nil
    #{from_value_clauses}    def from_value(_), do: nil

      @doc "List all variants in declared order."
      @spec all() :: [t()]
      def all, do: [#{all_list}]

      @doc false
      def __flatbuf__(:underlying_type), do: #{inspect(enum.underlying_type)}

      # JSON helpers: flatc emits enum values as the variant name string.
      @doc false
      def __to_json__(atom) when is_atom(atom), do: Atom.to_string(atom)

      def __to_json__(int) when is_integer(int) do
        case from_value(int) do
          nil -> int
          atom -> Atom.to_string(atom)
        end
      end

      @doc false
      def __from_json__(name) when is_binary(name) do
        atom = String.to_atom(name)
        if atom in all(), do: atom, else: raise("unknown #{enum.name} variant: " <> name)
      end

      def __from_json__(int) when is_integer(int) do
        from_value(int) || raise("unknown #{enum.name} value: " <> Integer.to_string(int))
      end
    end
    """

    {module_atom, source}
  end
end
