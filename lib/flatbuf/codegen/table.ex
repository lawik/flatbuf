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
    # Every table can serve as the root of a (possibly nested) buffer,
    # so we always emit `decode/1`, `encode/1`, `verify/1`,
    # `to_json/1`, and `from_json/1`. The schema's `root_type`
    # declaration is a hint about the canonical root; it doesn't
    # restrict which tables can act as roots.
    is_root? = true
    _ = schema.root_type
    module_name = fqn_to_module(t.name)
    module_atom = Module.concat([module_name])

    niceties = Keyword.get(opts, :niceties, [])

    defstruct_fields = build_defstruct(t, schema)
    type_spec = build_type_spec(t, schema)
    decode_at_body = build_decode_at(t, schema)
    accessor_funs = build_accessors(t, schema)
    build_body = build_encode_build(t, schema)
    encode_funs = build_encode_top(t, is_root?, schema.file_identifier)
    to_json_map_body = build_to_json_map(t, schema)
    from_json_map_body = build_from_json_map(t, schema)
    json_top = build_json_top(is_root?)
    verify_body = build_verify_at(t, schema)
    verify_top = build_verify_top(is_root?, schema.file_identifier)
    always_emit_keys = always_emit_keys(t)
    required_check = build_required_check(t)
    file_id_funs = build_file_identifier_funs(schema.file_identifier)
    behaviour_decl = build_behaviour_decl(is_root?, niceties)
    derives = build_derive_attrs(is_root?, niceties)

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
    #{behaviour_decl}#{file_id_funs}
    #{derives}  defstruct #{defstruct_fields}
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
    #{required_check}#{build_body}  end

      @doc false
      def __to_json_map__(value) when is_map(value) do
        Map.new([
    #{to_json_map_body}    ])
        |> Map.reject(fn {k, v} ->
          (v == nil or v == []) and k not in #{always_emit_keys}
        end)
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
    per_field =
      Enum.map_join(t.fields, "\n", fn f ->
        field_decoder(f, schema) <>
          nested_flatbuffer_accessor(f, schema, t) <>
          keyed_lookup_accessor(f, schema)
      end)

    per_field <> key_introspection(t)
  end

  # If this table has a `(key)`-marked field, expose:
  #
  # * `__flatbuf__(:key_field)` — the field's atom name.
  # * `__key_at__(buf, pos)` — read the key value at a given table
  #   position; used by `Wire.binary_search_offset_vector/5`.
  defp key_introspection(t) do
    case Enum.find(t.fields, fn f -> Map.get(f.attributes, :key, false) end) do
      nil ->
        ""

      f ->
        """

          @doc false
          def __flatbuf__(:key_field), do: #{inspect(f.name)}

          @doc \"Read the table's key field (#{f.name}) at the given position.\"
          def __key_at__(buf, pos), do: decode_field_#{f.name}(buf, pos)
        """
    end
  end

  # For each `[KeyedTable]` field on this table, emit a
  # `find_<field>_by_<key>(buf, table_pos, target)` helper that binary
  # -searches the (sorted-by-key) vector and returns the matching
  # table's `decode_at/2` result, or `nil`.
  defp keyed_lookup_accessor(f, schema) do
    with {:vector, {:table, fqn}} <- f.type,
         %Table{} = inner <- Schema.fetch(schema, fqn),
         key_field when not is_nil(key_field) <-
           Enum.find(inner.fields, fn kf -> Map.get(kf.attributes, :key, false) end) do
      mod = fqn_to_module(fqn)

      """

        @doc \"Binary-search `#{f.name}` for the entry with `#{key_field.name} == target`. Returns the matching #{fqn_to_module(fqn)} struct or `nil`.\"
        def find_#{f.name}_by_#{key_field.name}(buf, pos, target) do
          case Wire.read_vtable_field(buf, pos, #{f.vtable_slot}) do
            0 ->
              nil

            o ->
              vec_pos = Wire.follow_uoffset(buf, pos + o)
              count = Wire.read_vector_count(buf, vec_pos)

              case Wire.binary_search_offset_vector(buf, vec_pos, count, target, &#{mod}.__key_at__/2) do
                nil -> nil
                table_pos -> #{mod}.decode_at(buf, table_pos)
              end
          end
        end
      """
    else
      _ -> ""
    end
  end

  # If a field is `[ubyte] (nested_flatbuffer: "Type")`, emit an extra
  # `<field>_as_<short_type>(buf, pos)` accessor that grabs the byte
  # vector as a contiguous binary slice and decodes it as the named
  # type. Returns `{:ok, struct} | {:error, reason}` or `nil` if the
  # field is absent.
  defp nested_flatbuffer_accessor(f, schema, t) do
    with {:vector, {:scalar, :u8}} <- f.type,
         name when is_binary(name) <- Map.get(f.attributes, :nested_flatbuffer),
         fqn when is_binary(fqn) <- resolve_nested_type(name, t.namespace, schema) do
      mod = fqn_to_module(fqn)
      short = fqn |> String.split(".") |> List.last() |> Macro.underscore()

      """
        @doc \"Decode the `#{f.name}` byte vector as a `#{fqn}` buffer.\"
        def #{f.name}_as_#{short}(buf, pos) do
          case Wire.read_vtable_field(buf, pos, #{f.vtable_slot}) do
            0 ->
              nil

            o ->
              vec_pos = Wire.follow_uoffset(buf, pos + o)
              count = Wire.read_vector_count(buf, vec_pos)
              bytes = binary_part(buf, vec_pos + 4, count)
              #{mod}.decode(bytes)
          end
        end
      """
    else
      _ -> ""
    end
  end

  # Resolve a name (possibly unqualified or dotted) against the
  # schema's types by walking up the field's containing namespace —
  # same logic as Resolver.lookup_name/3, duplicated to keep codegen
  # self-contained.
  defp resolve_nested_type(name, ns, schema) do
    candidates =
      cond do
        is_nil(ns) -> [name]
        String.contains?(name, ".") -> [name | ns_walk(ns, name)]
        true -> ns_walk(ns, name) ++ [name]
      end

    Enum.find(candidates, fn fqn -> Map.has_key?(schema.types, fqn) end)
  end

  defp ns_walk(ns, name) do
    parts = String.split(ns, ".")

    for i <- length(parts)..1//-1 do
      (Enum.take(parts, i) ++ [name]) |> Enum.join(".")
    end
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

      {:vector, {:union, fqn}} ->
        # Vectors of unions are stored as two parallel vectors in the
        # vtable: a `[u8]` of discriminators at `vtable_slot - 2` and
        # a `[uoffset]` of variant values at `vtable_slot`.
        disc_slot = f.vtable_slot - 2

        """
              case Wire.read_vtable_field(buf, pos, #{disc_slot}) do
                0 -> []
                type_o ->
                  case Wire.read_vtable_field(buf, pos, #{f.vtable_slot}) do
                    0 -> []
                    value_o ->
                      types_abs = Wire.follow_uoffset(buf, pos + type_o)
                      values_abs = Wire.follow_uoffset(buf, pos + value_o)
                      count = Wire.read_vector_count(buf, types_abs)
                      if count == 0 do
                        []
                      else
                        for i <- 0..(count - 1) do
                          disc = Wire.read_u8(buf, Wire.vector_elem_pos(types_abs, i, 1))
                          elem_pos = Wire.vector_elem_pos(values_abs, i, 4)
                          abs_pos = Wire.follow_uoffset(buf, elem_pos)
                          #{fqn_to_module(fqn)}.decode_variant(buf, disc, abs_pos)
                        end
                      end
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

  defp build_encode_top(_t, true, file_id) do
    finish_opts =
      case file_id do
        nil -> "[]"
        id -> "[file_identifier: #{inspect(id)}]"
      end

    sp_finish_opts =
      case file_id do
        nil -> "[size_prefix: true]"
        id -> "[size_prefix: true, file_identifier: #{inspect(id)}]"
      end

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

      @doc \"\"\"
      Decode a size-prefixed buffer whose root is this table.

      The leading 4-byte little-endian size is stripped; the remainder is
      decoded as a standard buffer.
      \"\"\"
      @spec decode_size_prefixed(binary()) :: {:ok, t()} | {:error, term()}
      def decode_size_prefixed(<<size::little-32, rest::binary>>) when byte_size(rest) >= size do
        decode(binary_part(rest, 0, size))
      end

      def decode_size_prefixed(buf) when is_binary(buf) do
        {:error, :truncated_size_prefix}
      end

      @doc \"Encode a value to a complete buffer with this table as the root.\"
      @spec encode(t() | map()) :: {:ok, binary()} | {:error, term()}
      def encode(value) when is_map(value) do
        try do
          builder = Wire.new_builder()
          {builder, root_addr} = build(builder, value)
          builder = Wire.finish(builder, root_addr, #{finish_opts})
          {:ok, Wire.to_binary(builder)}
        catch
          {:flatbuf_required, _} = err -> {:error, err}
        end
      end

      @doc \"Encode the value with a leading 4-byte size prefix.\"
      @spec encode_size_prefixed(t() | map()) :: {:ok, binary()} | {:error, term()}
      def encode_size_prefixed(value) when is_map(value) do
        try do
          builder = Wire.new_builder()
          {builder, root_addr} = build(builder, value)
          builder = Wire.finish(builder, root_addr, #{sp_finish_opts})
          {:ok, Wire.to_binary(builder)}
        catch
          {:flatbuf_required, _} = err -> {:error, err}
        end
      end
    """
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

  defp build_verify_top(true, _file_id) do
    """

      @doc \"\"\"
      Structurally verify a buffer claimed to be this table.

      Checks every offset is within the buffer, vtables are well-formed,
      strings have their null terminator, vectors don't claim to extend
      past the buffer, required fields are present, and sub-tables are
      recursively verified to a depth of 64. Returns `:ok` on success,
      `{:error, reason}` on the first problem encountered.
      \"\"\"
      @spec verify(binary()) :: :ok | {:error, term()}
      def verify(buf) when is_binary(buf) do
        with :ok <- Wire.verify_size(buf, 4),
             {:ok, root_pos} <- Wire.verify_follow_uoffset(buf, 0) do
          __verify_at__(buf, root_pos, 64)
        end
      end

      @doc \"\"\"
      Verify a size-prefixed buffer claimed to be this table.

      Validates the leading u32 size, then runs `verify/1` on the body.
      \"\"\"
      @spec verify_size_prefixed(binary()) :: :ok | {:error, term()}
      def verify_size_prefixed(<<size::little-32, rest::binary>>) when byte_size(rest) == size do
        verify(rest)
      end

      def verify_size_prefixed(<<size::little-32, rest::binary>>) do
        {:error, {:size_prefix_mismatch, size, byte_size(rest)}}
      end

      def verify_size_prefixed(buf) when is_binary(buf) do
        {:error, {:buffer_too_small, 4}}
      end
    """
  end

  # -----------------------------------------------------------------------
  # Niceties: opt-in behaviour and protocol derives
  # -----------------------------------------------------------------------

  defp build_behaviour_decl(true, niceties) do
    if :behaviour in niceties do
      "\n  @behaviour Flatbuf.Table\n"
    else
      ""
    end
  end

  # Jason.Encoder is derived on the table struct itself, which fits the
  # decoded-shape (atoms + scalars + nested structs) cleanly. Users who
  # want flatc-shaped JSON instead use `to_json/1`.
  defp build_derive_attrs(true, niceties) do
    if :jason in niceties do
      "  @derive Jason.Encoder\n  "
    else
      ""
    end
  end

  # -----------------------------------------------------------------------
  # File identifier
  # -----------------------------------------------------------------------

  defp build_file_identifier_funs(nil), do: ""

  defp build_file_identifier_funs(id) when is_binary(id) do
    """

      @doc \"\"\"
      The 4-byte `file_identifier` this schema declares. Generated tables
      with a `file_identifier` write it into the buffer header during
      `encode/1`; callers can compare it against the bytes at offset 4
      (or 8 for size-prefixed buffers) to disambiguate union-of-roots.
      \"\"\"
      @spec file_identifier() :: binary()
      def file_identifier, do: #{inspect(id)}
    """
  end

  # -----------------------------------------------------------------------
  # Required-field enforcement (encode side)
  # -----------------------------------------------------------------------

  # Required fields fail-fast at the top of `build/2`. Throwing a known
  # tag here is what `encode/1` catches above to translate the failure
  # into an `{:error, _}` return tuple.
  # Emit an `Enum.sort_by` expression for a list of `fqn` table
  # structs, sorted by the table's `(key)` field. If `fqn` has no key
  # field, the list is left as-is (no-op).
  defp sort_by_key_step(fqn, schema) do
    case Schema.fetch(schema, fqn) do
      %Table{fields: fields} ->
        case Enum.find(fields, fn f -> Map.get(f.attributes, :key, false) end) do
          nil ->
            "list"

          %{name: key_name} ->
            "Enum.sort_by(list, fn item -> Map.get(item, #{inspect(key_name)}) end)"
        end

      _ ->
        "list"
    end
  end

  defp build_required_check(%Table{fields: fields}) do
    required =
      Enum.filter(fields, fn f ->
        Map.get(f.attributes, :required) == true and field_can_be_required?(f.type)
      end)

    case required do
      [] ->
        ""

      _ ->
        names = Enum.map(required, & &1.name)

        """
            Enum.each(#{inspect(names)}, fn name ->
              case Map.get(value, name) do
                nil -> throw({:flatbuf_required, name})
                _ -> :ok
              end
            end)
        """
    end
  end

  # `required` is only meaningful for fields that occupy a uoffset slot;
  # the parser/resolver should already reject `required` on scalars but
  # we filter defensively so a stray attribute doesn't generate dead code.
  defp field_can_be_required?(:string), do: true
  defp field_can_be_required?({:vector, _}), do: true
  defp field_can_be_required?({:table, _}), do: true
  defp field_can_be_required?({:union, _}), do: true
  defp field_can_be_required?({:struct, _}), do: true
  defp field_can_be_required?(_), do: false

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
        # `(shared)` routes through create_shared_string, which dedups
        # identical strings within a single buffer via the builder's
        # string_cache.
        create_fn =
          if Map.get(f.attributes, :shared, false) do
            "Wire.create_shared_string"
          else
            "Wire.create_string"
          end

        line = """
            {b, #{var}} =
              case #{field_lookup} do
                nil -> {b, nil}
                s when is_binary(s) -> #{create_fn}(b, s)
              end
        """

        {var, line}

      {:vector, {:union, fqn}} ->
        # Two locals: the type vector's addr and the value vector's.
        types_var = "addr_#{f.name}_types"
        mod = fqn_to_module(fqn)

        line = """
            {b, #{types_var}, #{var}} =
              case #{field_lookup} do
                nil ->
                  {b, nil, nil}

                list when is_list(list) ->
                  {pairs, b} =
                    Enum.map_reduce(list, b, fn item, acc ->
                      case item do
                        nil ->
                          {{0, nil}, acc}

                        {variant_atom, variant_value} ->
                          {acc2, addr} = #{mod}.build_variant(acc, variant_atom, variant_value)
                          disc = #{mod}.discriminator(variant_atom)
                          {{disc, addr}, acc2}
                      end
                    end)

                  discs = Enum.map(pairs, &elem(&1, 0))
                  addrs = Enum.map(pairs, &elem(&1, 1))
                  {b, vals_addr} = Wire.create_offset_vector(b, addrs)
                  {b, types_addr} = Wire.create_scalar_vector(b, discs, 1, 1, &Wire.push_u8/2)
                  {b, types_addr, vals_addr}
              end
        """

        {{:union_vec, types_var, var}, line}

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
        # If the inner table has a `(key)` field, sort the list by
        # that field's value before writing — so the wire order is
        # ascending by key and `find_<field>_by_<key>/3` (which does
        # a binary search) actually finds matches.
        sort_step = sort_by_key_step(fqn, schema)

        """
            {b, #{var}} =
              case #{field_lookup} do
                nil ->
                  {b, nil}

                list when is_list(list) ->
                  list = #{sort_step}

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
        # Handled in build_subobject_for_field directly so it can
        # expose both `addr_<name>_types` and `addr_<name>` to
        # build_field_add. Should not reach here.
        raise "vector-of-union handled in build_subobject_for_field"
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

        raw_value =
          "Map.get(value, #{inspect(f.name)}, #{inspect(default_value(f, schema))})"

        # `(hash: "fnv1_32")` etc. lets the user pass a string in place
        # of the int; the encoder hashes it on the way down. Integers
        # pass through unchanged.
        value_expr =
          case Map.get(f.attributes, :hash) do
            nil ->
              raw_value

            alg when is_binary(alg) ->
              "Wire.maybe_hash(#{raw_value}, #{inspect(String.to_atom(alg))})"
          end

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

      {:vector, {:union, _}} ->
        # Two parallel vtable slots: type vector at slot - 2, value
        # vector at slot.
        {:union_vec, types_var, values_var} = Map.get(addrs, f.name)
        disc_slot = slot - 2

        """
            b = Wire.add_field_offset(b, #{slot}, #{values_var})
            b = Wire.add_field_offset(b, #{disc_slot}, #{types_var})
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

  # JSON keys that the to_json_map must emit *even when nil*, matching
  # flatc's behavior:
  #
  # * Optional scalar fields (`field: int = null`) — flatc emits
  #   `"field": null` when the slot is absent from the vtable; our
  #   decoder returns nil for those, and the reject filter would
  #   otherwise drop the key entirely.
  defp always_emit_keys(t) do
    keys =
      t.fields
      |> Enum.reject(&Map.get(&1.attributes, :deprecated, false))
      |> Enum.filter(fn f -> f.default == :null end)
      |> Enum.map(fn f -> Atom.to_string(f.name) end)

    inspect(keys)
  end

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
    field_clauses =
      t.fields
      |> Enum.map(fn f -> verify_field(f, schema) end)
      |> Enum.reject(&(&1 == ""))

    required_clauses =
      t.fields
      |> Enum.filter(fn f -> Map.get(f.attributes, :required) == true end)
      |> Enum.map(&verify_required_field/1)

    clauses = required_clauses ++ field_clauses

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

  defp verify_required_field(f) do
    """
    :ok <- (if Wire.read_vtable_field(buf, pos, #{f.vtable_slot}) == 0,
              do: {:error, {:missing_required, #{inspect(f.name)}}},
              else: :ok)
    """
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

      {:vector, {:union, fqn}} ->
        # Vector-of-union: two parallel vectors. Bounds-check both,
        # then dispatch each (discriminator, value) pair through the
        # union module's `__verify_variant__/4`.
        mod = fqn_to_module(fqn)
        disc_slot = f.vtable_slot - 2

        """
        :ok <- (case Wire.read_vtable_field(buf, pos, #{disc_slot}) do
                  0 -> :ok
                  type_o ->
                    case Wire.read_vtable_field(buf, pos, #{f.vtable_slot}) do
                      0 -> :ok
                      value_o ->
                        with {:ok, types_pos} <- Wire.verify_follow_uoffset(buf, pos + type_o),
                             {:ok, vals_pos} <- Wire.verify_follow_uoffset(buf, pos + value_o),
                             {:ok, _} <- Wire.verify_vector_at(buf, types_pos, 1),
                             {:ok, count} <- Wire.verify_vector_at(buf, vals_pos, 4) do
                          Enum.reduce_while(0..(count - 1)//1, :ok, fn i, _ ->
                            disc = Wire.read_u8(buf, Wire.vector_elem_pos(types_pos, i, 1))
                            val_elem = Wire.vector_elem_pos(vals_pos, i, 4)
                            case Wire.verify_follow_uoffset(buf, val_elem) do
                              {:ok, abs_pos} ->
                                case #{mod}.__verify_variant__(buf, disc, abs_pos, depth - 1) do
                                  :ok -> {:cont, :ok}
                                  err -> {:halt, err}
                                end
                              err -> {:halt, err}
                            end
                          end)
                        end
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
    # Vectors of unions are handled specially in verify_field/2 above
    # (they take two parallel vtable slots). This clause shouldn't be
    # reached, but kept for safety.
    {4, "Wire.verify_bounds(buf, elem_pos, 4)"}
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

        {:vector, {:union, fqn}} ->
          mod = fqn_to_module(fqn)
          type_key = inspect(Atom.to_string(f.name) <> "_type")

          """
                {#{type_key}, Enum.map(#{val} || [], &#{mod}.__to_json_type__/1)},
                {#{key}, Enum.map(#{val} || [], &#{mod}.__to_json_value__/1)},
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

        {:vector, {:union, fqn}} ->
          mod = fqn_to_module(fqn)
          type_key = inspect(Atom.to_string(f.name) <> "_type")

          """
                #{f.name}:
                  Enum.zip(
                    Map.get(map, #{type_key}) || [],
                    Map.get(map, #{key}) || []
                  )
                  |> Enum.map(fn {t, v} -> #{mod}.__from_json__(t, v) end),
          """

        _ ->
          val = "Map.get(map, #{key})"
          expr = from_json_value_expr(f.type, val, schema)
          # `(hash: "fnv1_32")` accepts a JSON string at the input side
          # and hashes it. JSON values that are already integers pass
          # through `Wire.maybe_hash/2` unchanged.
          expr =
            case Map.get(f.attributes, :hash) do
              nil ->
                expr

              alg when is_binary(alg) ->
                "Wire.maybe_hash(#{expr}, #{inspect(String.to_atom(alg))})"
            end

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
