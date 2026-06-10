defmodule Flatbuf.Schema.Resolver do
  @moduledoc """
  CST → `%Flatbuf.Schema{}` normalization.

  * Resolves `include "..."` paths recursively (cycle-safe).
  * Threads `namespace` declarations through all subsequent decls.
  * Assigns vtable slots to table fields in declaration order.
  * Computes struct layouts (offsets, total size, alignment).
  * Computes enum values (implicit increment, explicit overrides).
  * Validates type references against the loaded type table.
  """

  alias Flatbuf.Schema
  alias Flatbuf.Schema.Enum, as: SchemaEnum
  alias Flatbuf.Schema.Field
  alias Flatbuf.Schema.Parser
  alias Flatbuf.Schema.Struct, as: SchemaStruct
  alias Flatbuf.Schema.Table
  alias Flatbuf.Schema.Union

  @doc """
  Resolve a single schema source string with no includes.

  Used by tests and code that constructs schemas in memory.
  """
  @spec resolve_source(binary()) :: {:ok, Schema.t()} | {:error, term()}
  def resolve_source(source) when is_binary(source) do
    with {:ok, decls} <- Parser.parse(source) do
      normalize([{:inline, decls}])
    end
  end

  @doc """
  Resolve a `.fbs` file from disk, following `include` statements recursively.

  Options:

    * `:include_paths` — list of additional directories to search for
      included files. Mirrors flatc's `-I PATH` flag. The directory of
      the *including* file is always tried first; the search paths are
      tried in order if that fails.
  """
  @spec resolve_path(Path.t(), keyword()) :: {:ok, Schema.t()} | {:error, term()}
  def resolve_path(path, opts \\ []) do
    abs = Path.expand(path)
    include_paths = Keyword.get(opts, :include_paths, []) |> Enum.map(&Path.expand/1)

    case load_all(abs, include_paths, %{}, []) do
      {:ok, _seen, loaded} -> normalize(loaded)
      {:error, _} = err -> err
    end
  end

  defp load_all(path, include_paths, seen, acc) do
    if Map.has_key?(seen, path) do
      {:ok, seen, acc}
    else
      with {:ok, src} <- read_file(path),
           {:ok, decls} <- Parser.parse(src) do
        seen2 = Map.put(seen, path, true)
        acc2 = acc ++ [{path, decls}]
        load_includes(decls, path, include_paths, seen2, acc2)
      end
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, src} -> {:ok, src}
      {:error, reason} -> {:error, {:cannot_read, path, reason}}
    end
  end

  defp load_includes([], _includer, _ip, seen, acc), do: {:ok, seen, acc}

  defp load_includes([{:include, rel, _line} | rest], includer, include_paths, seen, acc) do
    case resolve_include(rel, includer, include_paths) do
      {:ok, full} ->
        case load_all(full, include_paths, seen, acc) do
          {:ok, seen2, acc2} ->
            load_includes(rest, includer, include_paths, seen2, acc2)

          err ->
            err
        end

      :not_found ->
        searched = include_candidates(rel, includer, include_paths)

        {:error,
         {:include_not_found, rel, Path.relative_to_cwd(includer),
          Enum.map(searched, &Path.relative_to_cwd/1)}}
    end
  end

  defp load_includes([_ | rest], includer, include_paths, seen, acc),
    do: load_includes(rest, includer, include_paths, seen, acc)

  # First try the including file's own directory (standard flatc behaviour),
  # then each `-I` search path in order.
  defp resolve_include(rel, includer, include_paths) do
    case Enum.find(include_candidates(rel, includer, include_paths), &File.regular?/1) do
      nil -> :not_found
      path -> {:ok, path}
    end
  end

  defp include_candidates(rel, includer, include_paths) do
    Enum.uniq([
      Path.expand(Path.join(Path.dirname(includer), rel))
      | Enum.map(include_paths, &Path.join(&1, rel))
    ])
  end

  # Normalize per-file declarations into a Schema --------------------------

  defp normalize(files) do
    schema = %Schema{source_files: Enum.map(files, &elem(&1, 0))}

    {schema, root} =
      Enum.reduce(files, {schema, nil}, fn {_file, decls}, {sch, root} ->
        state = %{namespace: nil, schema: sch, root: root}
        final = Enum.reduce(decls, state, &add_decl/2)
        {final.schema, final.root}
      end)

    {:ok, finalize(schema, root)}
  catch
    {:resolve_error, reason} -> {:error, reason}
  end

  defp add_decl({:namespace, name, _line}, state),
    do: %{state | namespace: name}

  defp add_decl({:include, _path, _line}, state), do: state

  # Recorded with the namespace in effect at the declaration site and
  # resolved at finalize time, once every type is known.
  defp add_decl({:root_type, name, line}, state),
    do: %{state | root: {name, state.namespace, line}}

  defp add_decl({:file_identifier, id, _line}, state) do
    if byte_size(id) != 4 do
      throw({:resolve_error, {:bad_file_identifier_length, id}})
    end

    %{state | schema: %{state.schema | file_identifier: id}}
  end

  defp add_decl({:file_extension, ext, _line}, state),
    do: %{state | schema: %{state.schema | file_extension: ext}}

  defp add_decl({:attribute_decl, _name, _line}, state), do: state

  # RPC services are parsed for completeness but don't generate code.
  defp add_decl({:rpc_service, _body}, state), do: state

  defp add_decl({:table, body}, state) do
    fqn = qualify(body.name, state.namespace)
    check_duplicate_field_names(fqn, body.fields)

    table = %Table{
      name: fqn,
      namespace: state.namespace,
      short_name: body.name,
      fields: Enum.map(body.fields, &build_field/1),
      attributes: normalize_attrs(body.attributes),
      docs: body.docs
    }

    %{state | schema: put_type(state.schema, fqn, table)}
  end

  defp add_decl({:struct, body}, state) do
    fqn = qualify(body.name, state.namespace)

    if body.fields == [] do
      throw({:resolve_error, {:empty_struct, fqn, body.line}})
    end

    check_duplicate_field_names(fqn, body.fields)

    Enum.each(body.fields, fn f ->
      if f.default != nil do
        throw({:resolve_error, {:default_on_struct_field, fqn, f.name, f.line}})
      end
    end)

    struct_rec = %SchemaStruct{
      name: fqn,
      namespace: state.namespace,
      short_name: body.name,
      fields: Enum.map(body.fields, &build_field/1),
      attributes: normalize_attrs(body.attributes),
      docs: body.docs
    }

    %{state | schema: put_type(state.schema, fqn, struct_rec)}
  end

  defp add_decl({:union, body}, state) do
    fqn = qualify(body.name, state.namespace)
    check_duplicate_names(body.variants, &{:duplicate_union_variant, fqn, &1, &2})

    underlying = union_underlying(body, fqn, state)

    # Discriminator 0 is NONE, so the default u8 leaves room for 255
    # variants. With an explicit underlying type the per-value range
    # check in compute_union_values is the governing rule, as in flatc.
    if body.underlying_type == nil and length(body.variants) > 255 do
      throw({:resolve_error, {:too_many_union_variants, fqn, length(body.variants)}})
    end

    variants = compute_union_values(body.variants, fqn, underlying)

    union = %Union{
      name: fqn,
      namespace: state.namespace,
      short_name: body.name,
      underlying_type: underlying,
      variants: variants,
      attributes: normalize_attrs(body.attributes),
      docs: body.docs
    }

    %{state | schema: put_type(state.schema, fqn, union)}
  end

  defp add_decl({:enum, body}, state) do
    fqn = qualify(body.name, state.namespace)
    attrs = normalize_attrs(body.attributes)
    bit_flags? = Map.has_key?(attrs, :bit_flags)

    underlying =
      case body.underlying_type do
        u when u in [:i8, :u8, :i16, :u16, :i32, :u32, :i64, :u64] -> u
        other -> throw({:resolve_error, {:bad_enum_underlying, fqn, other}})
      end

    check_duplicate_names(body.variants, &{:duplicate_enum_variant, fqn, &1, &2})
    variants = compute_enum_values(body.variants, bit_flags?, fqn, underlying)

    enum = %SchemaEnum{
      name: fqn,
      namespace: state.namespace,
      short_name: body.name,
      underlying_type: underlying,
      variants: variants,
      attributes: attrs,
      docs: body.docs,
      bit_flags?: bit_flags?
    }

    %{state | schema: put_type(state.schema, fqn, enum)}
  end

  @integral_scalars [:i8, :u8, :i16, :u16, :i32, :u32, :i64, :u64]

  # flatc: "underlying uniontype must be integral". Integral scalars
  # pass through; a named ref must be an *already declared* enum —
  # flatc resolves this single-pass, so forward references are
  # rejected too — and the union inherits the enum's own width.
  defp union_underlying(%{underlying_type: nil}, _fqn, _state), do: :u8

  defp union_underlying(%{underlying_type: {:scalar, s}}, _fqn, _state)
       when s in @integral_scalars,
       do: s

  defp union_underlying(%{underlying_type: {:name, name}} = body, fqn, state) do
    found =
      name
      |> enumerate_candidates(state.namespace)
      |> Enum.find_value(fn cand -> Map.get(state.schema.types, cand) end)

    case found do
      %SchemaEnum{underlying_type: u} ->
        u

      _ ->
        throw({:resolve_error, {:union_underlying_not_integral, fqn, name, body.line}})
    end
  end

  defp union_underlying(%{underlying_type: other} = body, fqn, _state),
    do: throw({:resolve_error, {:union_underlying_not_integral, fqn, other, body.line}})

  # Union discriminator values: 0 is reserved for NONE; explicit `= N`
  # values are honored and implicit ones increment from the previous
  # (starting at 1). Every value must fit the underlying type. flatc
  # accepts duplicate values between variants (the first declaration
  # wins on decode) but rejects a collision with NONE at 0.
  defp compute_union_values(variants, fqn, underlying) do
    {lo, hi} = scalar_int_range(underlying)

    {result, _next} =
      Enum.map_reduce(variants, 1, fn v, expected ->
        disc = v.value || expected

        if disc < lo or disc > hi do
          throw({:resolve_error, {:union_value_out_of_range, fqn, v.name, disc, v.line}})
        end

        if disc == 0 do
          throw({:resolve_error, {:union_value_collides_with_none, fqn, v.name, v.line}})
        end

        {{String.to_atom(v.name), v.type, disc}, disc + 1}
      end)

    result
  end

  defp build_field(f) do
    %Field{
      name: String.to_atom(f.name),
      type: f.type,
      default: f.default,
      attributes: normalize_attrs(f.attributes),
      docs: f.docs,
      line: f.line
    }
  end

  defp check_duplicate_field_names(fqn, fields),
    do: check_duplicate_names(fields, &{:duplicate_field, fqn, &1, &2})

  defp check_duplicate_names(entries, error_fun) do
    Enum.reduce(entries, MapSet.new(), fn entry, seen ->
      if MapSet.member?(seen, entry.name) do
        throw({:resolve_error, error_fun.(entry.name, entry.line)})
      end

      MapSet.put(seen, entry.name)
    end)
  end

  defp put_type(schema, fqn, rec) do
    if Map.has_key?(schema.types, fqn) do
      throw({:resolve_error, {:duplicate_type, fqn}})
    end

    %{schema | types: Map.put(schema.types, fqn, rec)}
  end

  # Finalization: resolve forward refs and compute layouts -----------------

  defp finalize(schema, root) do
    schema = %{
      schema
      | types: Map.new(schema.types, fn {k, v} -> {k, resolve_refs(v, schema)} end)
    }

    # Collapse manual union-split pairs (`foo_type:UnionT; foo:UnionT;`)
    # before slot assignment so the surviving field gets the right slot.
    schema = %{
      schema
      | types: Map.new(schema.types, fn {k, v} -> {k, collapse_union_splits(v)} end)
    }

    schema = %{schema | types: Map.new(schema.types, fn {k, v} -> {k, assign_slots(v)} end)}

    # Struct layouts must be computed in dependency order — a struct
    # containing another struct needs the inner one's `size`/`align` to
    # be set first.
    schema = layout_all_structs(schema)

    resolve_root(schema, root)
  end

  # flatc resolves `root_type Name` by trying the name as written first
  # (so a global or fully-qualified name wins), then qualified with the
  # namespace in effect at the declaration. No parent-namespace walk-up.
  defp resolve_root(schema, nil), do: schema

  defp resolve_root(schema, {name, ns, line}) do
    candidates = Enum.uniq([name, qualify(name, ns)])

    case Enum.find(candidates, &Map.has_key?(schema.types, &1)) do
      nil -> throw({:resolve_error, {:unknown_root_type, name, line}})
      fqn -> %{schema | root_type: fqn}
    end
  end

  # If a table is declared with `foo_type:UnionT; foo:UnionT;` (the
  # manual-split form that monster_test.fbs uses with explicit ids),
  # collapse the pair into one logical union field named `foo`.
  # The discriminator slot follows the `_type` field's slot; the value
  # slot is `disc_slot + 2`, as auto-expanded unions already do.
  defp collapse_union_splits(%Table{fields: fields} = t),
    do: %{t | fields: do_collapse(fields, [])}

  defp collapse_union_splits(other), do: other

  defp do_collapse([], acc), do: Enum.reverse(acc)

  defp do_collapse([a, b | rest], acc) do
    if manual_union_pair?(a, b) do
      # `b` is the value field and already carries the correct id (or
      # gets the right auto-allocated slot from assign_slots). The
      # discriminator field `a` was redundant — slot - 2 is derived.
      do_collapse(rest, [b | acc])
    else
      do_collapse([b | rest], [a | acc])
    end
  end

  defp do_collapse([f | rest], acc), do: do_collapse(rest, [f | acc])

  defp manual_union_pair?(%Field{type: {:union, t}} = a, %Field{type: {:union, t}} = b) do
    a_name = Atom.to_string(a.name)
    b_name = Atom.to_string(b.name)
    String.ends_with?(a_name, "_type") and String.replace_suffix(a_name, "_type", "") == b_name
  end

  defp manual_union_pair?(_, _), do: false

  defp layout_all_structs(schema) do
    structs = Schema.structs(schema)
    graph = Map.new(structs, fn s -> {s.name, struct_deps(s)} end)
    order = topo_sort(Map.keys(graph), graph)

    Enum.reduce(order, schema, fn fqn, sch ->
      case Schema.fetch(sch, fqn) do
        nil -> sch
        rec -> %{sch | types: Map.put(sch.types, fqn, compute_struct_layout(rec, sch))}
      end
    end)
  end

  defp struct_deps(%SchemaStruct{fields: fields}) do
    Enum.flat_map(fields, &struct_field_deps(&1.type))
  end

  defp struct_field_deps({:struct, fqn}), do: [fqn]
  defp struct_field_deps({:array, inner, _}), do: struct_field_deps(inner)
  defp struct_field_deps(_), do: []

  defp topo_sort(nodes, graph) do
    # Plain maps (key => true) stand in for sets here. MapSet would
    # express the intent better but dialyzer can't carry the opaque
    # type through the mutual recursion below — using a map keeps
    # the inference clean.
    {_, sorted} =
      Enum.reduce(nodes, {%{}, []}, fn node, {seen, acc} ->
        visit(node, graph, seen, acc, %{})
      end)

    Enum.reverse(sorted)
  end

  defp visit(node, graph, seen, acc, stack) do
    cond do
      Map.has_key?(stack, node) ->
        throw({:resolve_error, {:struct_cycle, node}})

      Map.has_key?(seen, node) ->
        {seen, acc}

      true ->
        stack = Map.put(stack, node, true)
        deps = Map.get(graph, node, [])

        {seen, acc} =
          Enum.reduce(deps, {seen, acc}, fn d, {s, a} ->
            if Map.has_key?(graph, d), do: visit(d, graph, s, a, stack), else: {s, a}
          end)

        {Map.put(seen, node, true), [node | acc]}
    end
  end

  defp resolve_refs(%Table{} = t, schema) do
    fields =
      t.fields
      |> Enum.map(&resolve_field_ref(&1, t.namespace, schema))
      |> Enum.map(&validate_table_field(&1, t.name, schema))

    %{t | fields: fields}
  end

  defp resolve_refs(%SchemaStruct{} = s, schema) do
    fields = Enum.map(s.fields, &resolve_field_ref(&1, s.namespace, schema))

    Enum.each(fields, fn f ->
      case f.type do
        {:scalar, _} -> :ok
        {:enum, _} -> :ok
        {:struct, _} -> :ok
        {:array, inner, n} -> check_array(s.name, Atom.to_string(f.name), inner, n, f.line)
        other -> throw({:resolve_error, {:bad_struct_field_type, s.name, f.name, other}})
      end
    end)

    %{s | fields: fields}
  end

  defp resolve_refs(%Union{} = u, schema) do
    variants =
      Enum.map(u.variants, fn {name, type, disc} ->
        {name, resolve_type(type, u.namespace, schema), disc}
      end)

    Enum.each(variants, fn {name, type, _} ->
      case type do
        {:table, _} -> :ok
        {:struct, _} -> :ok
        :string -> :ok
        other -> throw({:resolve_error, {:bad_union_variant_type, u.name, name, other}})
      end
    end)

    %{u | variants: variants}
  end

  defp resolve_refs(other, _schema), do: other

  defp check_array(struct_name, field_name, inner, n, line) do
    # flatc: "length of fixed-length array must be positive and fit to
    # uint16_t type".
    if n < 1 or n > 65_535 do
      throw({:resolve_error, {:bad_array_length, struct_name, field_name, n, line}})
    end

    case inner do
      {:scalar, _} -> :ok
      {:enum, _} -> :ok
      {:struct, _} -> :ok
      other -> throw({:resolve_error, {:bad_array_element_type, struct_name, field_name, other}})
    end
  end

  # Per-field table validation: structural restrictions, `required`
  # placement, and default-value typing. Returns the field with its
  # default normalized to the literal shapes codegen understands.
  defp validate_table_field(f, table_fqn, schema) do
    check_table_field_type(f, table_fqn)

    if Map.has_key?(f.attributes, :required) and
         match?({kind, _} when kind in [:scalar, :enum], f.type) do
      throw({:resolve_error, {:required_on_scalar, table_fqn, fname(f), f.line}})
    end

    %{f | default: validate_default(f, table_fqn, schema)}
  end

  defp check_table_field_type(f, table_fqn) do
    case f.type do
      {:array, _, _} ->
        throw({:resolve_error, {:array_in_table, table_fqn, fname(f), f.line}})

      {:vector, {:vector, _}} ->
        throw({:resolve_error, {:nested_vector, table_fqn, fname(f), f.line}})

      {:vector, {:array, _, _}} ->
        throw({:resolve_error, {:array_in_table, table_fqn, fname(f), f.line}})

      _ ->
        :ok
    end
  end

  # Default-value typing. Mirrors flatc: scalars and enums take defaults
  # (range-checked; numeric strings are parsed); strings take string
  # literals; vectors only `= []`; table/struct/union fields take none.
  # `= null` (optional) is allowed on scalars and enums only.
  defp validate_default(%Field{default: nil}, _table, _schema), do: nil

  defp validate_default(%Field{type: {:scalar, :bool}} = f, table, _schema) do
    case f.default do
      :null -> :null
      {:bool, _} = b -> b
      {:int, n} -> {:bool, n != 0}
      {:string, "true"} -> {:bool, true}
      {:string, "false"} -> {:bool, false}
      {:string, s} -> {:bool, parse_int_string(s, f, table) != 0}
      other -> throw({:resolve_error, {:invalid_default, table, fname(f), other, f.line}})
    end
  end

  defp validate_default(%Field{type: {:scalar, kind}} = f, table, _schema)
       when kind in [:f32, :f64] do
    case f.default do
      :null -> :null
      {:float, _} = fl -> fl
      {:int, _} = i -> i
      {:string, s} -> parse_number_string(s, f, table)
      other -> throw({:resolve_error, {:invalid_default, table, fname(f), other, f.line}})
    end
  end

  defp validate_default(%Field{type: {:scalar, kind}} = f, table, _schema) do
    case f.default do
      :null -> :null
      {:int, n} -> {:int, check_int_range(n, kind, f, table)}
      {:string, s} -> {:int, check_int_range(parse_int_string(s, f, table), kind, f, table)}
      other -> throw({:resolve_error, {:invalid_default, table, fname(f), other, f.line}})
    end
  end

  defp validate_default(%Field{type: {:enum, fqn}} = f, table, schema) do
    enum = Schema.fetch(schema, fqn)

    case f.default do
      :null ->
        :null

      {:ident, name} ->
        {:ident, check_enum_member(enum, name, f, table)}

      {:int, n} ->
        {:int, check_enum_int(enum, n, f, table)}

      {:string, s} ->
        if Enum.any?(enum.variants, fn {vname, _} -> Atom.to_string(vname) == s end) do
          {:ident, s}
        else
          {:int, check_enum_int(enum, parse_int_string(s, f, table), f, table)}
        end

      other ->
        throw({:resolve_error, {:invalid_default, table, fname(f), other, f.line}})
    end
  end

  defp validate_default(%Field{type: :string} = f, table, _schema) do
    case f.default do
      {:string, _} = s -> s
      other -> throw({:resolve_error, {:invalid_default, table, fname(f), other, f.line}})
    end
  end

  defp validate_default(%Field{type: {:vector, _}} = f, table, _schema) do
    case f.default do
      # `= []` is legal (and is what the wire format already means by an
      # absent vector); non-empty vector defaults are not expressible.
      {:array, []} = a -> a
      other -> throw({:resolve_error, {:invalid_default, table, fname(f), other, f.line}})
    end
  end

  defp validate_default(%Field{default: default} = f, table, _schema),
    do: throw({:resolve_error, {:invalid_default, table, fname(f), default, f.line}})

  defp parse_int_string(s, f, table) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> throw({:resolve_error, {:invalid_default, table, fname(f), {:string, s}, f.line}})
    end
  end

  defp parse_number_string(s, f, table) do
    case Integer.parse(s) do
      {n, ""} ->
        {:int, n}

      _ ->
        case Float.parse(s) do
          {fl, ""} -> {:float, fl}
          _ -> throw({:resolve_error, {:invalid_default, table, fname(f), {:string, s}, f.line}})
        end
    end
  end

  defp check_int_range(n, kind, f, table) do
    {lo, hi} = scalar_int_range(kind)

    if n < lo or n > hi do
      throw({:resolve_error, {:default_out_of_range, table, fname(f), n, kind, f.line}})
    end

    n
  end

  defp check_enum_member(%SchemaEnum{} = enum, name, f, table) do
    atom = String.to_atom(name)

    if Enum.any?(enum.variants, fn {vname, _} -> vname == atom end) do
      name
    else
      throw({:resolve_error, {:unknown_enum_default, table, fname(f), name, f.line}})
    end
  end

  # For bit_flags enums any value that fits the underlying type is legal
  # (it's a flag combination); plain enums require an exact member value.
  defp check_enum_int(%SchemaEnum{bit_flags?: true, underlying_type: u}, n, f, table),
    do: check_int_range(n, u, f, table)

  defp check_enum_int(%SchemaEnum{variants: variants}, n, f, table) do
    if Enum.any?(variants, fn {_, v} -> v == n end) do
      n
    else
      throw({:resolve_error, {:enum_default_not_member, table, fname(f), n, f.line}})
    end
  end

  defp scalar_int_range(:i8), do: {-128, 127}
  defp scalar_int_range(:u8), do: {0, 255}
  defp scalar_int_range(:i16), do: {-32_768, 32_767}
  defp scalar_int_range(:u16), do: {0, 65_535}
  defp scalar_int_range(:i32), do: {-2_147_483_648, 2_147_483_647}
  defp scalar_int_range(:u32), do: {0, 4_294_967_295}
  defp scalar_int_range(:i64), do: {-9_223_372_036_854_775_808, 9_223_372_036_854_775_807}
  defp scalar_int_range(:u64), do: {0, 18_446_744_073_709_551_615}

  defp resolve_field_ref(%Field{type: type} = f, namespace, schema) do
    %{f | type: resolve_type(type, namespace, schema)}
  end

  defp resolve_type({:scalar, _} = t, _ns, _schema), do: t
  defp resolve_type(:string, _ns, _schema), do: :string
  defp resolve_type({:vector, inner}, ns, schema), do: {:vector, resolve_type(inner, ns, schema)}

  defp resolve_type({:array, inner, n}, ns, schema),
    do: {:array, resolve_type(inner, ns, schema), n}

  defp resolve_type({:name, name}, ns, schema) do
    fqn = lookup_name(name, ns, schema)

    case Schema.fetch(schema, fqn) do
      %Table{} -> {:table, fqn}
      %SchemaStruct{} -> {:struct, fqn}
      %SchemaEnum{} -> {:enum, fqn}
      %Union{} -> {:union, fqn}
      nil -> throw({:resolve_error, {:unknown_type, name}})
    end
  end

  defp resolve_type(other, _ns, _schema), do: other

  defp lookup_name(name, ns, schema) do
    found = Enum.find(enumerate_candidates(name, ns), &Map.has_key?(schema.types, &1))

    cond do
      found ->
        found

      String.contains?(name, ".") ->
        name

      true ->
        throw({:resolve_error, {:unknown_type, name}})
    end
  end

  # Reference lookup walks up the namespace hierarchy: for `foo.bar.X`
  # we try `foo.bar.X`, then `foo.X`, then `X`. Matches flatc semantics
  # so schemas like monster_test.fbs can refer to a type defined in
  # an outer namespace without re-qualifying it.
  defp enumerate_candidates(name, nil), do: [name]

  defp enumerate_candidates(name, ns) do
    parts = String.split(ns, ".")

    prefixed =
      for i <- length(parts)..1//-1 do
        Enum.take(parts, i) |> Enum.join(".") |> Kernel.<>("." <> name)
      end

    prefixed ++ [name]
  end

  defp assign_slots(%Table{fields: fields} = t) do
    ids = validate_field_ids(t, fields)

    {assigned, _} =
      Enum.map_reduce(fields, 4, fn f, slot ->
        explicit = Map.fetch(ids, f.name)

        # The schema's `(id: N)` always refers to a single voffset slot
        # (4 + N*2). For a union field that single slot is the *value*
        # slot — the matching discriminator lives at slot - 2. Without
        # an explicit id, a union still consumes two consecutive slots,
        # but the value slot is the higher of the two so the next field
        # starts cleanly at value + 2.
        slot_used =
          case explicit do
            {:ok, id} -> 4 + id * 2
            :error -> if union_field?(f), do: slot + 2, else: slot
          end

        next = slot_used + 2
        {%{f | vtable_slot: slot_used}, next}
      end)

    %{t | fields: assigned}
  end

  defp assign_slots(other), do: other

  defp union_field?(f),
    do: match?({:union, _}, f.type) or match?({:vector, {:union, _}}, f.type)

  # Explicit `(id: N)` validation, mirroring flatc:
  #
  #   * ids are non-negative integers (numeric strings are coerced);
  #   * either all fields carry an id or none do;
  #   * a union field consumes two ids — the explicit id names the value
  #     slot, the type slot is id - 1;
  #   * together the ids must cover 0..max consecutively, each exactly once.
  #
  # Returns a `field name => id` map (empty when ids are implicit).
  defp validate_field_ids(t, fields) do
    tagged =
      Enum.map(fields, fn f ->
        case Map.fetch(f.attributes, :id) do
          {:ok, raw} -> {f, coerce_field_id(t.name, f, raw)}
          :error -> {f, nil}
        end
      end)

    with_id = Enum.filter(tagged, fn {_, id} -> id != nil end)

    cond do
      with_id == [] ->
        %{}

      length(with_id) != length(fields) ->
        {f, _} = Enum.find(tagged, fn {_, id} -> id == nil end)
        throw({:resolve_error, {:missing_field_id, t.name, fname(f), f.line}})

      true ->
        check_id_coverage(t, with_id)
        Map.new(with_id, fn {f, id} -> {f.name, id} end)
    end
  end

  defp coerce_field_id(table, f, raw) do
    id =
      case raw do
        n when is_integer(n) ->
          n

        s when is_binary(s) ->
          # flatc parses attribute values as strings; `(id: "0")` is legal.
          case Integer.parse(s) do
            {n, ""} -> n
            _ -> throw({:resolve_error, {:bad_field_id, table, fname(f), raw, f.line}})
          end

        _ ->
          throw({:resolve_error, {:bad_field_id, table, fname(f), raw, f.line}})
      end

    if id < 0 or id > 65_535 do
      throw({:resolve_error, {:bad_field_id, table, fname(f), raw, f.line}})
    end

    id
  end

  defp check_id_coverage(t, with_id) do
    claimed =
      Enum.flat_map(with_id, fn {f, id} ->
        if union_field?(f) do
          if id < 1 do
            # flatc: "a union type effectively adds two fields ... its id
            # must be that of the second field".
            throw({:resolve_error, {:bad_union_field_id, t.name, fname(f), id, f.line}})
          end

          [{id - 1, f}, {id, f}]
        else
          [{id, f}]
        end
      end)

    Enum.reduce(Enum.sort_by(claimed, &elem(&1, 0)), 0, fn {id, f}, expected ->
      cond do
        id == expected ->
          expected + 1

        id < expected ->
          throw({:resolve_error, {:duplicate_field_id, t.name, fname(f), id, f.line}})

        true ->
          throw({:resolve_error, {:nonconsecutive_field_ids, t.name, fname(f), id, f.line}})
      end
    end)
  end

  defp compute_struct_layout(%SchemaStruct{} = s, schema) do
    {layout, total, max_align} =
      Enum.reduce(s.fields, {[], 0, 1}, fn f, {acc, pos, max_a} ->
        {size, align} = scalar_or_struct_size_align(f.type, schema)
        pad = pad_to(pos, align)
        new_pos = pos + pad + size
        entry = %{field: f, offset: pos + pad, size: size, align: align}
        {[entry | acc], new_pos, max(max_a, align)}
      end)

    forced_align = validate_force_align(s, max_align)
    final_align = max(max_align, forced_align)
    final_size = total + pad_to(total, final_align)

    %{s | layout: Enum.reverse(layout), size: final_size, align: final_align}
  end

  defp compute_struct_layout(other, _schema), do: other

  # flatc: force_align on a struct must be a power of two between the
  # struct's natural alignment and 32. (It accepts numeric strings, and
  # ignores the attribute entirely on tables and table fields.)
  defp validate_force_align(s, natural_align) do
    case Map.fetch(s.attributes, :force_align) do
      :error ->
        1

      {:ok, raw} ->
        n =
          case raw do
            n when is_integer(n) ->
              n

            str when is_binary(str) ->
              case Integer.parse(str) do
                {n, ""} -> n
                _ -> throw({:resolve_error, {:bad_force_align, s.name, raw, natural_align}})
              end

            _ ->
              throw({:resolve_error, {:bad_force_align, s.name, raw, natural_align}})
          end

        if power_of_two?(n) and n >= natural_align and n <= 32 do
          n
        else
          throw({:resolve_error, {:bad_force_align, s.name, n, natural_align}})
        end
    end
  end

  defp power_of_two?(n), do: n > 0 and Bitwise.band(n, n - 1) == 0

  defp scalar_or_struct_size_align({:scalar, kind}, _schema) do
    sz = Schema.scalar_size(kind)
    {sz, sz}
  end

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
    {elem_size, elem_align} = scalar_or_struct_size_align(inner, schema)
    {elem_size * n, elem_align}
  end

  defp pad_to(pos, align) do
    rem = rem(pos, align)
    if rem == 0, do: 0, else: align - rem
  end

  # Enum values -----------------------------------------------------------
  #
  # For regular enums the schema's `= N` is the variant value, and missing
  # values increment from the previous one. For `(bit_flags)` enums the
  # `= N` is interpreted as the *bit position* (so the actual value is
  # `1 <<< N`); missing values still increment the position by one.
  #
  # Validation mirrors flatc: every value (explicit or implicit) must fit
  # the underlying type, values must be unique, and bit_flags positions
  # must shift to a representable value. flatc 25.x does *not* require
  # ascending declaration order.

  defp compute_enum_values(variants, false, fqn, underlying) do
    {lo, hi} = scalar_int_range(underlying)

    {result, _next} =
      Enum.map_reduce(variants, 0, fn v, expected ->
        actual =
          case v.value do
            nil -> expected
            n -> n
          end

        if actual < lo or actual > hi do
          throw({:resolve_error, {:enum_value_out_of_range, fqn, v.name, actual, v.line}})
        end

        {{String.to_atom(v.name), actual}, actual + 1}
      end)

    check_unique_enum_values(result, variants, fqn)
    result
  end

  defp compute_enum_values(variants, true, fqn, underlying) do
    import Bitwise

    # The shifted value (not the bit position) must fit the underlying
    # type — flatc errors on `byte` shift 7 (128 > 127) but allows 6.
    {_lo, hi} = scalar_int_range(underlying)

    {result, _next} =
      Enum.map_reduce(variants, 0, fn v, expected_shift ->
        shift =
          case v.value do
            nil -> expected_shift
            n -> n
          end

        if shift < 0 or 1 <<< shift > hi do
          throw({:resolve_error, {:bit_flag_out_of_range, fqn, v.name, shift, v.line}})
        end

        value = 1 <<< shift
        {{String.to_atom(v.name), value}, shift + 1}
      end)

    check_unique_enum_values(result, variants, fqn)
    result
  end

  defp check_unique_enum_values(computed, variants, fqn) do
    lines = Map.new(variants, fn v -> {String.to_atom(v.name), v.line} end)

    Enum.reduce(computed, %{}, fn {name, value}, seen ->
      case Map.fetch(seen, value) do
        {:ok, _first} ->
          throw(
            {:resolve_error,
             {:duplicate_enum_value, fqn, Atom.to_string(name), value, Map.get(lines, name)}}
          )

        :error ->
          Map.put(seen, value, name)
      end
    end)
  end

  # Misc helpers ----------------------------------------------------------

  defp fname(%Field{name: name}), do: Atom.to_string(name)

  defp qualify(name, nil), do: name

  defp qualify(name, ns) do
    if String.contains?(name, "."), do: name, else: ns <> "." <> name
  end

  defp normalize_attrs(pairs) do
    Map.new(pairs, fn {k, v} ->
      key = String.to_atom(k)
      value = unwrap_literal(v)
      {key, value}
    end)
  end

  defp unwrap_literal(nil), do: true
  defp unwrap_literal({:int, n}), do: n
  defp unwrap_literal({:float, f}), do: f
  defp unwrap_literal({:string, s}), do: s
  defp unwrap_literal({:bool, b}), do: b
  defp unwrap_literal({:ident, n}), do: n
  defp unwrap_literal(:null), do: nil
  defp unwrap_literal(other), do: other
end
