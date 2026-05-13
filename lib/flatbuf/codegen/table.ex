defmodule Flatbuf.Codegen.Table do
  @moduledoc """
  Emits an Elixir module for a FlatBuffers `table` declaration.

  The emitted module includes:

  * a `defstruct` matching the table's fields,
  * `decode/1` and `decode_at/2` returning the struct,
  * `encode/1` returning a complete buffer,
  * `build/2` for nested-table assembly inside an existing builder,
  * per-field zero-copy accessors.
  """

  alias Flatbuf.Schema
  alias Flatbuf.Schema.Enum, as: SchemaEnum
  alias Flatbuf.Schema.Struct, as: SchemaStruct
  alias Flatbuf.Schema.Table

  @spec generate(Table.t(), Schema.t(), keyword()) :: {module(), String.t()}
  def generate(%Table{} = t, %Schema{} = schema, opts) do
    wire_module = Keyword.fetch!(opts, :wire_module)
    is_root? = schema.root_type == t.name
    module_name = fqn_to_module(t.name)
    module_atom = Module.concat([module_name])

    defstruct_fields = build_defstruct(t, schema)
    type_spec = build_type_spec(t, schema)
    decode_at_body = build_decode_at(t, schema)
    accessor_funs = build_accessors(t, schema)
    build_body = build_encode_build(t, schema)
    encode_funs = build_encode_top(t, is_root?)

    source = """
    defmodule #{module_name} do
      @moduledoc "Generated from FlatBuffers table #{t.name}. Do not edit."

      alias #{inspect(wire_module)}, as: Wire

      defstruct #{defstruct_fields}
      @type t :: #{type_spec}
    #{encode_funs}
      @doc "Decode a table at absolute position `pos` within `buf`."
      @spec decode_at(binary(), non_neg_integer()) :: t()
      def decode_at(buf, pos) do
        %__MODULE__{
    #{decode_at_body}    }
      end

      @doc "Build this table inside an existing builder. Returns `{builder, addr}`."
      def build(builder, value) when is_map(value) do
    #{build_body}  end

    #{accessor_funs}end
    """

    {module_atom, source}
  end

  # -----------------------------------------------------------------------
  # Defstruct / typespec
  # -----------------------------------------------------------------------

  defp build_defstruct(t, schema) do
    parts =
      Enum.map(t.fields, fn f ->
        d = default_value(f, schema)
        "#{f.name}: #{inspect(d)}"
      end)

    "[" <> Enum.join(parts, ", ") <> "]"
  end

  defp build_type_spec(t, schema) do
    parts =
      Enum.map(t.fields, fn f ->
        "#{f.name}: #{type_for(f.type, schema)}"
      end)

    "%__MODULE__{" <> Enum.join(parts, ", ") <> "}"
  end

  defp type_for({:scalar, :bool}, _), do: "boolean()"
  defp type_for({:scalar, k}, _) when k in [:f32, :f64], do: "float() | nil"
  defp type_for({:scalar, _}, _), do: "integer() | nil"
  defp type_for(:string, _), do: "String.t() | nil"
  defp type_for({:vector, inner}, schema), do: "[#{type_for(inner, schema)}]"
  defp type_for({:enum, fqn}, _), do: fqn_to_module(fqn) <> ".t() | nil"
  defp type_for({:struct, fqn}, _), do: fqn_to_module(fqn) <> ".t() | nil"
  defp type_for({:table, fqn}, _), do: fqn_to_module(fqn) <> ".t() | nil"
  defp type_for({:union, fqn}, _), do: fqn_to_module(fqn) <> ".t()"

  # -----------------------------------------------------------------------
  # Defaults
  # -----------------------------------------------------------------------

  # The default value used in the defstruct and as the missing-field default
  # when decoding. The default *value* (after unwrapping the parser's literal
  # tuple) is what we surface to user code.
  defp default_value(f, schema) do
    case {f.type, f.default} do
      {{:scalar, kind}, nil} -> Schema.scalar_default(kind)
      {{:scalar, _}, {:int, n}} -> n
      {{:scalar, _}, {:float, f}} -> f
      {{:scalar, _}, {:bool, b}} -> b
      {{:enum, fqn}, nil} -> first_variant_atom(fqn, schema)
      {{:enum, fqn}, {:ident, name}} -> resolve_enum_ident(fqn, name, schema)
      {{:enum, fqn}, {:int, n}} -> int_to_enum_atom(fqn, n, schema)
      {:string, _} -> nil
      {{:vector, _}, _} -> []
      {{:table, _}, _} -> nil
      {{:struct, _}, _} -> nil
      {{:union, _}, _} -> nil
    end
  end

  defp first_variant_atom(fqn, schema) do
    %SchemaEnum{variants: [{name, _} | _]} = Schema.fetch(schema, fqn)
    name
  end

  defp resolve_enum_ident(fqn, name, schema) do
    %SchemaEnum{variants: variants} = Schema.fetch(schema, fqn)
    atom = String.to_atom(name)

    case Enum.find(variants, fn {n, _} -> n == atom end) do
      {n, _} -> n
      nil -> raise "unknown enum variant #{name} for #{fqn}"
    end
  end

  defp int_to_enum_atom(fqn, n, schema) do
    %SchemaEnum{variants: variants} = Schema.fetch(schema, fqn)

    case Enum.find(variants, fn {_, v} -> v == n end) do
      {atom, _} -> atom
      nil -> n
    end
  end

  # -----------------------------------------------------------------------
  # Decode
  # -----------------------------------------------------------------------

  defp build_decode_at(t, _schema) do
    t.fields
    |> Enum.map_join("", fn f ->
      "      #{f.name}: decode_field_#{f.name}(buf, pos),\n"
    end)
    |> trim_trailing_comma()
  end

  defp build_accessors(t, schema) do
    Enum.map_join(t.fields, "\n", fn f -> field_decoder(f, schema) end)
  end

  defp field_decoder(f, schema) do
    body = field_decode_body(f, schema)

    """
      @doc \"Read field `#{f.name}` from a table at position `pos`. Returns the field value or its default.\"
      def decode_field_#{f.name}(buf, pos) do
    #{body}  end
    """
  end

  defp field_decode_body(f, schema) do
    case f.type do
      {:union, fqn} ->
        # Union fields don't fit the regular `vtable_slot -> read` pattern:
        # the discriminator is in slot N, the uoffset in slot N+2, and we
        # have to read both before we can dispatch.
        value_slot = f.vtable_slot + 2

        """
              case Wire.read_vtable_field(buf, pos, #{f.vtable_slot}) do
                0 -> nil
                type_o ->
                  case Wire.read_vtable_field(buf, pos, #{value_slot}) do
                    0 -> nil
                    value_o ->
                      disc = Wire.read_u8(buf, pos + type_o)
                      abs_pos = Wire.follow_uoffset(buf, pos + value_o)
                      #{fqn_to_module(fqn)}.decode_variant(buf, disc, abs_pos)
                  end
              end
        """
        |> String.trim_trailing()
        |> Kernel.<>("\n")

      _ ->
        default = default_value(f, schema)
        default_lit = inspect(default)

        read_expr =
          case f.type do
            {:scalar, kind} ->
              "Wire.read_#{kind}(buf, pos + o)"

            :string ->
              "Wire.read_string_at(buf, Wire.follow_uoffset(buf, pos + o))"

            {:vector, inner} ->
              decode_vector_expr(inner, schema)

            {:enum, fqn} ->
              %SchemaEnum{underlying_type: u} = Schema.fetch(schema, fqn)
              "#{fqn_to_module(fqn)}.from_value(Wire.read_#{u}(buf, pos + o))"

            {:struct, fqn} ->
              "#{fqn_to_module(fqn)}.decode_at(buf, pos + o)"

            {:table, fqn} ->
              "#{fqn_to_module(fqn)}.decode_at(buf, Wire.follow_uoffset(buf, pos + o))"
          end

        "      case Wire.read_vtable_field(buf, pos, #{f.vtable_slot}) do\n        0 -> #{default_lit}\n        o -> #{read_expr}\n      end\n"
    end
  end

  defp decode_vector_expr(inner, schema) do
    {elem_size, _elem_align, read_elem} =
      case inner do
        {:scalar, kind} ->
          sz = Schema.scalar_size(kind)
          {sz, sz, "Wire.read_#{kind}(buf, Wire.vector_elem_pos(abs, i, #{sz}))"}

        :string ->
          {4, 4,
           "Wire.read_string_at(buf, Wire.follow_uoffset(buf, Wire.vector_elem_pos(abs, i, 4)))"}

        {:enum, fqn} ->
          %SchemaEnum{underlying_type: u} = Schema.fetch(schema, fqn)
          sz = Schema.scalar_size(u)

          {sz, sz,
           "#{fqn_to_module(fqn)}.from_value(Wire.read_#{u}(buf, Wire.vector_elem_pos(abs, i, #{sz})))"}

        {:struct, fqn} ->
          %SchemaStruct{size: sz, align: al} = Schema.fetch(schema, fqn)
          {sz, al, "#{fqn_to_module(fqn)}.decode_at(buf, Wire.vector_elem_pos(abs, i, #{sz}))"}

        {:table, fqn} ->
          {4, 4,
           "#{fqn_to_module(fqn)}.decode_at(buf, Wire.follow_uoffset(buf, Wire.vector_elem_pos(abs, i, 4)))"}
      end

    _ = elem_size

    """
    (
              abs = Wire.follow_uoffset(buf, pos + o)
              count = Wire.read_vector_count(buf, abs)
              if count == 0 do
                []
              else
                for i <- 0..(count - 1) do
                  #{read_elem}
                end
              end
            )
    """
    |> String.trim_trailing()
  end

  # -----------------------------------------------------------------------
  # Encode (top-level)
  # -----------------------------------------------------------------------

  defp build_encode_top(_t, is_root?) do
    if is_root? do
      """

        @doc \"Decode a buffer whose root is this table.\"
        @spec decode(binary()) :: {:ok, t()} | {:error, term()}
        def decode(buf) when is_binary(buf) do
          try do
            {:ok, decode_at(buf, Wire.root_table_pos(buf))}
          catch
            kind, reason -> {:error, {kind, reason}}
          end
        end

        @doc \"Encode a value to a complete buffer with this table as the root.\"
        @spec encode(t() | map()) :: {:ok, binary()} | {:error, term()}
        def encode(value) when is_map(value) do
          builder = Wire.new_builder()
          {builder, root_addr} = build(builder, value)
          builder = Wire.finish(builder, root_addr)
          {:ok, Wire.to_binary(builder)}
        end
      """
    else
      ""
    end
  end

  # -----------------------------------------------------------------------
  # Encode (build into existing builder)
  # -----------------------------------------------------------------------

  defp build_encode_build(t, schema) do
    {prelude_lines, addrs_per_field} = build_subobject_prelude(t, schema)
    field_add_lines = build_field_adds(t, schema, addrs_per_field)

    """
        b = builder
    #{prelude_lines}    b = Wire.start_table(b)
    #{field_add_lines}    Wire.end_table(b)
    """
  end

  # For each field that references a sub-object (string/vector/sub-table),
  # emit code that builds it and stores its addr into a local variable.
  defp build_subobject_prelude(t, schema) do
    {lines, addrs} =
      Enum.map_reduce(t.fields, %{}, fn f, acc ->
        case build_subobject_for_field(f, schema) do
          nil ->
            {"", acc}

          {addr_var, line} ->
            {line, Map.put(acc, f.name, addr_var)}
        end
      end)

    {Enum.join(lines), addrs}
  end

  defp build_subobject_for_field(f, schema) do
    var = "addr_#{f.name}"
    field_lookup = "Map.get(value, #{inspect(f.name)})"

    case f.type do
      :string ->
        line = """
            {b, #{var}} =
              case #{field_lookup} do
                nil -> {b, nil}
                "" -> Wire.create_string(b, "")
                s when is_binary(s) -> Wire.create_string(b, s)
              end
        """

        {var, line}

      {:vector, inner} ->
        line = build_vector_prelude(var, field_lookup, inner, schema)
        {var, line}

      {:table, fqn} ->
        line = """
            {b, #{var}} =
              case #{field_lookup} do
                nil -> {b, nil}
                v -> #{fqn_to_module(fqn)}.build(b, v)
              end
        """

        {var, line}

      {:union, fqn} ->
        # Two locals: the discriminator and the variant value's addr.
        disc_var = "disc_#{f.name}"

        line = """
            {b, #{disc_var}, #{var}} =
              case #{field_lookup} do
                nil ->
                  {b, 0, nil}

                {variant_atom, variant_value} ->
                  {b2, addr} = #{fqn_to_module(fqn)}.build_variant(b, variant_atom, variant_value)
                  {b2, #{fqn_to_module(fqn)}.discriminator(variant_atom), addr}
              end
        """

        {var, line}

      _ ->
        nil
    end
  end

  defp build_vector_prelude(var, field_lookup, inner, schema) do
    case inner do
      {:scalar, kind} ->
        sz = Schema.scalar_size(kind)

        """
            {b, #{var}} =
              case #{field_lookup} do
                nil -> {b, nil}
                [] -> Wire.create_scalar_vector(b, [], #{sz}, #{sz}, &Wire.push_#{kind}/2)
                list when is_list(list) -> Wire.create_scalar_vector(b, list, #{sz}, #{sz}, &Wire.push_#{kind}/2)
              end
        """

      :string ->
        """
            {b, #{var}} =
              case #{field_lookup} do
                nil ->
                  {b, nil}

                list when is_list(list) ->
                  {addrs, b} =
                    Enum.map_reduce(list, b, fn s, acc ->
                      {acc2, a} = Wire.create_string(acc, s)
                      {a, acc2}
                    end)

                  Wire.create_offset_vector(b, addrs)
              end
        """

      {:table, fqn} ->
        """
            {b, #{var}} =
              case #{field_lookup} do
                nil ->
                  {b, nil}

                list when is_list(list) ->
                  {addrs, b} =
                    Enum.map_reduce(list, b, fn item, acc ->
                      {acc2, a} = #{fqn_to_module(fqn)}.build(acc, item)
                      {a, acc2}
                    end)

                  Wire.create_offset_vector(b, addrs)
              end
        """

      {:enum, fqn} ->
        %SchemaEnum{underlying_type: u} = Schema.fetch(schema, fqn)
        sz = Schema.scalar_size(u)
        mod = fqn_to_module(fqn)

        """
            {b, #{var}} =
              case #{field_lookup} do
                nil ->
                  {b, nil}

                list when is_list(list) ->
                  ints = Enum.map(list, &#{mod}.value/1)
                  Wire.create_scalar_vector(b, ints, #{sz}, #{sz}, &Wire.push_#{u}/2)
              end
        """

      {:struct, fqn} ->
        %SchemaStruct{size: sz, align: al} = Schema.fetch(schema, fqn)
        mod = fqn_to_module(fqn)

        """
            {b, #{var}} =
              case #{field_lookup} do
                nil ->
                  {b, nil}

                list when is_list(list) ->
                  count = length(list)
                  b1 = Wire.start_vector(b, count, #{sz}, #{al})

                  b2 =
                    list
                    |> Enum.reverse()
                    |> Enum.reduce(b1, fn item, acc ->
                      acc = Wire.align(acc, #{al})
                      bin = #{mod}.encode(item)
                      %{acc | bytes: [bin | acc.bytes], size: acc.size + byte_size(bin)}
                    end)

                  Wire.end_vector(b2, count)
              end
        """
    end
  end

  defp build_field_adds(t, schema, addrs) do
    t.fields
    |> Enum.reverse()
    |> Enum.map_join("", fn f -> build_field_add(f, schema, addrs) end)
  end

  defp build_field_add(f, schema, addrs) do
    slot = f.vtable_slot

    case f.type do
      {:scalar, kind} ->
        default = default_value(f, schema)
        default_expr = literal_for_scalar(default, kind)

        value_expr =
          "Map.get(value, #{inspect(f.name)}, #{inspect(default_value(f, schema))})"

        coerced =
          if kind == :bool do
            "(if #{value_expr}, do: 1, else: 0)"
          else
            value_expr
          end

        push_fn =
          if kind == :bool, do: "&Wire.push_u8/2", else: "&Wire.push_#{kind}/2"

        default_for_push =
          if kind == :bool do
            if default, do: 1, else: 0
          else
            default_expr
          end

        """
            b = Wire.add_field_scalar(b, #{slot}, #{coerced}, #{inspect(default_for_push)}, #{push_fn})
        """

      :string ->
        var = Map.get(addrs, f.name)

        """
            b = Wire.add_field_offset(b, #{slot}, #{var})
        """

      {:vector, _} ->
        var = Map.get(addrs, f.name)

        """
            b = Wire.add_field_offset(b, #{slot}, #{var})
        """

      {:table, _fqn} ->
        var = Map.get(addrs, f.name)

        """
            b = Wire.add_field_offset(b, #{slot}, #{var})
        """

      {:enum, fqn} ->
        %SchemaEnum{underlying_type: u} = Schema.fetch(schema, fqn)
        default = default_value(f, schema)
        mod = fqn_to_module(fqn)

        default_int =
          case Schema.fetch(schema, fqn) do
            %SchemaEnum{variants: vs} ->
              case Enum.find(vs, fn {n, _} -> n == default end) do
                {_, v} -> v
                nil -> 0
              end
          end

        value_atom = "Map.get(value, #{inspect(f.name)}, #{inspect(default)})"
        value_expr = "#{mod}.value(#{value_atom})"

        push_fn =
          if u == :bool, do: "&Wire.push_u8/2", else: "&Wire.push_#{u}/2"

        """
            b = Wire.add_field_scalar(b, #{slot}, #{value_expr}, #{default_int}, #{push_fn})
        """

      {:struct, fqn} ->
        %SchemaStruct{align: al} = Schema.fetch(schema, fqn)
        mod = fqn_to_module(fqn)

        """
            b =
              case Map.get(value, #{inspect(f.name)}) do
                nil -> b
                v -> Wire.add_field_struct(b, #{slot}, #{mod}.encode(v), #{al})
              end
        """

      {:union, _fqn} ->
        value_slot = slot + 2
        disc_var = "disc_#{f.name}"
        addr_var = "addr_#{f.name}"

        # First the value uoffset (slot N+2), then the u8 discriminator
        # (slot N). Order doesn't change correctness — the vtable maps
        # slot → offset either way — but pushing the offset first keeps
        # the field-add code shape consistent with how flatc-generated
        # code lays it out.
        """
            b = Wire.add_field_offset(b, #{value_slot}, #{addr_var})
            b = Wire.add_field_scalar(b, #{slot}, #{disc_var}, 0, &Wire.push_u8/2)
        """
    end
  end

  defp literal_for_scalar(v, _kind) when is_number(v), do: v
  defp literal_for_scalar(v, _kind) when is_boolean(v), do: if(v, do: 1, else: 0)
  defp literal_for_scalar(nil, _kind), do: 0

  # -----------------------------------------------------------------------
  # Misc
  # -----------------------------------------------------------------------

  defp trim_trailing_comma(s) do
    String.replace(s, ~r/,\n$/, "\n")
  end

  defp fqn_to_module(fqn) do
    Enum.map_join(String.split(fqn, "."), ".", &Macro.camelize/1)
  end
end
