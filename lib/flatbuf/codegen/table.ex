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

  alias Flatbuf.Codegen.Naming
  alias Flatbuf.Schema
  alias Flatbuf.Schema.Enum, as: SchemaEnum
  alias Flatbuf.Schema.Struct, as: SchemaStruct
  alias Flatbuf.Schema.Table

  @ns_key :flatbuf_codegen_table_namespace

  @spec generate(Table.t(), Schema.t(), keyword()) :: {module(), String.t()}
  def generate(%Table{} = t, %Schema{} = schema, opts) do
    Process.put(@ns_key, Keyword.get(opts, :namespace))

    try do
      do_generate(t, schema, opts)
    after
      Process.delete(@ns_key)
    end
  end

  defp do_generate(%Table{} = t, %Schema{} = schema, opts) do
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
    to_json_map_body = build_to_json_map(t, schema)
    from_json_map_body = build_from_json_map(t, schema)
    json_top = build_json_top(is_root?)
    verify_body = build_verify_at(t, schema)
    verify_top = build_verify_top(is_root?)

    # An empty table has nothing to read in decode_at; underscore the
    # params to avoid the "variable is unused" warning the compiler
    # would otherwise emit on the generated source.
    has_fields? = t.fields != []
    buf_param = if has_fields?, do: "buf", else: "_buf"
    pos_param = if has_fields?, do: "pos", else: "_pos"

    source = """
    defmodule #{module_name} do
      @moduledoc "Generated from FlatBuffers table #{t.name}. Do not edit."

      alias #{inspect(wire_module)}, as: Wire

      defstruct #{defstruct_fields}
      @type t :: #{type_spec}
    #{encode_funs}#{json_top}
      @doc "Decode a table at absolute position `pos` within `buf`."
      @spec decode_at(binary(), non_neg_integer()) :: t()
      def decode_at(#{buf_param}, #{pos_param}) do
        %__MODULE__{
    #{decode_at_body}    }
      end

      @doc "Build this table inside an existing builder. Returns `{builder, addr}`."
      def build(builder, value) when is_map(value) do
    #{build_body}  end

      @doc false
      def __to_json_map__(value) when is_map(value) do
        Map.new([
    #{to_json_map_body}    ])
        |> Map.reject(fn {_k, v} -> v == nil or v == [] end)
      end

      @doc false
      def __from_json_map__(map) when is_map(map) do
        %__MODULE__{
    #{from_json_map_body}    }
      end
    #{verify_top}
      @doc false
      def __verify_at__(_buf, _pos, 0), do: {:error, :depth_exceeded}

      def __verify_at__(buf, pos, #{if recurses?(t), do: "depth", else: "_depth"}) do
        with {:ok, _vt_pos, _vt_size, _inline_size} <- Wire.verify_table_header(buf, pos) do
    #{verify_body}    end
      end

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
      # `= null` marks the field optional. Until we wire full presence
      # tracking through the decoder, treat it as "absent default":
      # the struct field is nil and our JSON output omits it (matching
      # flatc's behavior for missing optional scalars).
      {{:scalar, _}, :null} -> nil
      {{:scalar, _}, {:int, n}} -> n
      {{:scalar, _}, {:float, f}} -> f
      {{:scalar, _}, {:bool, b}} -> b
      {{:enum, fqn}, nil} -> default_enum_value(fqn, schema)
      {{:enum, _}, :null} -> nil
      {{:enum, fqn}, {:ident, name}} -> explicit_enum_default(fqn, name, schema)
      {{:enum, fqn}, {:int, n}} -> int_enum_default(fqn, n, schema)
      {:string, _} -> nil
      {{:vector, _}, _} -> []
      {{:table, _}, _} -> nil
      {{:struct, _}, _} -> nil
      {{:union, _}, _} -> nil
    end
  end

  defp default_enum_value(fqn, schema) do
    case Schema.fetch(schema, fqn) do
      %SchemaEnum{bit_flags?: true} -> []
      %SchemaEnum{variants: [{name, _} | _]} -> name
    end
  end

  defp explicit_enum_default(fqn, name, schema) do
    atom = resolve_enum_ident(fqn, name, schema)

    case Schema.fetch(schema, fqn) do
      %SchemaEnum{bit_flags?: true} -> [atom]
      _ -> atom
    end
  end

  defp int_enum_default(fqn, n, schema) do
    case Schema.fetch(schema, fqn) do
      %SchemaEnum{bit_flags?: true} ->
        # Decompose into flag list using the same logic the runtime decoder will.
        import Bitwise
        %SchemaEnum{variants: vs} = Schema.fetch(schema, fqn)
        for {atom, v} <- vs, v != 0 and (n &&& v) == v, do: atom

      _ ->
        int_to_enum_atom(fqn, n, schema)
    end
  end

  # Compile-time computation of the integer that corresponds to a
  # decoded default for an enum field. Used as the `default` arg to
  # Wire.add_field_scalar; the runtime compares value/1's result
  # against this and omits the field when they match.
  defp enum_default_int(%SchemaEnum{bit_flags?: true, variants: vs}, default)
       when is_list(default) do
    import Bitwise

    Enum.reduce(default, 0, fn atom, acc ->
      case Enum.find(vs, fn {n, _} -> n == atom end) do
        {_, v} -> bor(acc, v)
        nil -> acc
      end
    end)
  end

  defp enum_default_int(%SchemaEnum{variants: vs}, default) do
    case Enum.find(vs, fn {n, _} -> n == default end) do
      {_, v} -> v
      nil -> 0
    end
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
        # Union fields use two adjacent vtable slots: discriminator (u8)
        # at `vtable_slot - 2`, value (uoffset) at `vtable_slot`. This
        # matches both the auto-expanded case (slot allocated as the
        # higher of a pair) and the explicit-id case (where the schema's
        # `(id: N)` refers to the value slot).
        disc_slot = f.vtable_slot - 2

        """
              case Wire.read_vtable_field(buf, pos, #{disc_slot}) do
                0 -> nil
                type_o ->
                  case Wire.read_vtable_field(buf, pos, #{f.vtable_slot}) do
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

        {:union, _fqn} ->
          # Vectors of unions are Phase 3 — they use two parallel
          # vtable slots (a `[u8]` of discriminators and a `[uoffset]`
          # of values). Emit a stub that decodes to nil so the table's
          # other fields still work; full support comes later.
          {4, 4, "nil"}
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

  defp build_json_top(is_root?) do
    if is_root? do
      """

        @doc \"Encode this table as a JSON string (flatc-compatible shape).\"
        @spec to_json(t() | map()) :: binary()
        def to_json(value) when is_map(value) do
          value |> __to_json_map__() |> JSON.encode!() |> IO.iodata_to_binary()
        end

        @doc \"Decode a JSON string into this table's struct.\"
        @spec from_json(binary()) :: {:ok, t()} | {:error, term()}
        def from_json(json) when is_binary(json) do
          case JSON.decode(json) do
            {:ok, map} -> {:ok, __from_json_map__(map)}
            err -> err
          end
        end
      """
    else
      ""
    end
  end

  defp build_verify_top(is_root?) do
    if is_root? do
      """

        @doc \"\"\"
        Structurally verify a buffer claimed to be this table.

        Checks every offset is within the buffer, vtables are well-formed,
        strings have their null terminator, vectors don't claim to extend
        past the buffer, and sub-tables are recursively verified to a
        depth of 64. Returns `:ok` on success, `{:error, reason}` on the
        first problem encountered.
        \"\"\"
        @spec verify(binary()) :: :ok | {:error, term()}
        def verify(buf) when is_binary(buf) do
          with :ok <- Wire.verify_size(buf, 4),
               {:ok, root_pos} <- Wire.verify_follow_uoffset(buf, 0) do
            __verify_at__(buf, root_pos, 64)
          end
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

      {:union, _fqn} ->
        # Phase 3: vector-of-unions needs two parallel vtable slots
        # (a `[u8]` of discriminators and a `[uoffset]` of values).
        # Stub the encoder so the surrounding table still compiles;
        # nothing is actually written for these fields yet.
        """
            {b, #{var}} = {b, nil}
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
        %SchemaEnum{underlying_type: u} = enum_rec = Schema.fetch(schema, fqn)
        default = default_value(f, schema)
        mod = fqn_to_module(fqn)
        default_int = enum_default_int(enum_rec, default)

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
        # `slot` is the value slot; discriminator lives at slot - 2.
        disc_slot = slot - 2
        disc_var = "disc_#{f.name}"
        addr_var = "addr_#{f.name}"

        """
            b = Wire.add_field_offset(b, #{slot}, #{addr_var})
            b = Wire.add_field_scalar(b, #{disc_slot}, #{disc_var}, 0, &Wire.push_u8/2)
        """
    end
  end

  defp literal_for_scalar(v, _kind) when is_number(v), do: v
  defp literal_for_scalar(v, _kind) when is_boolean(v), do: if(v, do: 1, else: 0)
  defp literal_for_scalar(nil, _kind), do: 0
  # NaN/Infinity default literals — emit them as atoms; the wire helper
  # writes the IEEE 754 bit pattern when these come through push_f32/f64.
  defp literal_for_scalar(atom, _kind) when atom in [:nan, :infinity, :neg_infinity], do: atom

  # -----------------------------------------------------------------------
  # Verifier
  # -----------------------------------------------------------------------

  # True if any of the table's fields needs to recurse with `depth - 1`.
  # When false, the verifier's `depth` parameter is unused and the
  # generated source uses `_depth` to keep the compiler quiet.
  defp recurses?(t) do
    Enum.any?(t.fields, fn f -> recurses_field?(f.type) end)
  end

  defp recurses_field?({:table, _}), do: true
  defp recurses_field?({:union, _}), do: true
  defp recurses_field?({:vector, {:table, _}}), do: true
  defp recurses_field?(_), do: false

  defp build_verify_at(t, schema) do
    clauses =
      t.fields
      |> Enum.map(fn f -> verify_field(f, schema) end)
      |> Enum.reject(&(&1 == ""))

    case clauses do
      [] ->
        "      :ok\n"

      _ ->
        joined = clauses |> Enum.map(&String.trim/1) |> Enum.join(",\n         ")

        """
              with #{joined} do
                :ok
              end
        """
    end
  end

  defp verify_field(f, schema) do
    case f.type do
      {:scalar, _} ->
        # Scalars live inline in the table; the vtable header check
        # already bounded the inline area, so no extra work needed.
        ""

      {:enum, _} ->
        ""

      {:struct, _} ->
        # Inline struct — bounded by inline_size.
        ""

      :string ->
        """
        :ok <- (case Wire.read_vtable_field(buf, pos, #{f.vtable_slot}) do
                  0 -> :ok
                  o ->
                    case Wire.verify_follow_uoffset(buf, pos + o) do
                      {:ok, abs_pos} -> Wire.verify_string_at(buf, abs_pos)
                      err -> err
                    end
                end)
        """

      {:vector, inner} ->
        verify_vector_field(f, inner, schema)

      {:table, fqn} ->
        mod = fqn_to_module(fqn)

        """
        :ok <- (case Wire.read_vtable_field(buf, pos, #{f.vtable_slot}) do
                  0 -> :ok
                  o ->
                    case Wire.verify_follow_uoffset(buf, pos + o) do
                      {:ok, abs_pos} -> #{mod}.__verify_at__(buf, abs_pos, depth - 1)
                      err -> err
                    end
                end)
        """

      {:union, fqn} ->
        mod = fqn_to_module(fqn)
        disc_slot = f.vtable_slot - 2

        """
        :ok <- (case Wire.read_vtable_field(buf, pos, #{disc_slot}) do
                  0 -> :ok
                  type_o ->
                    with :ok <- Wire.verify_bounds(buf, pos + type_o, 1) do
                      case Wire.read_vtable_field(buf, pos, #{f.vtable_slot}) do
                        0 -> :ok
                        value_o ->
                          case Wire.verify_follow_uoffset(buf, pos + value_o) do
                            {:ok, abs_pos} ->
                              disc = Wire.read_u8(buf, pos + type_o)
                              #{mod}.__verify_variant__(buf, disc, abs_pos, depth - 1)
                            err -> err
                          end
                      end
                    end
                end)
        """
    end
  end

  defp verify_vector_field(f, inner, schema) do
    {elem_size, elem_verifier} = vector_elem_verify(inner, schema)

    """
    :ok <- (case Wire.read_vtable_field(buf, pos, #{f.vtable_slot}) do
              0 -> :ok
              o ->
                case Wire.verify_follow_uoffset(buf, pos + o) do
                  {:ok, vec_pos} ->
                    case Wire.verify_vector_at(buf, vec_pos, #{elem_size}) do
                      {:ok, count} when count == 0 -> :ok
                      {:ok, count} ->
                        Enum.reduce_while(0..(count - 1), :ok, fn i, _acc ->
                          elem_pos = Wire.vector_elem_pos(vec_pos, i, #{elem_size})
                          case #{elem_verifier} do
                            :ok -> {:cont, :ok}
                            err -> {:halt, err}
                          end
                        end)
                      err -> err
                    end
                  err -> err
                end
            end)
    """
  end

  # Returns {elem_size, verify_expr} where verify_expr uses `elem_pos`,
  # `buf`, and `depth` and produces :ok or {:error, _}.
  defp vector_elem_verify({:scalar, kind}, _),
    do:
      {Schema.scalar_size(kind), "Wire.verify_bounds(buf, elem_pos, #{Schema.scalar_size(kind)})"}

  defp vector_elem_verify(:string, _),
    do:
      {4,
       "(case Wire.verify_follow_uoffset(buf, elem_pos) do {:ok, sp} -> Wire.verify_string_at(buf, sp); e -> e end)"}

  defp vector_elem_verify({:enum, fqn}, schema) do
    %SchemaEnum{underlying_type: u} = Schema.fetch(schema, fqn)
    sz = Schema.scalar_size(u)
    {sz, "Wire.verify_bounds(buf, elem_pos, #{sz})"}
  end

  defp vector_elem_verify({:struct, fqn}, schema) do
    %SchemaStruct{size: sz} = Schema.fetch(schema, fqn)
    {sz, "Wire.verify_bounds(buf, elem_pos, #{sz})"}
  end

  defp vector_elem_verify({:table, fqn}, _),
    do:
      {4,
       "(case Wire.verify_follow_uoffset(buf, elem_pos) do {:ok, tp} -> #{fqn_to_module(fqn)}.__verify_at__(buf, tp, depth - 1); e -> e end)"}

  defp vector_elem_verify({:union, _fqn}, _) do
    # Vectors of unions need parallel type+value vectors — Phase 3.
    {4, ":ok"}
  end

  # -----------------------------------------------------------------------
  # JSON map builders
  # -----------------------------------------------------------------------

  defp build_to_json_map(t, schema) do
    t.fields
    # `(deprecated)` fields are intentionally dropped from JSON
    # output — flatc does this, so matching means our output stays
    # comparable across binaries that include those slots in the
    # vtable for backwards compatibility.
    |> Enum.reject(&Map.get(&1.attributes, :deprecated, false))
    |> Enum.map_join("", fn f ->
      key = inspect(Atom.to_string(f.name))
      val = "Map.get(value, #{inspect(f.name)})"

      case f.type do
        {:union, fqn} ->
          mod = fqn_to_module(fqn)
          type_key = inspect(Atom.to_string(f.name) <> "_type")

          """
                {#{type_key}, #{mod}.__to_json_type__(#{val})},
                {#{key}, #{mod}.__to_json_value__(#{val})},
          """

        _ ->
          # Always emit scalars, enums, and structs (the value we
          # decoded — even when it's the schema default — matches
          # flatc's output when run with `--defaults-json`). Nil and
          # empty-list values get filtered out at the end of
          # `__to_json_map__`, which mirrors flatc omitting fields
          # genuinely absent from the vtable.
          expr = to_json_value_expr(f.type, val, schema)
          "      {#{key}, #{expr}},\n"
      end
    end)
  end

  defp build_from_json_map(t, schema) do
    Enum.map_join(t.fields, "", fn f ->
      key = inspect(Atom.to_string(f.name))

      case f.type do
        {:union, fqn} ->
          mod = fqn_to_module(fqn)
          type_key = inspect(Atom.to_string(f.name) <> "_type")

          "      #{f.name}: #{mod}.__from_json__(Map.get(map, #{type_key}), Map.get(map, #{key})),\n"

        _ ->
          val = "Map.get(map, #{key})"
          expr = from_json_value_expr(f.type, val, schema)
          "      #{f.name}: #{expr},\n"
      end
    end)
  end

  defp to_json_value_expr({:scalar, k}, val, _) when k in [:f32, :f64] do
    "(case #{val} do :nan -> \"nan\"; :infinity -> \"inf\"; :neg_infinity -> \"-inf\"; v -> v end)"
  end

  defp to_json_value_expr({:scalar, _}, val, _), do: val
  defp to_json_value_expr(:string, val, _), do: val

  defp to_json_value_expr({:enum, fqn}, val, _),
    do: "if(#{val} == nil, do: nil, else: #{fqn_to_module(fqn)}.__to_json__(#{val}))"

  defp to_json_value_expr({:struct, fqn}, val, _),
    do: "if(#{val} == nil, do: nil, else: #{fqn_to_module(fqn)}.__to_json_map__(#{val}))"

  defp to_json_value_expr({:table, fqn}, val, _),
    do: "if(#{val} == nil, do: nil, else: #{fqn_to_module(fqn)}.__to_json_map__(#{val}))"

  defp to_json_value_expr({:vector, inner}, val, schema) do
    inner_expr = to_json_value_expr(inner, "v", schema)
    "Enum.map(#{val} || [], fn v -> #{inner_expr} end)"
  end

  # Phase 3 stub — vectors of unions emit nothing.
  defp to_json_value_expr({:union, _}, _val, _schema), do: "nil"

  defp from_json_value_expr({:scalar, k}, val, _) when k in [:f32, :f64] do
    "(case #{val} do \"nan\" -> :nan; \"inf\" -> :infinity; \"-inf\" -> :neg_infinity; v -> v end)"
  end

  defp from_json_value_expr({:scalar, _}, val, _), do: val
  defp from_json_value_expr(:string, val, _), do: val

  defp from_json_value_expr({:enum, fqn}, val, _),
    do: "if(#{val} == nil, do: nil, else: #{fqn_to_module(fqn)}.__from_json__(#{val}))"

  defp from_json_value_expr({:struct, fqn}, val, _),
    do: "if(#{val} == nil, do: nil, else: #{fqn_to_module(fqn)}.__from_json_map__(#{val}))"

  defp from_json_value_expr({:table, fqn}, val, _),
    do: "if(#{val} == nil, do: nil, else: #{fqn_to_module(fqn)}.__from_json_map__(#{val}))"

  defp from_json_value_expr({:vector, inner}, val, schema) do
    inner_expr = from_json_value_expr(inner, "v", schema)
    "Enum.map(#{val} || [], fn v -> #{inner_expr} end)"
  end

  defp from_json_value_expr({:union, _}, _val, _schema), do: "nil"

  # -----------------------------------------------------------------------
  # Misc
  # -----------------------------------------------------------------------

  defp trim_trailing_comma(s) do
    String.replace(s, ~r/,\n$/, "\n")
  end

  defp fqn_to_module(fqn), do: Naming.module_name(fqn, Process.get(@ns_key))
end
