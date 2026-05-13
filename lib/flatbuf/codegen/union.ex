defmodule Flatbuf.Codegen.Union do
  @moduledoc """
  Emits an Elixir module for a FlatBuffers `union` declaration.

  The module owns the discriminator ↔ variant mapping and the two
  per-direction dispatch helpers:

  * `decode_variant/3` — given a discriminator integer and the
    referenced position in the buffer, return `{variant_atom, value}`.
  * `build_variant/3` — given a variant atom and a value, write it into
    the buffer and return `{builder, addr}` so the calling table can
    add `(discriminator, uoffset)` as a pair of fields.

  Variant 0 is always the implicit `:NONE`.
  """

  alias Flatbuf.Schema
  alias Flatbuf.Schema.Struct, as: SchemaStruct
  alias Flatbuf.Schema.Union

  @spec generate(Union.t(), Schema.t(), keyword()) :: {module(), String.t()}
  def generate(%Union{} = u, %Schema{} = schema, opts) do
    wire_module = Keyword.fetch!(opts, :wire_module)
    module_name = fqn_to_module(u.name)
    module_atom = Module.concat([module_name])

    type_spec = build_type_spec(u, schema)
    disc_clauses = build_disc_clauses(u)
    atom_clauses = build_atom_clauses(u)
    decode_clauses = build_decode_clauses(u, schema)
    build_clauses = build_build_clauses(u, schema)
    to_json_clauses = build_to_json_clauses(u)
    from_json_clauses = build_from_json_clauses(u)
    verify_clauses = build_verify_clauses(u)

    source = """
    defmodule #{module_name} do
      @moduledoc "Generated from FlatBuffers union #{u.name}. Do not edit."

      alias #{inspect(wire_module)}, as: Wire

      @type t :: #{type_spec}

      @doc "Integer discriminator for a variant atom (0 for :NONE)."
      @spec discriminator(atom()) :: non_neg_integer()
      def discriminator(:NONE), do: 0
    #{disc_clauses}
      @doc "Variant atom for an integer discriminator."
      @spec variant_atom(non_neg_integer()) :: atom() | nil
      def variant_atom(0), do: :NONE
    #{atom_clauses}  def variant_atom(_), do: nil

      @doc \"\"\"
      Decode a union value at `abs_pos`, given its discriminator. The
      `abs_pos` is the absolute target of the uoffset_t the table field
      stored — i.e. for a table variant, the table position; for a
      string variant, the start of the u32 length; for a struct variant,
      the start of the inline struct bytes.
      \"\"\"
      def decode_variant(_buf, 0, _abs_pos), do: nil
    #{decode_clauses}  def decode_variant(_buf, disc, _abs_pos), do: {:unknown_variant, disc}

      @doc \"\"\"
      Build a variant value into the builder. Returns `{builder, addr}`.
      For `:NONE`, returns `{builder, nil}`.
      \"\"\"
      def build_variant(b, :NONE, _value), do: {b, nil}
    #{build_clauses}
      # JSON helpers — used by table codegen for the paired `_type` and
      # value keys flatc emits.

      @doc false
      def __to_json_type__(nil), do: nil
      def __to_json_type__({variant, _value}), do: Atom.to_string(variant)

      @doc false
      def __to_json_value__(nil), do: nil
    #{to_json_clauses}
      @doc false
      def __from_json__(nil, _value), do: nil
      def __from_json__("NONE", _value), do: nil
    #{from_json_clauses}
      @doc false
      def __verify_variant__(_buf, 0, _abs_pos, _depth), do: :ok
    #{verify_clauses}  def __verify_variant__(_buf, disc, _abs_pos, _depth), do: {:error, {:unknown_union_variant, disc}}
    end
    """

    {module_atom, source}
  end

  defp build_type_spec(u, _schema) do
    parts =
      Enum.map(u.variants, fn {name, type, _disc} ->
        "{#{inspect(name)}, #{variant_type_t(type)}}"
      end)

    Enum.join(["nil" | parts], " | ")
  end

  defp variant_type_t({:table, fqn}), do: "#{fqn_to_module(fqn)}.t()"
  defp variant_type_t({:struct, fqn}), do: "#{fqn_to_module(fqn)}.t()"
  defp variant_type_t(:string), do: "String.t()"

  defp build_disc_clauses(u) do
    u.variants
    |> Enum.map_join("", fn {name, _type, disc} ->
      "  def discriminator(#{inspect(name)}), do: #{disc}\n"
    end)
  end

  defp build_atom_clauses(u) do
    u.variants
    |> Enum.map_join("", fn {name, _type, disc} ->
      "  def variant_atom(#{disc}), do: #{inspect(name)}\n"
    end)
  end

  defp build_decode_clauses(u, _schema) do
    u.variants
    |> Enum.map_join("", fn {name, type, disc} ->
      body =
        case type do
          {:table, fqn} ->
            "{#{inspect(name)}, #{fqn_to_module(fqn)}.decode_at(buf, abs_pos)}"

          {:struct, fqn} ->
            "{#{inspect(name)}, #{fqn_to_module(fqn)}.decode_at(buf, abs_pos)}"

          :string ->
            "{#{inspect(name)}, Wire.read_string_at(buf, abs_pos)}"
        end

      "  def decode_variant(buf, #{disc}, abs_pos), do: #{body}\n"
    end)
  end

  defp build_build_clauses(u, schema) do
    u.variants
    |> Enum.map_join("", fn {name, type, _disc} ->
      body =
        case type do
          {:table, fqn} ->
            "#{fqn_to_module(fqn)}.build(b, value)"

          {:struct, fqn} ->
            %SchemaStruct{align: al} = Schema.fetch(schema, fqn)
            "Wire.create_struct(b, #{fqn_to_module(fqn)}.encode(value), #{al})"

          :string ->
            "Wire.create_string(b, value)"
        end

      "  def build_variant(b, #{inspect(name)}, value), do: #{body}\n"
    end)
  end

  defp build_to_json_clauses(u) do
    u.variants
    |> Enum.map_join("", fn {name, type, _disc} ->
      expr =
        case type do
          {:table, fqn} -> "#{fqn_to_module(fqn)}.__to_json_map__(value)"
          {:struct, fqn} -> "#{fqn_to_module(fqn)}.__to_json_map__(value)"
          :string -> "value"
        end

      "  def __to_json_value__({#{inspect(name)}, value}), do: #{expr}\n"
    end)
  end

  defp build_from_json_clauses(u) do
    u.variants
    |> Enum.map_join("", fn {name, type, _disc} ->
      expr =
        case type do
          {:table, fqn} -> "{#{inspect(name)}, #{fqn_to_module(fqn)}.__from_json_map__(value)}"
          {:struct, fqn} -> "{#{inspect(name)}, #{fqn_to_module(fqn)}.__from_json_map__(value)}"
          :string -> "{#{inspect(name)}, value}"
        end

      "  def __from_json__(#{inspect(Atom.to_string(name))}, value), do: #{expr}\n"
    end)
  end

  defp build_verify_clauses(u) do
    u.variants
    |> Enum.map_join("", fn {_name, type, disc} ->
      expr =
        case type do
          {:table, fqn} ->
            "#{fqn_to_module(fqn)}.__verify_at__(buf, abs_pos, depth)"

          # Inline struct (struct-in-union) — depth-independent bounds check.
          {:struct, fqn} ->
            "Wire.verify_bounds(buf, abs_pos, #{fqn_to_module(fqn)}.__flatbuf__(:struct_size))"

          :string ->
            "Wire.verify_string_at(buf, abs_pos)"
        end

      "  def __verify_variant__(buf, #{disc}, abs_pos, depth), do: #{expr}\n"
    end)
  end

  defp fqn_to_module(fqn) do
    Enum.map_join(String.split(fqn, "."), ".", &Macro.camelize/1)
  end
end
