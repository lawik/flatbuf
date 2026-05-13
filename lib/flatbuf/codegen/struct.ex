defmodule Flatbuf.Codegen.Struct do
  @moduledoc """
  Emits an Elixir module for a FlatBuffers `struct` declaration.

  Structs have fixed inline layout — the generated module knows every
  field's offset, size, and alignment at compile time. The reader uses
  position arithmetic, the writer constructs a single binary.
  """

  alias Flatbuf.Schema
  alias Flatbuf.Schema.Enum, as: SchemaEnum
  alias Flatbuf.Schema.Struct, as: SchemaStruct

  @spec generate(SchemaStruct.t(), Schema.t(), keyword()) :: {module(), String.t()}
  def generate(%SchemaStruct{} = s, %Schema{} = schema, opts) do
    wire_module = Keyword.fetch!(opts, :wire_module)
    module_name = fqn_to_module(s.name)
    module_atom = Module.concat([module_name])

    defstruct_fields = build_defstruct(s)
    type_spec = build_type_spec(s, schema)
    decode_body = build_decode(s, schema, wire_module)
    encode_body = build_encode(s, schema)

    source = """
    defmodule #{module_name} do
      @moduledoc "Generated from FlatBuffers struct #{s.name}. Do not edit."

      alias #{inspect(wire_module)}, as: Wire

      defstruct #{defstruct_fields}
      @type t :: #{type_spec}

      @doc false
      def __flatbuf__(:struct_size), do: #{s.size}
      def __flatbuf__(:struct_align), do: #{s.align}

      @doc "Decode a struct from `buf` at the given absolute position."
      @spec decode_at(binary(), non_neg_integer()) :: t()
      def decode_at(buf, pos) do
        %__MODULE__{
    #{decode_body}    }
      end

      @doc "Serialize this struct to a binary of exactly `#{s.size}` bytes."
      @spec encode(t() | map()) :: binary()
      def encode(value) do
        _ = value
    #{encode_body}  end
    end
    """

    {module_atom, source}
  end

  defp build_defstruct(s) do
    parts =
      Enum.map(s.fields, fn f ->
        "#{f.name}: #{inspect(default_for(f.type))}"
      end)

    "[" <> Enum.join(parts, ", ") <> "]"
  end

  defp default_for({:scalar, kind}), do: Schema.scalar_default(kind)
  defp default_for({:enum, _}), do: nil
  defp default_for({:struct, _}), do: nil
  defp default_for(_), do: nil

  defp build_type_spec(s, schema) do
    parts =
      Enum.map(s.fields, fn f ->
        "#{f.name}: #{type_for(f.type, schema)}"
      end)

    "%__MODULE__{" <> Enum.join(parts, ", ") <> "}"
  end

  defp type_for({:scalar, :bool}, _), do: "boolean()"
  defp type_for({:scalar, k}, _) when k in [:f32, :f64], do: "float()"
  defp type_for({:scalar, _}, _), do: "integer()"

  defp type_for({:enum, fqn}, _) do
    fqn_to_module(fqn) <> ".t()"
  end

  defp type_for({:struct, fqn}, _) do
    fqn_to_module(fqn) <> ".t()"
  end

  defp type_for(_, _), do: "any()"

  defp build_decode(s, schema, _wire_module) do
    s.layout
    |> Enum.map_join("", fn entry ->
      f = entry.field

      read_expr =
        case f.type do
          {:scalar, :u8} -> "Wire.read_u8(buf, pos + #{entry.offset})"
          {:scalar, :i8} -> "Wire.read_i8(buf, pos + #{entry.offset})"
          {:scalar, :u16} -> "Wire.read_u16(buf, pos + #{entry.offset})"
          {:scalar, :i16} -> "Wire.read_i16(buf, pos + #{entry.offset})"
          {:scalar, :u32} -> "Wire.read_u32(buf, pos + #{entry.offset})"
          {:scalar, :i32} -> "Wire.read_i32(buf, pos + #{entry.offset})"
          {:scalar, :u64} -> "Wire.read_u64(buf, pos + #{entry.offset})"
          {:scalar, :i64} -> "Wire.read_i64(buf, pos + #{entry.offset})"
          {:scalar, :f32} -> "Wire.read_f32(buf, pos + #{entry.offset})"
          {:scalar, :f64} -> "Wire.read_f64(buf, pos + #{entry.offset})"
          {:scalar, :bool} -> "Wire.read_bool(buf, pos + #{entry.offset})"
          {:enum, fqn} -> enum_read(entry.offset, fqn, schema)
          {:struct, fqn} -> "#{fqn_to_module(fqn)}.decode_at(buf, pos + #{entry.offset})"
        end

      "      #{f.name}: #{read_expr},\n"
    end)
    |> trim_trailing_comma()
  end

  defp enum_read(offset, fqn, schema) do
    %SchemaEnum{underlying_type: u} = Schema.fetch(schema, fqn)
    reader = "Wire.read_#{u}(buf, pos + #{offset})"
    "#{fqn_to_module(fqn)}.from_value(#{reader})"
  end

  defp build_encode(s, schema) do
    # Build the binary in source-declared order using pure binary syntax.
    binary_parts =
      Enum.map(s.layout, fn entry ->
        f = entry.field
        pad = entry.offset - inferred_pos(s.layout, entry)

        pad_part =
          if pad > 0 do
            "<<0::size(#{pad * 8})>>"
          else
            ""
          end

        value_part = encode_field_part(f, schema)

        case pad_part do
          "" -> value_part
          _ -> "#{pad_part}, #{value_part}"
        end
      end)

    tail_pad = s.size - tail_offset_after_last(s.layout)

    tail =
      if tail_pad > 0 do
        ", <<0::size(#{tail_pad * 8})>>"
      else
        ""
      end

    "    <<" <>
      Enum.join(binary_parts, ", ") <> tail <> ">>" <> "\n  "
  end

  defp inferred_pos([], _entry), do: 0

  defp inferred_pos(layout, entry) do
    case Enum.find_index(layout, &(&1 == entry)) do
      0 ->
        0

      i ->
        prev = Enum.at(layout, i - 1)
        prev.offset + prev.size
    end
  end

  defp tail_offset_after_last([]), do: 0

  defp tail_offset_after_last(layout) do
    last = List.last(layout)
    last.offset + last.size
  end

  defp encode_field_part(f, schema) do
    val = "Map.get(value, #{inspect(f.name)}, #{inspect(default_for(f.type))})"

    case f.type do
      {:scalar, :bool} ->
        "(if #{val}, do: 1, else: 0)::8"

      {:scalar, :u8} ->
        "(#{val})::8"

      {:scalar, :i8} ->
        "(#{val})::signed-8"

      {:scalar, :u16} ->
        "(#{val})::little-16"

      {:scalar, :i16} ->
        "(#{val})::little-signed-16"

      {:scalar, :u32} ->
        "(#{val})::little-32"

      {:scalar, :i32} ->
        "(#{val})::little-signed-32"

      {:scalar, :u64} ->
        "(#{val})::little-64"

      {:scalar, :i64} ->
        "(#{val})::little-signed-64"

      {:scalar, :f32} ->
        "(#{val})::little-float-32"

      {:scalar, :f64} ->
        "(#{val})::little-float-64"

      {:enum, fqn} ->
        %SchemaEnum{underlying_type: u} = Schema.fetch(schema, fqn)
        spec = scalar_bin_spec(u)
        "#{fqn_to_module(fqn)}.value(#{val})::#{spec}"

      {:struct, fqn} ->
        "(#{fqn_to_module(fqn)}.encode(#{val}))::binary"
    end
  end

  defp scalar_bin_spec(:bool), do: "8"
  defp scalar_bin_spec(:u8), do: "8"
  defp scalar_bin_spec(:i8), do: "signed-8"
  defp scalar_bin_spec(:u16), do: "little-16"
  defp scalar_bin_spec(:i16), do: "little-signed-16"
  defp scalar_bin_spec(:u32), do: "little-32"
  defp scalar_bin_spec(:i32), do: "little-signed-32"
  defp scalar_bin_spec(:u64), do: "little-64"
  defp scalar_bin_spec(:i64), do: "little-signed-64"
  defp scalar_bin_spec(:f32), do: "little-float-32"
  defp scalar_bin_spec(:f64), do: "little-float-64"

  defp trim_trailing_comma(s) do
    String.replace(s, ~r/,\n$/, "\n")
  end

  defp fqn_to_module(fqn) do
    Enum.map_join(String.split(fqn, "."), ".", &Macro.camelize/1)
  end
end
