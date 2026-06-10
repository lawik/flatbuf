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
  alias Flatbuf.Schema.Union, as: SchemaUnion

  @spec generate(Table.t(), Schema.t(), keyword()) :: {module(), String.t()}
  def generate(%Table{} = t, %Schema{} = schema, opts) do
    wire_module = Keyword.fetch!(opts, :wire_module)
    # The `:namespace` override is threaded explicitly (trailing `ns`
    # arg) through every helper that maps FQNs to module names.
    ns = Keyword.get(opts, :namespace)
    # Every table can serve as the root of a (possibly nested) buffer,
    # so we always emit `decode/1`, `encode/1`, `verify/2`,
    # `to_json/1`, and `from_json/1`. The schema's `root_type`
    # declaration is a hint about the canonical root; it doesn't
    # restrict which tables can act as roots.
    module_name = fqn_to_module(t.name, ns)
    module_atom = Module.concat([module_name])

    niceties = Keyword.get(opts, :niceties, [])

    defstruct_fields = build_defstruct(t, schema)
    type_spec = build_type_spec(t, schema, ns)
    decode_at_body = build_decode_at(t, schema)
    accessor_funs = build_accessors(t, schema, ns)
    build_body = build_encode_build(t, schema, ns)
    encode_funs = build_encode_top(schema.file_identifier)
    to_json_map_body = build_to_json_map(t, schema, ns)
    from_json_map_body = build_from_json_map(t, schema, ns)
    json_top = build_json_top()
    verify_body = build_verify_at(t, schema, ns)
    verify_top = build_verify_top()
    always_emit_keys = always_emit_keys(t)
    required_check = build_required_check(t)
    file_id_funs = build_file_identifier_funs(schema.file_identifier)
    file_ext_funs = build_file_extension_funs(schema.file_extension)
    behaviour_decl = build_behaviour_decl(niceties)
    derives = build_derive_attrs(niceties)

    # An empty table has nothing to read in decode_at; underscore the
    # params to avoid the "variable is unused" warning the compiler
    # would otherwise emit on the generated source. Same deal for the
    # verifier's inline_size: only field clauses consume it.
    has_fields? = t.fields != []
    buf_param = if has_fields?, do: "buf", else: "_buf"
    pos_param = if has_fields?, do: "pos", else: "_pos"
    inline_size_param = if has_fields?, do: "inline_size", else: "_inline_size"

    source = """
    defmodule #{module_name} do
      @moduledoc "Generated from FlatBuffers table #{t.name}. Do not edit."

      alias #{inspect(wire_module)}, as: Wire
    #{behaviour_decl}#{file_id_funs}#{file_ext_funs}
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
      def __verify_at__(_buf, _pos, 0), do: {:error, :depth_exceeded, []}

      def __verify_at__(buf, pos, #{if recurses?(t), do: "depth", else: "_depth"}) do
        case Wire.verify_table_header(buf, pos) do
          {:ok, _vt_pos, _vt_size, #{inline_size_param}} ->
    #{verify_body}
          {:error, reason} ->
            {:error, reason, []}
        end
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

  defp build_type_spec(t, schema, ns) do
    parts =
      Enum.map(t.fields, fn f ->
        "#{f.name}: #{type_for(f.type, schema, ns)}"
      end)

    "%__MODULE__{" <> Enum.join(parts, ", ") <> "}"
  end

  defp type_for({:scalar, :bool}, _, _ns), do: "boolean()"
  defp type_for({:scalar, k}, _, _ns) when k in [:f32, :f64], do: "float() | nil"
  defp type_for({:scalar, _}, _, _ns), do: "integer() | nil"
  defp type_for(:string, _, _ns), do: "String.t() | nil"
  defp type_for({:vector, inner}, schema, ns), do: "[#{type_for(inner, schema, ns)}]"
  defp type_for({:enum, fqn}, _, ns), do: fqn_to_module(fqn, ns) <> ".t() | nil"
  defp type_for({:struct, fqn}, _, ns), do: fqn_to_module(fqn, ns) <> ".t() | nil"
  defp type_for({:table, fqn}, _, ns), do: fqn_to_module(fqn, ns) <> ".t() | nil"
  defp type_for({:union, fqn}, _, ns), do: fqn_to_module(fqn, ns) <> ".t()"

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
      %SchemaEnum{variants: []} -> nil
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

  defp build_accessors(t, schema, ns) do
    per_field =
      Enum.map_join(t.fields, "\n", fn f ->
        field_decoder(f, schema, ns) <>
          nested_flatbuffer_accessor(f, schema, t, ns) <>
          keyed_lookup_accessor(f, schema, ns)
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
  defp keyed_lookup_accessor(f, schema, ns) do
    with {:vector, {:table, fqn}} <- f.type,
         %Table{} = inner <- Schema.fetch(schema, fqn),
         key_field when not is_nil(key_field) <-
           Enum.find(inner.fields, fn kf -> Map.get(kf.attributes, :key, false) end) do
      mod = fqn_to_module(fqn, ns)

      """

        @doc \"Binary-search `#{f.name}` for the entry with `#{key_field.name} == target`. Returns the matching #{mod} struct or `nil`.\"
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
  defp nested_flatbuffer_accessor(f, schema, t, ns) do
    with {:vector, {:scalar, :u8}} <- f.type,
         name when is_binary(name) <- Map.get(f.attributes, :nested_flatbuffer),
         fqn when is_binary(fqn) <- resolve_nested_type(name, t.namespace, schema) do
      mod = fqn_to_module(fqn, ns)
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

  defp field_decoder(f, schema, ns) do
    body = field_decode_body(f, schema, ns)

    """
      @doc \"Read field `#{f.name}` from a table at position `pos`. Returns the field value or its default.\"
      def decode_field_#{f.name}(buf, pos) do
    #{body}  end
    """
  end

  defp field_decode_body(f, schema, ns) do
    case f.type do
      {:union, fqn} ->
        # Union fields use two adjacent vtable slots: discriminator
        # (the union's underlying type, u8 unless declared otherwise)
        # at `vtable_slot - 2`, value (uoffset) at `vtable_slot`. This
        # matches both the auto-expanded case (slot allocated as the
        # higher of a pair) and the explicit-id case (where the schema's
        # `(id: N)` refers to the value slot).
        disc_slot = f.vtable_slot - 2
        {u, _sz} = union_disc_info(fqn, schema)

        """
              case Wire.read_vtable_field(buf, pos, #{disc_slot}) do
                0 -> nil
                type_o ->
                  case Wire.read_vtable_field(buf, pos, #{f.vtable_slot}) do
                    0 -> nil
                    value_o ->
                      disc = Wire.read_#{u}(buf, pos + type_o)
                      abs_pos = Wire.follow_uoffset(buf, pos + value_o)
                      #{fqn_to_module(fqn, ns)}.decode_variant(buf, disc, abs_pos)
                  end
              end
        """
        |> String.trim_trailing()
        |> Kernel.<>("\n")

      {:vector, {:union, fqn}} ->
        # Vectors of unions are stored as two parallel vectors in the
        # vtable: a vector of underlying-typed discriminators (u8
        # unless declared otherwise) at `vtable_slot - 2` and a
        # `[uoffset]` of variant values at `vtable_slot`. A NONE
        # (discriminator 0) element decodes to nil without touching
        # its value slot — flatc's verifier deliberately leaves that
        # slot uninspected, so its bytes are not to be trusted.
        disc_slot = f.vtable_slot - 2
        {u, sz} = union_disc_info(fqn, schema)

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
                          case Wire.read_#{u}(buf, Wire.vector_elem_pos(types_abs, i, #{sz})) do
                            0 ->
                              nil

                            disc ->
                              elem_pos = Wire.vector_elem_pos(values_abs, i, 4)
                              abs_pos = Wire.follow_uoffset(buf, elem_pos)
                              #{fqn_to_module(fqn, ns)}.decode_variant(buf, disc, abs_pos)
                          end
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
              decode_vector_expr(inner, schema, ns)

            {:enum, fqn} ->
              %SchemaEnum{underlying_type: u} = Schema.fetch(schema, fqn)
              "#{fqn_to_module(fqn, ns)}.from_value(Wire.read_#{u}(buf, pos + o))"

            {:struct, fqn} ->
              "#{fqn_to_module(fqn, ns)}.decode_at(buf, pos + o)"

            {:table, fqn} ->
              "#{fqn_to_module(fqn, ns)}.decode_at(buf, Wire.follow_uoffset(buf, pos + o))"
          end

        "      case Wire.read_vtable_field(buf, pos, #{f.vtable_slot}) do\n        0 -> #{default_lit}\n        o -> #{read_expr}\n      end\n"
    end
  end

  defp decode_vector_expr(inner, schema, ns) do
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
           "#{fqn_to_module(fqn, ns)}.from_value(Wire.read_#{u}(buf, Wire.vector_elem_pos(abs, i, #{sz})))"}

        {:struct, fqn} ->
          %SchemaStruct{size: sz, align: al} = Schema.fetch(schema, fqn)

          {sz, al,
           "#{fqn_to_module(fqn, ns)}.decode_at(buf, Wire.vector_elem_pos(abs, i, #{sz}))"}

        {:table, fqn} ->
          {4, 4,
           "#{fqn_to_module(fqn, ns)}.decode_at(buf, Wire.follow_uoffset(buf, Wire.vector_elem_pos(abs, i, 4)))"}

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

  defp build_encode_top(file_id) do
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

      @doc \"\"\"
      Decode a buffer whose root is this table.

      Returns `{:ok, t()}` on success or `{:error, {:malformed_buffer, exception}}`
      if the buffer is truncated or has out-of-range offsets. Other
      exceptions (programmer bugs in the caller, etc.) propagate. For
      untrusted input, call `verify/2` first.
      \"\"\"
      @spec decode(binary()) :: {:ok, t()} | {:error, {:malformed_buffer, Exception.t()}}
      def decode(buf) when is_binary(buf) do
        try do
          {:ok, decode_at(buf, Wire.root_table_pos(buf))}
        rescue
          e in [MatchError, ArgumentError, FunctionClauseError] ->
            {:error, {:malformed_buffer, e}}
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
          {:scalar_out_of_range, _, _, _} = err -> {:error, err}
          {:invalid_scalar, _, _, _} = err -> {:error, err}
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
          {:scalar_out_of_range, _, _, _} = err -> {:error, err}
          {:invalid_scalar, _, _, _} = err -> {:error, err}
        end
      end
    """
  end

  defp build_json_top() do
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
  end

  defp build_verify_top() do
    """

      @doc \"\"\"
      Structurally verify a buffer claimed to be this table.

      Checks every offset is within the buffer, vtables are well-formed,
      strings have their null terminator, vectors don't claim to extend
      past the buffer, required fields are present, and sub-tables are
      recursively verified up to `:max_depth` levels deep. Returns `:ok`
      on success, `{:error, reason, path}` on the first problem
      encountered.

      `path` is a root-first list locating the failing field: field
      atoms, vector indices (integers), and union variant atoms. The
      path starts at this table's first field — the root table itself
      contributes no leading segment. Failures detected before any
      field is reached (buffer too small, bad root offset, bad vtable)
      carry the empty path `[]`.

      ## Options

        * `:max_depth` — how many levels of nested tables/union values
          to follow before failing with reason `:depth_exceeded`
          (default: 64).
      \"\"\"
      @spec verify(binary(), keyword()) ::
              :ok | {:error, term(), [atom() | non_neg_integer()]}
      def verify(buf, opts \\\\ []) when is_binary(buf) do
        max_depth = Keyword.get(opts, :max_depth, 64)

        with :ok <- Wire.verify_size(buf, 4),
             {:ok, root_pos} <- Wire.verify_follow_uoffset(buf, 0) do
          __verify_at__(buf, root_pos, max_depth)
        else
          {:error, reason} -> {:error, reason, []}
        end
      end

      @doc \"\"\"
      Verify a size-prefixed buffer claimed to be this table.

      Validates the leading u32 size, then runs `verify/2` on the body
      (same options, same `:ok | {:error, reason, path}` contract).
      \"\"\"
      @spec verify_size_prefixed(binary(), keyword()) ::
              :ok | {:error, term(), [atom() | non_neg_integer()]}
      def verify_size_prefixed(buf, opts \\\\ [])

      def verify_size_prefixed(<<size::little-32, rest::binary>>, opts)
          when byte_size(rest) == size do
        verify(rest, opts)
      end

      def verify_size_prefixed(<<size::little-32, rest::binary>>, _opts) do
        {:error, {:size_prefix_mismatch, size, byte_size(rest)}, []}
      end

      def verify_size_prefixed(buf, _opts) when is_binary(buf) do
        {:error, {:buffer_too_small, 4}, []}
      end
    """
  end

  # -----------------------------------------------------------------------
  # Niceties: opt-in behaviour and protocol derives
  # -----------------------------------------------------------------------

  defp build_behaviour_decl(niceties) do
    if :behaviour in niceties do
      "\n  @behaviour Flatbuf.Table\n"
    else
      ""
    end
  end

  # Jason.Encoder is derived on the table struct itself, which fits the
  # decoded-shape (atoms + scalars + nested structs) cleanly. Users who
  # want flatc-shaped JSON instead use `to_json/1`.
  defp build_derive_attrs(niceties) do
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

  # Mirrors `file_identifier/0`: emitted only when the schema declares
  # a `file_extension`, absent otherwise. Purely informational — the
  # extension never appears on the wire; it's the conventional file
  # suffix for buffers of this schema (flatc uses it to name `--binary`
  # output, defaulting to ".bin").
  defp build_file_extension_funs(nil), do: ""

  defp build_file_extension_funs(ext) when is_binary(ext) do
    """

      @doc \"\"\"
      The `file_extension` this schema declares: the conventional file
      suffix (without the dot) for buffers rooted in this schema. It is
      metadata only and never written into the buffer.
      \"\"\"
      @spec file_extension() :: binary()
      def file_extension, do: #{inspect(ext)}
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
    # A field that is both `required` and `deprecated` is not enforced:
    # the encoder never writes deprecated slots, so demanding a value
    # we'd then throw away would make the table impossible to encode.
    # flatc's generated code drops the required check together with
    # the field.
    required =
      fields
      |> reject_deprecated()
      |> Enum.filter(fn f ->
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

  defp reject_deprecated(fields) do
    Enum.reject(fields, &Map.get(&1.attributes, :deprecated, false))
  end

  defp build_encode_build(t, schema, ns) do
    # `(deprecated)` fields are skipped on the encode side and still
    # accepted on the decode side, matching flatc's generated
    # builders, which emit no setter for them. The remaining fields
    # keep their id-derived vtable slots, so the deprecated slot stays
    # reserved on the wire — it's simply never written.
    live = %{t | fields: reject_deprecated(t.fields)}
    {prelude_lines, addrs_per_field} = build_subobject_prelude(live, schema, ns)
    field_add_lines = build_field_adds(live, schema, addrs_per_field, ns)

    """
        b = builder
    #{prelude_lines}    b = Wire.start_table(b)
    #{field_add_lines}    Wire.end_table(b)
    """
  end

  # For each field that references a sub-object (string/vector/sub-table),
  # emit code that builds it and stores its addr into a local variable.
  defp build_subobject_prelude(t, schema, ns) do
    {lines, addrs} =
      Enum.map_reduce(t.fields, %{}, fn f, acc ->
        case build_subobject_for_field(f, schema, ns) do
          nil ->
            {"", acc}

          {addr_var, line} ->
            {line, Map.put(acc, f.name, addr_var)}
        end
      end)

    {Enum.join(lines), addrs}
  end

  defp build_subobject_for_field(f, schema, ns) do
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
        mod = fqn_to_module(fqn, ns)
        {u, sz} = union_disc_info(fqn, schema)

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
                  {b, types_addr} = Wire.create_scalar_vector(b, discs, #{sz}, #{sz}, &Wire.push_#{u}/2)
                  {b, types_addr, vals_addr}
              end
        """

        {{:union_vec, types_var, var}, line}

      {:vector, inner} ->
        line = build_vector_prelude(f, var, field_lookup, inner, schema, ns)
        {var, line}

      {:table, fqn} ->
        line = """
            {b, #{var}} =
              case #{field_lookup} do
                nil -> {b, nil}
                v -> #{fqn_to_module(fqn, ns)}.build(b, v)
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
                  {b2, addr} = #{fqn_to_module(fqn, ns)}.build_variant(b, variant_atom, variant_value)
                  {b2, #{fqn_to_module(fqn, ns)}.discriminator(variant_atom), addr}
              end
        """

        {var, line}

      _ ->
        nil
    end
  end

  defp force_align(%{attributes: attrs}) do
    case Map.get(attrs, :force_align, 1) do
      n when is_integer(n) and n >= 1 -> n
      _ -> 1
    end
  end

  defp force_align(_), do: 1

  defp build_vector_prelude(f, var, field_lookup, inner, schema, ns) do
    # `(force_align: N)` on the vector field raises the element
    # alignment to at least N, so the contiguous vector body starts
    # at an N-aligned offset.
    force = force_align(f)

    case inner do
      {:scalar, kind} ->
        sz = Schema.scalar_size(kind)
        elem_align = max(sz, force)

        """
            {b, #{var}} =
              case #{field_lookup} do
                nil ->
                  {b, nil}

                list when is_list(list) ->
                  list = Enum.map(list, &Wire.check_scalar!(&1, #{inspect(kind)}, #{inspect(f.name)}))
                  Wire.create_scalar_vector(b, list, #{sz}, #{elem_align}, &Wire.push_#{kind}/2)
              end
        """

      :string ->
        # Vectors of strings store uoffsets (4-byte elements). force
        # alignment bumps the body-start alignment but the
        # `create_offset_vector` helper hard-codes elem alignment to 4;
        # for force_align > 4 we'd need a richer offset-vector helper.
        # Common case is force_align <= 4, which is a no-op here.
        _ = force

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
                      {acc2, a} = #{fqn_to_module(fqn, ns)}.build(acc, item)
                      {a, acc2}
                    end)

                  Wire.create_offset_vector(b, addrs)
              end
        """

      {:enum, fqn} ->
        %SchemaEnum{underlying_type: u} = Schema.fetch(schema, fqn)
        sz = Schema.scalar_size(u)
        elem_align = max(sz, force)
        mod = fqn_to_module(fqn, ns)
        check_kind = if u == :bool, do: :u8, else: u

        """
            {b, #{var}} =
              case #{field_lookup} do
                nil ->
                  {b, nil}

                list when is_list(list) ->
                  ints =
                    Enum.map(list, &Wire.check_scalar!(#{mod}.value(&1), #{inspect(check_kind)}, #{inspect(f.name)}))

                  Wire.create_scalar_vector(b, ints, #{sz}, #{elem_align}, &Wire.push_#{u}/2)
              end
        """

      {:struct, fqn} ->
        %SchemaStruct{size: sz, align: al} = Schema.fetch(schema, fqn)
        elem_align = max(al, force)
        mod = fqn_to_module(fqn, ns)

        """
            {b, #{var}} =
              case #{field_lookup} do
                nil ->
                  {b, nil}

                list when is_list(list) ->
                  count = length(list)
                  b1 = Wire.start_vector(b, count, #{sz}, #{elem_align})

                  b2 =
                    list
                    |> Enum.reverse()
                    |> Enum.reduce(b1, fn item, acc ->
                      acc = Wire.align(acc, #{elem_align})
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

  defp build_field_adds(t, schema, addrs, ns) do
    t.fields
    |> Enum.reverse()
    |> Enum.map_join("", fn f -> build_field_add(f, schema, addrs, ns) end)
  end

  defp build_field_add(f, schema, addrs, ns) do
    slot = f.vtable_slot

    case f.type do
      {:scalar, kind} ->
        # `= null` marks the field optional: nil is the omission
        # sentinel (so the slot is skipped when absent), and the
        # validator lets nil pass through.
        optional? = f.default == :null
        default = default_value(f, schema)

        raw_value =
          "Map.get(value, #{inspect(f.name)}, #{inspect(default)})"

        # `(hash: "fnv1_32")` etc. lets the user pass a string in place
        # of the int; the encoder hashes it on the way down. Integers
        # pass through unchanged. Validation runs post-hash, on the
        # integer headed for the wire.
        value_expr =
          case Map.get(f.attributes, :hash) do
            nil ->
              raw_value

            alg when is_binary(alg) ->
              "Wire.maybe_hash(#{raw_value}, #{inspect(String.to_atom(alg))})"
          end

        check_fn =
          if optional?, do: "Wire.check_optional_scalar!", else: "Wire.check_scalar!"

        checked = "#{check_fn}(#{value_expr}, #{inspect(kind)}, #{inspect(f.name)})"

        push_fn =
          if kind == :bool, do: "&Wire.push_bool/2", else: "&Wire.push_#{kind}/2"

        default_for_push = if optional?, do: nil, else: default

        """
            b = Wire.add_field_scalar(b, #{slot}, #{checked}, #{inspect(default_for_push)}, #{push_fn})
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
        optional? = f.default == :null
        default = default_value(f, schema)
        mod = fqn_to_module(fqn, ns)

        push_fn =
          if u == :bool, do: "&Wire.push_u8/2", else: "&Wire.push_#{u}/2"

        check_kind = if u == :bool, do: :u8, else: u

        checked =
          "Wire.check_scalar!(#{mod}.value(v), #{inspect(check_kind)}, #{inspect(f.name)})"

        # A nil value means: omit when the field is optional (`= null`)
        # or has no representable default (empty enum); otherwise it's
        # a wrong-typed value and gets the same tagged throw the
        # scalar validator uses.
        nil_branch =
          if optional? or default == nil do
            "b"
          else
            "throw({:invalid_scalar, #{inspect(f.name)}, #{inspect(check_kind)}, nil})"
          end

        {lookup, default_for_push} =
          if optional? do
            {"Map.get(value, #{inspect(f.name)})", nil}
          else
            {"Map.get(value, #{inspect(f.name)}, #{inspect(default)})",
             enum_default_int(enum_rec, default)}
          end

        """
            b =
              case #{lookup} do
                nil -> #{nil_branch}
                v -> Wire.add_field_scalar(b, #{slot}, #{checked}, #{inspect(default_for_push)}, #{push_fn})
              end
        """

      {:struct, fqn} ->
        %SchemaStruct{align: al} = Schema.fetch(schema, fqn)
        mod = fqn_to_module(fqn, ns)

        """
            b =
              case Map.get(value, #{inspect(f.name)}) do
                nil -> b
                v -> Wire.add_field_struct(b, #{slot}, #{mod}.encode(v), #{al})
              end
        """

      {:union, fqn} ->
        # `slot` is the value slot; discriminator lives at slot - 2 and
        # is written at the union's underlying width.
        disc_slot = slot - 2
        disc_var = "disc_#{f.name}"
        addr_var = "addr_#{f.name}"
        {u, _sz} = union_disc_info(fqn, schema)

        """
            b = Wire.add_field_offset(b, #{slot}, #{addr_var})
            b = Wire.add_field_scalar(b, #{disc_slot}, #{disc_var}, 0, &Wire.push_#{u}/2)
        """
    end
  end

  # The wire type and byte width of a union's discriminator — `:u8`/1
  # historically, wider when the schema declares an underlying type
  # (`union U : int { … }`).
  defp union_disc_info(fqn, schema) do
    %SchemaUnion{underlying_type: u} = Schema.fetch(schema, fqn)
    {u, Schema.scalar_size(u)}
  end

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
      |> reject_deprecated()
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
  defp recurses_field?({:vector, {:union, _}}), do: true
  defp recurses_field?(_), do: false

  defp build_verify_at(t, schema, ns) do
    # Deprecated fields keep their per-field content clause: our
    # decoder still reads them when present, so the verifier must
    # cover everything decode dereferences. Only the *required*
    # enforcement is dropped (below) — our own encoder never writes
    # deprecated slots, so a required-and-deprecated field would
    # otherwise reject every buffer we produce. flatc's generated
    # verifier likewise skips the check for deprecated fields.
    field_clauses =
      t.fields
      |> Enum.map(fn f -> verify_field(f, schema, ns) end)
      |> Enum.reject(&(&1 == ""))

    required_clauses =
      t.fields
      |> reject_deprecated()
      |> Enum.filter(fn f -> Map.get(f.attributes, :required) == true end)
      |> Enum.map(&verify_required_field/1)

    clauses = required_clauses ++ field_clauses

    case clauses do
      [] ->
        "      :ok\n"

      _ ->
        joined = Enum.map_join(clauses, ",\n         ", &String.trim/1)

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
              do: {:error, {:missing_required, #{inspect(f.name)}}, [#{inspect(f.name)}]},
              else: :ok)
    """
  end

  # Every present slot's voffset comes straight out of the (untrusted)
  # vtable, so each clause first checks the slot's bytes fit inside the
  # table's inline area via `Wire.verify_inline_field/3` — scalars and
  # inline structs in full, offset-typed fields for their 4-byte
  # uoffset — before anything dereferences it.
  defp verify_field(f, schema, ns) do
    case f.type do
      {:scalar, kind} ->
        verify_inline_only_field(f, Schema.scalar_size(kind))

      {:enum, fqn} ->
        %SchemaEnum{underlying_type: u} = Schema.fetch(schema, fqn)
        verify_inline_only_field(f, Schema.scalar_size(u))

      {:struct, fqn} ->
        %SchemaStruct{size: sz} = Schema.fetch(schema, fqn)
        verify_inline_only_field(f, sz)

      :string ->
        """
        :ok <- Wire.verify_path(
                 (case Wire.read_vtable_field(buf, pos, #{f.vtable_slot}) do
                    0 -> :ok
                    o ->
                      with :ok <- Wire.verify_inline_field(inline_size, o, 4),
                           {:ok, abs_pos} <- Wire.verify_follow_uoffset(buf, pos + o) do
                        Wire.verify_string_at(buf, abs_pos)
                      end
                  end),
                 #{inspect(f.name)})
        """

      {:vector, {:union, fqn}} ->
        verify_union_vector_field(f, fqn, schema, ns)

      {:vector, inner} ->
        verify_vector_field(f, inner, schema, ns)

      {:table, fqn} ->
        mod = fqn_to_module(fqn, ns)

        """
        :ok <- Wire.verify_path(
                 (case Wire.read_vtable_field(buf, pos, #{f.vtable_slot}) do
                    0 -> :ok
                    o ->
                      with :ok <- Wire.verify_inline_field(inline_size, o, 4),
                           {:ok, abs_pos} <- Wire.verify_follow_uoffset(buf, pos + o) do
                        #{mod}.__verify_at__(buf, abs_pos, depth - 1)
                      end
                  end),
                 #{inspect(f.name)})
        """

      {:union, fqn} ->
        mod = fqn_to_module(fqn, ns)
        disc_slot = f.vtable_slot - 2
        {u, sz} = union_disc_info(fqn, schema)

        """
        :ok <- Wire.verify_path(
                 (case Wire.read_vtable_field(buf, pos, #{disc_slot}) do
                    0 -> :ok
                    type_o ->
                      with :ok <- Wire.verify_inline_field(inline_size, type_o, #{sz}) do
                        case Wire.read_vtable_field(buf, pos, #{f.vtable_slot}) do
                          0 -> :ok
                          value_o ->
                            with :ok <- Wire.verify_inline_field(inline_size, value_o, 4),
                                 {:ok, abs_pos} <- Wire.verify_follow_uoffset(buf, pos + value_o) do
                              disc = Wire.read_#{u}(buf, pos + type_o)
                              #{mod}.__verify_variant__(buf, disc, abs_pos, depth - 1)
                            end
                        end
                      end
                  end),
                 #{inspect(f.name)})
        """
    end
  end

  defp verify_inline_only_field(f, field_bytes) do
    """
    :ok <- Wire.verify_path(
             (case Wire.read_vtable_field(buf, pos, #{f.vtable_slot}) do
                0 -> :ok
                o -> Wire.verify_inline_field(inline_size, o, #{field_bytes})
              end),
             #{inspect(f.name)})
    """
  end

  # Vector-of-union: two parallel vectors that must agree. Mirrors
  # flatc's generated Verify<Union>Vector: both-or-neither present,
  # equal element counts, and NONE (discriminator 0) elements verified
  # by skipping their value slot entirely.
  defp verify_union_vector_field(f, fqn, schema, ns) do
    mod = fqn_to_module(fqn, ns)
    disc_slot = f.vtable_slot - 2
    {u, sz} = union_disc_info(fqn, schema)

    """
    :ok <- Wire.verify_path(
             (case {Wire.read_vtable_field(buf, pos, #{disc_slot}),
                    Wire.read_vtable_field(buf, pos, #{f.vtable_slot})} do
                {0, 0} ->
                  :ok

                {type_o, value_o} when type_o == 0 or value_o == 0 ->
                  {:error, :union_vector_presence_mismatch}

                {type_o, value_o} ->
                  with :ok <- Wire.verify_inline_field(inline_size, type_o, 4),
                       :ok <- Wire.verify_inline_field(inline_size, value_o, 4),
                       {:ok, types_pos} <- Wire.verify_follow_uoffset(buf, pos + type_o),
                       {:ok, vals_pos} <- Wire.verify_follow_uoffset(buf, pos + value_o),
                       {:ok, types_count} <- Wire.verify_vector_at(buf, types_pos, #{sz}),
                       {:ok, values_count} <- Wire.verify_vector_at(buf, vals_pos, 4),
                       :ok <-
                         (if types_count == values_count,
                            do: :ok,
                            else: {:error, {:union_vector_count_mismatch, types_count, values_count}}) do
                    Enum.reduce_while(0..(types_count - 1)//1, :ok, fn i, _ ->
                      case Wire.read_#{u}(buf, Wire.vector_elem_pos(types_pos, i, #{sz})) do
                        0 ->
                          {:cont, :ok}

                        disc ->
                          with {:ok, abs_pos} <-
                                 Wire.verify_follow_uoffset(buf, Wire.vector_elem_pos(vals_pos, i, 4)),
                               :ok <- #{mod}.__verify_variant__(buf, disc, abs_pos, depth - 1) do
                            {:cont, :ok}
                          else
                            err -> {:halt, Wire.verify_path(err, i)}
                          end
                      end
                    end)
                  end
              end),
             #{inspect(f.name)})
    """
  end

  defp verify_vector_field(f, inner, schema, ns) do
    {elem_size, elem_verifier} = vector_elem_verify(inner, schema, ns)

    """
    :ok <- Wire.verify_path(
             (case Wire.read_vtable_field(buf, pos, #{f.vtable_slot}) do
                0 -> :ok
                o ->
                  with :ok <- Wire.verify_inline_field(inline_size, o, 4),
                       {:ok, vec_pos} <- Wire.verify_follow_uoffset(buf, pos + o),
                       {:ok, count} <- Wire.verify_vector_at(buf, vec_pos, #{elem_size}) do
                    Enum.reduce_while(0..(count - 1)//1, :ok, fn i, _acc ->
                      elem_pos = Wire.vector_elem_pos(vec_pos, i, #{elem_size})
                      case #{elem_verifier} do
                        :ok -> {:cont, :ok}
                        err -> {:halt, Wire.verify_path(err, i)}
                      end
                    end)
                  end
              end),
             #{inspect(f.name)})
    """
  end

  # Returns {elem_size, verify_expr} where verify_expr uses `elem_pos`,
  # `buf`, and `depth` and produces :ok or {:error, _}.
  defp vector_elem_verify({:scalar, kind}, _, _ns),
    do:
      {Schema.scalar_size(kind), "Wire.verify_bounds(buf, elem_pos, #{Schema.scalar_size(kind)})"}

  defp vector_elem_verify(:string, _, _ns),
    do:
      {4,
       "(case Wire.verify_follow_uoffset(buf, elem_pos) do {:ok, sp} -> Wire.verify_string_at(buf, sp); e -> e end)"}

  defp vector_elem_verify({:enum, fqn}, schema, _ns) do
    %SchemaEnum{underlying_type: u} = Schema.fetch(schema, fqn)
    sz = Schema.scalar_size(u)
    {sz, "Wire.verify_bounds(buf, elem_pos, #{sz})"}
  end

  defp vector_elem_verify({:struct, fqn}, schema, _ns) do
    %SchemaStruct{size: sz} = Schema.fetch(schema, fqn)
    {sz, "Wire.verify_bounds(buf, elem_pos, #{sz})"}
  end

  defp vector_elem_verify({:table, fqn}, _, ns),
    do:
      {4,
       "(case Wire.verify_follow_uoffset(buf, elem_pos) do {:ok, tp} -> #{fqn_to_module(fqn, ns)}.__verify_at__(buf, tp, depth - 1); e -> e end)"}

  defp vector_elem_verify({:union, _fqn}, _, _ns) do
    # Vectors of unions are handled specially in verify_field/3 above
    # (they take two parallel vtable slots). This clause shouldn't be
    # reached, but kept for safety.
    {4, "Wire.verify_bounds(buf, elem_pos, 4)"}
  end

  # -----------------------------------------------------------------------
  # JSON map builders
  # -----------------------------------------------------------------------

  defp build_to_json_map(t, schema, ns) do
    t.fields
    # `(deprecated)` fields are intentionally dropped from JSON
    # output: to_json reflects what encode/1 would write, and flatc's
    # *generated* readers can't see deprecated fields at all. Note
    # that flatc's schema-driven `flatc --json` tool diverges here —
    # probed at 25.12.19, it prints a deprecated field whenever the
    # buffer physically contains the slot (and its JSON parser will
    # happily accept and write one, too).
    |> reject_deprecated()
    |> Enum.map_join("", fn f ->
      key = inspect(Atom.to_string(f.name))
      val = "Map.get(value, #{inspect(f.name)})"

      case f.type do
        {:union, fqn} ->
          mod = fqn_to_module(fqn, ns)
          type_key = inspect(Atom.to_string(f.name) <> "_type")

          """
                {#{type_key}, #{mod}.__to_json_type__(#{val})},
                {#{key}, #{mod}.__to_json_value__(#{val})},
          """

        {:vector, {:union, fqn}} ->
          mod = fqn_to_module(fqn, ns)
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
          expr = to_json_value_expr(f.type, val, schema, ns)
          "      {#{key}, #{expr}},\n"
      end
    end)
  end

  defp build_from_json_map(t, schema, ns) do
    Enum.map_join(t.fields, "", fn f ->
      key = inspect(Atom.to_string(f.name))

      case f.type do
        {:union, fqn} ->
          mod = fqn_to_module(fqn, ns)
          type_key = inspect(Atom.to_string(f.name) <> "_type")

          "      #{f.name}: #{mod}.__from_json__(Map.get(map, #{type_key}), Map.get(map, #{key})),\n"

        {:vector, {:union, fqn}} ->
          mod = fqn_to_module(fqn, ns)
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
          expr = from_json_value_expr(f.type, val, schema, ns)
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

  defp to_json_value_expr({:scalar, k}, val, _, _ns) when k in [:f32, :f64] do
    "(case #{val} do :nan -> \"nan\"; :infinity -> \"inf\"; :neg_infinity -> \"-inf\"; v -> v end)"
  end

  defp to_json_value_expr({:scalar, _}, val, _, _ns), do: val
  defp to_json_value_expr(:string, val, _, _ns), do: val

  defp to_json_value_expr({:enum, fqn}, val, _, ns),
    do: "if(#{val} == nil, do: nil, else: #{fqn_to_module(fqn, ns)}.__to_json__(#{val}))"

  defp to_json_value_expr({:struct, fqn}, val, _, ns),
    do: "if(#{val} == nil, do: nil, else: #{fqn_to_module(fqn, ns)}.__to_json_map__(#{val}))"

  defp to_json_value_expr({:table, fqn}, val, _, ns),
    do: "if(#{val} == nil, do: nil, else: #{fqn_to_module(fqn, ns)}.__to_json_map__(#{val}))"

  defp to_json_value_expr({:vector, inner}, val, schema, ns) do
    inner_expr = to_json_value_expr(inner, "v", schema, ns)
    "Enum.map(#{val} || [], fn v -> #{inner_expr} end)"
  end

  # Phase 3 stub — vectors of unions emit nothing.
  defp to_json_value_expr({:union, _}, _val, _schema, _ns), do: "nil"

  defp from_json_value_expr({:scalar, k}, val, _, _ns) when k in [:f32, :f64] do
    "(case #{val} do \"nan\" -> :nan; \"inf\" -> :infinity; \"-inf\" -> :neg_infinity; v -> v end)"
  end

  defp from_json_value_expr({:scalar, _}, val, _, _ns), do: val
  defp from_json_value_expr(:string, val, _, _ns), do: val

  defp from_json_value_expr({:enum, fqn}, val, _, ns),
    do: "if(#{val} == nil, do: nil, else: #{fqn_to_module(fqn, ns)}.__from_json__(#{val}))"

  defp from_json_value_expr({:struct, fqn}, val, _, ns),
    do: "if(#{val} == nil, do: nil, else: #{fqn_to_module(fqn, ns)}.__from_json_map__(#{val}))"

  defp from_json_value_expr({:table, fqn}, val, _, ns),
    do: "if(#{val} == nil, do: nil, else: #{fqn_to_module(fqn, ns)}.__from_json_map__(#{val}))"

  defp from_json_value_expr({:vector, inner}, val, schema, ns) do
    inner_expr = from_json_value_expr(inner, "v", schema, ns)
    "Enum.map(#{val} || [], fn v -> #{inner_expr} end)"
  end

  defp from_json_value_expr({:union, _}, _val, _schema, _ns), do: "nil"

  # -----------------------------------------------------------------------
  # Misc
  # -----------------------------------------------------------------------

  defp trim_trailing_comma(s) do
    String.replace(s, ~r/,\n$/, "\n")
  end

  defp fqn_to_module(fqn, ns), do: Naming.module_name(fqn, ns)
end
