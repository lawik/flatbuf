defmodule Flatbuf.Codegen.Struct do
  @moduledoc """
  Emits an Elixir module for a FlatBuffers `struct` declaration.

  Structs have fixed inline layout — the generated module knows every
  field's offset, size, and alignment at compile time. The reader uses
  position arithmetic, the writer constructs a single binary.
  """

  alias Flatbuf.Codegen.Naming
  alias Flatbuf.Schema
  alias Flatbuf.Schema.Enum, as: SchemaEnum
  alias Flatbuf.Schema.Struct, as: SchemaStruct

  @spec generate(SchemaStruct.t(), Schema.t(), keyword()) :: {module(), String.t()}
  def generate(%SchemaStruct{} = s, %Schema{} = schema, opts) do
    wire_module = Keyword.fetch!(opts, :wire_module)
    # The `:namespace` override is threaded explicitly (trailing `ns`
    # arg) through every helper that maps FQNs to module names.
    ns = Keyword.get(opts, :namespace)
    module_name = fqn_to_module(s.name, ns)
    module_atom = Module.concat([module_name])

    defstruct_fields = build_defstruct(s)
    type_spec = build_type_spec(s, schema, ns)
    decode_body = build_decode(s, schema, ns)
    encode_body = build_encode(s, schema, ns)
    array_helpers = build_array_helpers(s, schema, ns)
    to_json_body = build_to_json_map(s, schema, ns)
    from_json_body = build_from_json_map(s, schema, ns)

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

      @doc false
      def __to_json_map__(value) when is_map(value) do
        %{
    #{to_json_body}    }
      end

      @doc false
      def __from_json_map__(map) when is_map(map) do
        %__MODULE__{
    #{from_json_body}    }
      end

    #{array_helpers}end
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
  defp default_for({:array, _, _}), do: []
  defp default_for(_), do: nil

  defp build_type_spec(s, schema, ns) do
    parts =
      Enum.map(s.fields, fn f ->
        "#{f.name}: #{type_for(f.type, schema, ns)}"
      end)

    "%__MODULE__{" <> Enum.join(parts, ", ") <> "}"
  end

  defp type_for({:scalar, :bool}, _, _ns), do: "boolean()"
  defp type_for({:scalar, k}, _, _ns) when k in [:f32, :f64], do: "float()"
  defp type_for({:scalar, _}, _, _ns), do: "integer()"

  defp type_for({:enum, fqn}, _, ns) do
    fqn_to_module(fqn, ns) <> ".t()"
  end

  defp type_for({:struct, fqn}, _, ns) do
    fqn_to_module(fqn, ns) <> ".t()"
  end

  defp type_for({:array, inner, _n}, schema, ns) do
    "[#{type_for(inner, schema, ns)}]"
  end

  defp type_for(_, _, _ns), do: "any()"

  defp build_decode(s, schema, ns) do
    s.layout
    |> Enum.map_join("", fn entry ->
      f = entry.field
      read_expr = decode_at_expr(f.type, "pos + #{entry.offset}", schema, ns)
      "      #{f.name}: #{read_expr},\n"
    end)
    |> trim_trailing_comma()
  end

  defp decode_at_expr({:scalar, kind}, pos_expr, _schema, _ns),
    do: "Wire.read_#{kind}(buf, #{pos_expr})"

  defp decode_at_expr({:enum, fqn}, pos_expr, schema, ns) do
    %SchemaEnum{underlying_type: u} = Schema.fetch(schema, fqn)
    "#{fqn_to_module(fqn, ns)}.from_value(Wire.read_#{u}(buf, #{pos_expr}))"
  end

  defp decode_at_expr({:struct, fqn}, pos_expr, _schema, ns),
    do: "#{fqn_to_module(fqn, ns)}.decode_at(buf, #{pos_expr})"

  defp decode_at_expr({:array, inner, n}, pos_expr, schema, ns) do
    {elem_size, _} = scalar_or_struct_size_align(inner, schema)
    inner_decoder = decode_at_expr(inner, "(#{pos_expr}) + i * #{elem_size}", schema, ns)
    "(for i <- 0..#{n - 1}, do: #{inner_decoder})"
  end

  defp scalar_or_struct_size_align({:scalar, kind}, _),
    do: {Schema.scalar_size(kind), Schema.scalar_size(kind)}

  defp scalar_or_struct_size_align({:enum, fqn}, schema) do
    %SchemaEnum{underlying_type: u} = Schema.fetch(schema, fqn)
    sz = Schema.scalar_size(u)
    {sz, sz}
  end

  defp scalar_or_struct_size_align({:struct, fqn}, schema) do
    %SchemaStruct{size: size, align: align} = Schema.fetch(schema, fqn)
    {size, align}
  end

  defp scalar_or_struct_size_align({:array, inner, n}, schema) do
    {sz, al} = scalar_or_struct_size_align(inner, schema)
    {sz * n, al}
  end

  defp build_encode(s, schema, ns) do
    # Build the binary in source-declared order using pure binary syntax.
    # Padding is emitted as a `0::size(N)` bit-spec — not a nested
    # binary literal, which Elixir parses as a `>>` operator soup.
    binary_parts =
      Enum.map(s.layout, fn entry ->
        f = entry.field
        pad = entry.offset - inferred_pos(s.layout, entry)
        pad_part = if pad > 0, do: "0::size(#{pad * 8})", else: ""
        value_part = encode_field_part(f, schema, ns)

        case pad_part do
          "" -> value_part
          _ -> "#{pad_part}, #{value_part}"
        end
      end)

    tail_pad = s.size - tail_offset_after_last(s.layout)
    tail = if tail_pad > 0, do: ", 0::size(#{tail_pad * 8})", else: ""

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

  # Every scalar headed for the wire goes through `Wire.check_scalar!/3`
  # first — Elixir binary construction truncates out-of-range integers
  # silently, and a struct encoder built from `<<v::little-16>>` parts
  # would otherwise corrupt data without a word. The throw is caught by
  # the enclosing table's generated `encode/1`.
  defp encode_field_part(f, schema, ns) do
    val = "Map.get(value, #{inspect(f.name)}, #{inspect(default_for(f.type))})"

    case f.type do
      {:scalar, :bool} ->
        "(if #{checked(val, :bool, f.name)}, do: 1, else: 0)::8"

      {:scalar, kind} ->
        "(#{checked(val, kind, f.name)})::#{scalar_bin_spec(kind)}"

      {:enum, fqn} ->
        %SchemaEnum{underlying_type: u} = Schema.fetch(schema, fqn)
        spec = scalar_bin_spec(u)
        "(#{checked("#{fqn_to_module(fqn, ns)}.value(#{val})", check_kind(u), f.name)})::#{spec}"

      {:struct, fqn} ->
        "(#{fqn_to_module(fqn, ns)}.encode(#{val}))::binary"

      {:array, _inner, _n} ->
        # Encoded by a per-field helper; here we just splice its result.
        "(__encode_arr_#{f.name}(value))::binary"
    end
  end

  defp checked(val_expr, kind, field_name),
    do: "Wire.check_scalar!(#{val_expr}, #{inspect(kind)}, #{inspect(field_name)})"

  # Enums with a bool underlying type carry 0/1 ints out of `value/1`.
  defp check_kind(:bool), do: :u8
  defp check_kind(kind), do: kind

  # ----------------------------------------------------------------------
  # Fixed-size array helpers (one defp per array-typed struct field)
  # ----------------------------------------------------------------------

  defp build_array_helpers(s, schema, ns) do
    s.layout
    |> Enum.filter(fn entry -> match?({:array, _, _}, entry.field.type) end)
    |> Enum.map_join("\n", fn entry -> array_helper(entry.field, schema, ns) end)
  end

  defp array_helper(f, schema, ns) do
    {:array, inner, n} = f.type
    elem_default = inner_default(inner, schema)

    """
      defp __encode_arr_#{f.name}(value) do
        list = Map.get(value, #{inspect(f.name)}, [])
        list = list ++ List.duplicate(#{inspect(elem_default)}, max(0, #{n} - length(list)))
        list = Enum.take(list, #{n})
        for v <- list, into: <<>>, do: #{array_elem_bin(inner, "v", schema, f.name, ns)}
      end
    """
  end

  defp inner_default({:scalar, kind}, _), do: Schema.scalar_default(kind)
  defp inner_default({:enum, fqn}, schema), do: first_enum_atom(fqn, schema)
  defp inner_default({:struct, _}, _), do: %{}

  defp first_enum_atom(fqn, schema) do
    %SchemaEnum{variants: [{atom, _} | _]} = Schema.fetch(schema, fqn)
    atom
  end

  defp array_elem_bin({:scalar, :bool}, var, _, field_name, _ns),
    do: "<<(if #{checked(var, :bool, field_name)}, do: 1, else: 0)::8>>"

  defp array_elem_bin({:scalar, kind}, var, _, field_name, _ns),
    do: "<<(#{checked(var, kind, field_name)})::#{scalar_bin_spec(kind)}>>"

  defp array_elem_bin({:enum, fqn}, var, schema, field_name, ns) do
    %SchemaEnum{underlying_type: u} = Schema.fetch(schema, fqn)

    "<<(#{checked("#{fqn_to_module(fqn, ns)}.value(#{var})", check_kind(u), field_name)})::#{scalar_bin_spec(u)}>>"
  end

  defp array_elem_bin({:struct, fqn}, var, _, _field_name, ns),
    do: "#{fqn_to_module(fqn, ns)}.encode(#{var})"

  # ----------------------------------------------------------------------
  # JSON map builders
  # ----------------------------------------------------------------------

  defp build_to_json_map(s, schema, ns) do
    Enum.map_join(s.fields, "", fn f ->
      val = "Map.get(value, #{inspect(f.name)})"
      expr = json_value_expr(f.type, val, schema, ns)
      "      #{inspect(Atom.to_string(f.name))} => #{expr},\n"
    end)
  end

  defp build_from_json_map(s, schema, ns) do
    Enum.map_join(s.fields, "", fn f ->
      val = "Map.get(map, #{inspect(Atom.to_string(f.name))})"
      expr = json_from_value_expr(f.type, val, schema, ns)
      "      #{f.name}: #{expr},\n"
    end)
  end

  defp json_value_expr({:scalar, k}, val, _, _ns) when k in [:f32, :f64] do
    # NaN/Inf aren't valid JSON; emit as strings the way flatc does.
    "(case #{val} do :nan -> \"nan\"; :infinity -> \"inf\"; :neg_infinity -> \"-inf\"; v -> v end)"
  end

  defp json_value_expr({:scalar, _}, val, _, _ns), do: val

  defp json_value_expr({:enum, fqn}, val, _, ns),
    do: "#{fqn_to_module(fqn, ns)}.__to_json__(#{val})"

  defp json_value_expr({:struct, fqn}, val, _, ns),
    do: "#{fqn_to_module(fqn, ns)}.__to_json_map__(#{val})"

  defp json_value_expr({:array, inner, _n}, val, schema, ns) do
    inner_expr = json_value_expr(inner, "v", schema, ns)
    "Enum.map(#{val} || [], fn v -> #{inner_expr} end)"
  end

  defp json_from_value_expr({:scalar, k}, val, _, _ns) when k in [:f32, :f64] do
    "(case #{val} do \"nan\" -> :nan; \"inf\" -> :infinity; \"-inf\" -> :neg_infinity; v -> v end)"
  end

  defp json_from_value_expr({:scalar, _}, val, _, _ns), do: val

  defp json_from_value_expr({:enum, fqn}, val, _, ns),
    do: "#{fqn_to_module(fqn, ns)}.__from_json__(#{val})"

  defp json_from_value_expr({:struct, fqn}, val, _, ns),
    do: "#{fqn_to_module(fqn, ns)}.__from_json_map__(#{val})"

  defp json_from_value_expr({:array, inner, _n}, val, schema, ns) do
    inner_expr = json_from_value_expr(inner, "v", schema, ns)
    "Enum.map(#{val} || [], fn v -> #{inner_expr} end)"
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

  defp fqn_to_module(fqn, ns), do: Naming.module_name(fqn, ns)
end
