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
        load_includes(decls, Path.dirname(path), include_paths, seen2, acc2)
      end
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, src} -> {:ok, src}
      {:error, reason} -> {:error, {:cannot_read, path, reason}}
    end
  end

  defp load_includes([], _base, _ip, seen, acc), do: {:ok, seen, acc}

  defp load_includes([{:include, rel, _line} | rest], base, include_paths, seen, acc) do
    case resolve_include(rel, base, include_paths) do
      {:ok, full} ->
        case load_all(full, include_paths, seen, acc) do
          {:ok, seen2, acc2} ->
            load_includes(rest, base, include_paths, seen2, acc2)

          err ->
            err
        end

      :not_found ->
        {:error, {:cannot_read, rel, :enoent}}
    end
  end

  defp load_includes([_ | rest], base, include_paths, seen, acc),
    do: load_includes(rest, base, include_paths, seen, acc)

  # First try the including file's own directory (standard flatc behaviour),
  # then each `-I` search path in order.
  defp resolve_include(rel, base, include_paths) do
    candidates = [
      Path.expand(Path.join(base, rel)) | Enum.map(include_paths, &Path.join(&1, rel))
    ]

    case Enum.find(candidates, &File.regular?/1) do
      nil -> :not_found
      path -> {:ok, path}
    end
  end

  # Normalize per-file declarations into a Schema --------------------------

  defp normalize(files) do
    schema = %Schema{source_files: Enum.map(files, &elem(&1, 0))}
    schema = Enum.reduce(files, schema, &collect_decls/2)
    {:ok, finalize(schema)}
  catch
    {:resolve_error, reason} -> {:error, reason}
  end

  defp collect_decls({_file, decls}, schema) do
    state = %{namespace: nil, schema: schema}
    final = Enum.reduce(decls, state, &add_decl/2)
    final.schema
  end

  defp add_decl({:namespace, name, _line}, state),
    do: %{state | namespace: name}

  defp add_decl({:include, _path, _line}, state), do: state

  defp add_decl({:root_type, name, _line}, state) do
    fqn = qualify(name, state.namespace)
    %{state | schema: %{state.schema | root_type: fqn}}
  end

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

    table = %Table{
      name: fqn,
      namespace: state.namespace,
      short_name: body.name,
      fields:
        Enum.map(body.fields, fn f ->
          %Field{
            name: String.to_atom(f.name),
            type: f.type,
            default: f.default,
            attributes: normalize_attrs(f.attributes),
            docs: f.docs
          }
        end),
      attributes: normalize_attrs(body.attributes),
      docs: body.docs
    }

    %{state | schema: put_type(state.schema, fqn, table)}
  end

  defp add_decl({:struct, body}, state) do
    fqn = qualify(body.name, state.namespace)

    struct_rec = %SchemaStruct{
      name: fqn,
      namespace: state.namespace,
      short_name: body.name,
      fields:
        Enum.map(body.fields, fn f ->
          %Field{
            name: String.to_atom(f.name),
            type: f.type,
            default: f.default,
            attributes: normalize_attrs(f.attributes),
            docs: f.docs
          }
        end),
      attributes: normalize_attrs(body.attributes),
      docs: body.docs
    }

    %{state | schema: put_type(state.schema, fqn, struct_rec)}
  end

  defp add_decl({:union, body}, state) do
    fqn = qualify(body.name, state.namespace)

    variants =
      body.variants
      |> Enum.with_index(1)
      |> Enum.map(fn {v, disc} ->
        {String.to_atom(v.name), v.type, disc}
      end)

    union = %Union{
      name: fqn,
      namespace: state.namespace,
      short_name: body.name,
      variants: variants,
      attributes: normalize_attrs(body.attributes),
      docs: body.docs
    }

    %{state | schema: put_type(state.schema, fqn, union)}
  end

  defp add_decl({:enum, body}, state) do
    fqn = qualify(body.name, state.namespace)

    variants = compute_enum_values(body.variants)

    underlying =
      case body.underlying_type do
        :string -> throw({:resolve_error, {:bad_enum_underlying, fqn}})
        other -> other
      end

    enum = %SchemaEnum{
      name: fqn,
      namespace: state.namespace,
      short_name: body.name,
      underlying_type: underlying,
      variants: variants,
      attributes: normalize_attrs(body.attributes),
      docs: body.docs,
      bit_flags?: Map.has_key?(normalize_attrs(body.attributes), :bit_flags)
    }

    %{state | schema: put_type(state.schema, fqn, enum)}
  end

  defp put_type(schema, fqn, rec) do
    if Map.has_key?(schema.types, fqn) do
      throw({:resolve_error, {:duplicate_type, fqn}})
    end

    %{schema | types: Map.put(schema.types, fqn, rec)}
  end

  # Finalization: resolve forward refs and compute layouts -----------------

  defp finalize(schema) do
    schema = %{
      schema
      | types: Map.new(schema.types, fn {k, v} -> {k, resolve_refs(v, schema)} end)
    }

    schema = %{schema | types: Map.new(schema.types, fn {k, v} -> {k, assign_slots(v)} end)}

    # Struct layouts must be computed in dependency order — a struct
    # containing another struct needs the inner one's `size`/`align` to
    # be set first.
    schema = layout_all_structs(schema)

    if schema.root_type && !Map.has_key?(schema.types, schema.root_type) do
      throw({:resolve_error, {:unknown_root_type, schema.root_type}})
    end

    schema
  end

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
    {_, sorted} =
      Enum.reduce(nodes, {MapSet.new(), []}, fn node, {seen, acc} ->
        visit(node, graph, seen, acc, MapSet.new())
      end)

    Enum.reverse(sorted)
  end

  defp visit(node, graph, seen, acc, stack) do
    cond do
      MapSet.member?(stack, node) ->
        throw({:resolve_error, {:struct_cycle, node}})

      MapSet.member?(seen, node) ->
        {seen, acc}

      true ->
        stack = MapSet.put(stack, node)
        deps = Map.get(graph, node, [])

        {seen, acc} =
          Enum.reduce(deps, {seen, acc}, fn d, {s, a} ->
            if Map.has_key?(graph, d), do: visit(d, graph, s, a, stack), else: {s, a}
          end)

        {MapSet.put(seen, node), [node | acc]}
    end
  end

  defp resolve_refs(%Table{} = t, schema) do
    %{t | fields: Enum.map(t.fields, &resolve_field_ref(&1, t.namespace, schema))}
  end

  defp resolve_refs(%SchemaStruct{} = s, schema) do
    fields = Enum.map(s.fields, &resolve_field_ref(&1, s.namespace, schema))

    Enum.each(fields, fn f ->
      case f.type do
        {:scalar, _} -> :ok
        {:enum, _} -> :ok
        {:struct, _} -> :ok
        {:array, inner, _} -> check_array_inner(s.name, f.name, inner)
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

  defp check_array_inner(_, _, {:scalar, _}), do: :ok
  defp check_array_inner(_, _, {:enum, _}), do: :ok
  defp check_array_inner(_, _, {:struct, _}), do: :ok

  defp check_array_inner(struct_name, field_name, other),
    do: throw({:resolve_error, {:bad_array_element_type, struct_name, field_name, other}})

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
    {assigned, _} =
      Enum.map_reduce(fields, 4, fn f, slot ->
        explicit = Map.get(f.attributes, :id)
        slot_used = if is_integer(explicit), do: 4 + explicit * 2, else: slot
        step = slot_step(f.type)
        {%{f | vtable_slot: slot_used}, slot_used + step}
      end)

    %{t | fields: assigned}
  end

  defp assign_slots(other), do: other

  # Union fields (and vectors of unions) consume two adjacent vtable
  # slots — the u8 discriminator at slot N, the uoffset value at N+2 —
  # so the next field starts at N+4.
  defp slot_step({:union, _}), do: 4
  defp slot_step({:vector, {:union, _}}), do: 4
  defp slot_step(_), do: 2

  defp compute_struct_layout(%SchemaStruct{} = s, schema) do
    {layout, total, max_align} =
      Enum.reduce(s.fields, {[], 0, 1}, fn f, {acc, pos, max_a} ->
        {size, align} = scalar_or_struct_size_align(f.type, schema)
        pad = pad_to(pos, align)
        new_pos = pos + pad + size
        entry = %{field: f, offset: pos + pad, size: size, align: align}
        {[entry | acc], new_pos, max(max_a, align)}
      end)

    forced_align =
      case Map.get(s.attributes, :force_align) do
        n when is_integer(n) -> n
        _ -> 1
      end

    final_align = max(max_align, forced_align)
    final_size = total + pad_to(total, final_align)

    %{s | layout: Enum.reverse(layout), size: final_size, align: final_align}
  end

  defp compute_struct_layout(other, _schema), do: other

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

  defp compute_enum_values(variants) do
    {result, _next} =
      Enum.map_reduce(variants, 0, fn v, expected ->
        actual =
          case v.value do
            nil -> expected
            n -> n
          end

        {{String.to_atom(v.name), actual}, actual + 1}
      end)

    result
  end

  # Misc helpers ----------------------------------------------------------

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
