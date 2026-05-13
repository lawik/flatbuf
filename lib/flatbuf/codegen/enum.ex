defmodule Flatbuf.Codegen.Enum do
  @moduledoc """
  Emits an Elixir module for a FlatBuffers `enum` declaration.

  The module exposes `value/1` (atom → integer) and `from_value/1`
  (integer → atom-or-nil). Variants keep their source-spelled atoms
  (`:Red`, not `:red`) to avoid surprising casing conversions.

  For `(bit_flags)` enums, `value/1` accepts a *list* of variants and
  OR's their bit values; `from_value/1` returns the list of variants
  present in the supplied integer.
  """

  alias Flatbuf.Codegen.Naming
  alias Flatbuf.Schema.Enum, as: SchemaEnum

  @spec generate(SchemaEnum.t(), keyword()) :: {module(), String.t()}
  def generate(enum, opts \\ [])

  def generate(%SchemaEnum{bit_flags?: true} = enum, opts), do: generate_bit_flags(enum, opts)
  def generate(%SchemaEnum{} = enum, opts), do: generate_plain(enum, opts)

  defp generate_plain(%SchemaEnum{} = enum, opts) do
    module_name = Naming.module_name(enum.name, Keyword.get(opts, :namespace))
    module_atom = Module.concat([module_name])

    variant_clauses =
      Enum.map_join(enum.variants, "", fn {name, value} ->
        "    def value(#{inspect(name)}), do: #{value}\n"
      end)

    from_value_clauses =
      Enum.map_join(enum.variants, "", fn {name, value} ->
        "    def from_value(#{value}), do: #{inspect(name)}\n"
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
      def __flatbuf__(:bit_flags?), do: false

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

  # bit_flags enum: value/1 accepts an atom OR a list of atoms (OR'd),
  # from_value/1 always returns a list of present variants.
  defp generate_bit_flags(%SchemaEnum{} = enum, opts) do
    module_name = Naming.module_name(enum.name, Keyword.get(opts, :namespace))
    module_atom = Module.concat([module_name])

    atom_value_clauses =
      Enum.map_join(enum.variants, "", fn {name, value} ->
        "    defp atom_value(#{inspect(name)}), do: #{value}\n"
      end)

    all_pairs =
      Enum.map_join(enum.variants, ", ", fn {name, value} ->
        "{#{inspect(name)}, #{value}}"
      end)

    all_list = Enum.map_join(enum.variants, ", ", fn {name, _} -> inspect(name) end)
    types = "[#{Enum.map_join(enum.variants, " | ", fn {n, _} -> inspect(n) end)}]"

    source = """
    defmodule #{module_name} do
      @moduledoc \"\"\"
      Generated from FlatBuffers bit_flags enum #{enum.name}. Do not edit.

      Values are powers of two; the decoder returns the *list* of
      variants present in the integer, the encoder accepts a list and
      OR's their bit values.
      \"\"\"

      import Bitwise

      @type t :: #{types}
      @type variant :: #{Enum.map_join(enum.variants, " | ", fn {n, _} -> inspect(n) end)}

      @doc \"Return the integer value of a flag combination (atom or list).\"
      @spec value(variant() | t()) :: integer()
      def value(atom) when is_atom(atom), do: atom_value(atom)
      def value(list) when is_list(list), do: Enum.reduce(list, 0, fn a, acc -> acc ||| atom_value(a) end)

    #{atom_value_clauses}    defp atom_value(_), do: 0

      @doc \"Return the list of variants present in an integer.\"
      @spec from_value(integer()) :: t()
      def from_value(int) when is_integer(int) do
        for {atom, v} <- [#{all_pairs}], v != 0 and (int &&& v) == v, do: atom
      end

      @doc \"List all variants in declared order.\"
      @spec all() :: [variant()]
      def all, do: [#{all_list}]

      @doc false
      def __flatbuf__(:underlying_type), do: #{inspect(enum.underlying_type)}
      def __flatbuf__(:bit_flags?), do: true

      @doc false
      # Empty flag set: flatc emits `0` (integer), not an empty string.
      def __to_json__([]), do: 0
      def __to_json__(list) when is_list(list), do: Enum.map_join(list, " ", &Atom.to_string/1)
      def __to_json__(int) when is_integer(int), do: __to_json__(from_value(int))

      @doc false
      def __from_json__(""), do: []
      def __from_json__(s) when is_binary(s) do
        s
        |> String.split(" ", trim: true)
        |> Enum.map(fn name ->
          atom = String.to_atom(name)
          if atom in all(), do: atom, else: raise("unknown #{enum.name} variant: " <> name)
        end)
      end

      def __from_json__(int) when is_integer(int), do: from_value(int)
    end
    """

    {module_atom, source}
  end
end
