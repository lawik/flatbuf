defmodule Flatbuf.Test.ValueGen do
  @moduledoc """
  IR-driven StreamData generators and the matching "expected decode"
  normalizer for property-based round-trip tests (SPEC §10.4).

  `root_gen/3` takes a resolved `%Flatbuf.Schema{}` plus a root-table
  FQN and returns a generator of value maps that are *valid inputs* for
  the generated `encode/1` — every scalar respects its wire range
  (`Wire.check_scalar!/3` would reject anything else), enums are
  variant atoms (lists of atoms for `bit_flags`), unions are
  `{variant_atom, value}` tuples, and `= null` optionals can be absent,
  explicitly `nil`, or a real value (including the type's zero).

  `expected/3` computes, from the same input map, the exact struct
  `decode(encode(value))` must return. It mirrors the decoder's
  semantics:

    * absent fields decode to their schema default (`nil` for
      optionals, strings, tables, structs, and unions; `[]` for
      vectors and `bit_flags`),
    * a scalar written at exactly its default is omitted from the wire,
      so it decodes back as the default literal,
    * `f32` values come back widened from 4-byte precision — generated
      `f32` values are pre-rounded through the f32 bit pattern so
      round-trip equality is exact,
    * `bit_flags` lists decode as the declared-order decomposition of
      the OR'd value (input order and duplicates are normalized away),
    * fixed-size struct arrays are zero-padded to their declared
      length.

  Float policy: `:nan`, `:infinity`, and `:neg_infinity` (this
  library's atoms for the IEEE 754 specials) are generated at low
  frequency for *table* float fields — they decode back to the same
  atoms, so equality is well-defined without any NaN /= NaN caveat.
  They are never generated inside structs: struct codegen writes raw
  `::little-float-N` binary segments, which cannot represent the
  specials. The `specials: false` option turns them off entirely for
  oracle directions where flatc's JSON layer is in the loop.
  """

  alias Flatbuf.Codegen.Naming
  alias Flatbuf.Schema
  alias Flatbuf.Schema.Enum, as: SchemaEnum
  alias Flatbuf.Schema.Field
  alias Flatbuf.Schema.Struct, as: SchemaStruct
  alias Flatbuf.Schema.Table
  alias Flatbuf.Schema.Union

  import StreamData

  @int_ranges %{
    i8: {-0x80, 0x7F},
    u8: {0, 0xFF},
    i16: {-0x8000, 0x7FFF},
    u16: {0, 0xFFFF},
    i32: {-0x80000000, 0x7FFFFFFF},
    u32: {0, 0xFFFFFFFF},
    i64: {-0x8000000000000000, 0x7FFFFFFFFFFFFFFF},
    u64: {0, 0xFFFFFFFFFFFFFFFF}
  }

  @f32_max 3.4028234663852886e38
  @f64_max 1.7976931348623157e308

  # The sentinel a generated field uses for "leave the key out of the
  # map entirely" — distinct from an explicit nil value.
  @absent :__flatbuf_absent__

  # ---------------------------------------------------------------------
  # Generators
  # ---------------------------------------------------------------------

  @doc """
  Generator of valid `encode/1` input maps for the table at `fqn`.

  Options:

    * `:union_vector_nils` — allow `nil` (NONE) elements inside vectors
      of unions (default `true`; flatc's JSON generator rejects them,
      so oracle directions disable this).
    * `:specials` — allow `:nan` / `:infinity` / `:neg_infinity` in
      table float fields (default `true`).
    * `:max_vector` — maximum generated vector length (default 4).
  """
  def root_gen(%Schema{} = schema, fqn, opts \\ []) when is_binary(fqn) do
    opts = %{
      union_vector_nils: Keyword.get(opts, :union_vector_nils, true),
      specials: Keyword.get(opts, :specials, true),
      max_vector: Keyword.get(opts, :max_vector, 4)
    }

    %Table{} = t = Schema.fetch(schema, fqn)
    table_gen(schema, t, opts)
  end

  defp table_gen(schema, %Table{} = t, opts) do
    t.fields
    |> Map.new(fn f -> {f.name, field_gen(schema, f, opts)} end)
    |> fixed_map()
    |> map(fn m -> Map.reject(m, fn {_k, v} -> v == @absent end) end)
  end

  # Each table field is present most of the time, sometimes absent
  # (key missing), and — where the encoder accepts it — sometimes an
  # explicit nil.
  defp field_gen(schema, %Field{} = f, opts) do
    gens = [{5, type_gen(schema, f.type, opts)}, {1, constant(@absent)}]
    gens = if nilable_field?(f), do: [{1, constant(nil)} | gens], else: gens
    frequency(gens)
  end

  # Explicit nil is a valid encode input for `= null` optionals (omit
  # the slot) and for every offset-typed field. It is *invalid* for
  # plain scalars and enums (`check_scalar!` rejects it), so those only
  # get the absent-key form.
  defp nilable_field?(%Field{default: :null}), do: true
  defp nilable_field?(%Field{type: :string}), do: true
  defp nilable_field?(%Field{type: {:vector, _}}), do: true
  defp nilable_field?(%Field{type: {:table, _}}), do: true
  defp nilable_field?(%Field{type: {:struct, _}}), do: true
  defp nilable_field?(%Field{type: {:union, _}}), do: true
  defp nilable_field?(_), do: false

  defp type_gen(_schema, {:scalar, :bool}, _opts), do: boolean()

  defp type_gen(_schema, {:scalar, kind}, _opts) when is_map_key(@int_ranges, kind) do
    {lo, hi} = Map.fetch!(@int_ranges, kind)
    frequency([{5, integer(lo..hi)}, {1, member_of([lo, hi, 0])}])
  end

  defp type_gen(_schema, {:scalar, kind}, opts) when kind in [:f32, :f64],
    do: float_gen(kind, opts)

  defp type_gen(_schema, :string, _opts), do: string_gen()

  defp type_gen(schema, {:enum, fqn}, _opts) do
    case Schema.fetch(schema, fqn) do
      %SchemaEnum{bit_flags?: true, variants: vs} ->
        # Duplicates are fine: the encoder ORs them away, and
        # `expected/3` models the decode as the decomposition of the
        # OR'd value. (`uniq_list_of` would give up on such a small
        # member space.)
        list_of(member_of(variant_atoms(vs)), max_length: length(vs))

      %SchemaEnum{variants: vs} ->
        member_of(variant_atoms(vs))
    end
  end

  defp type_gen(schema, {:vector, {:union, fqn}}, opts) do
    elem = union_gen(schema, fqn, opts)

    elem =
      if opts.union_vector_nils,
        do: frequency([{6, elem}, {1, constant(nil)}]),
        else: elem

    list_of(elem, max_length: opts.max_vector)
  end

  defp type_gen(schema, {:vector, inner}, opts),
    do: list_of(type_gen(schema, inner, opts), max_length: opts.max_vector)

  defp type_gen(schema, {:array, inner, n}, opts),
    do: list_of(type_gen(schema, inner, opts), length: n)

  defp type_gen(schema, {:struct, fqn}, opts) do
    %SchemaStruct{fields: fields} = Schema.fetch(schema, fqn)
    # Struct fields are always generated: an absent enum or sub-struct
    # member would crash the struct encoder, and IEEE specials can't be
    # written through the raw binary float segments structs use.
    opts = %{opts | specials: false}

    fields
    |> Map.new(fn f -> {f.name, type_gen(schema, f.type, opts)} end)
    |> fixed_map()
  end

  defp type_gen(schema, {:table, fqn}, opts),
    do: table_gen(schema, Schema.fetch(schema, fqn), opts)

  defp type_gen(schema, {:union, fqn}, opts), do: union_gen(schema, fqn, opts)

  defp union_gen(schema, fqn, opts) do
    %Union{variants: vs} = Schema.fetch(schema, fqn)

    one_of(
      for {name, vtype, _disc} <- vs do
        tuple({constant(name), union_variant_gen(schema, vtype, opts)})
      end
    )
  end

  defp union_variant_gen(schema, {:table, fqn}, opts), do: type_gen(schema, {:table, fqn}, opts)

  defp union_variant_gen(schema, {:struct, fqn}, opts),
    do: type_gen(schema, {:struct, fqn}, opts)

  defp union_variant_gen(_schema, :string, _opts), do: string_gen()

  defp float_gen(kind, opts) do
    base =
      case kind do
        # Without specials, clamp before rounding so an f64 magnitude
        # beyond the f32 range can't saturate into `:infinity`.
        :f32 when opts.specials -> map(float(), &f32_round/1)
        :f32 -> map(float(), fn f -> f |> f32_clamp() |> f32_round() end)
        :f64 -> float()
      end

    boundaries =
      case kind do
        :f32 -> member_of([0.0, -0.0, 1.0, -1.0, @f32_max, -@f32_max, 1.1754943508222875e-38])
        :f64 -> member_of([0.0, -0.0, 1.0, -1.0, @f64_max, -@f64_max, 5.0e-324])
      end

    if opts.specials do
      frequency([
        {8, base},
        {1, boundaries},
        {1, member_of([:nan, :infinity, :neg_infinity])}
      ])
    else
      frequency([{8, base}, {1, boundaries}])
    end
  end

  defp string_gen do
    frequency([
      {4, string(:printable, max_length: 12)},
      {2, string(:utf8, max_length: 12)},
      {1, constant("")}
    ])
  end

  defp variant_atoms(variants), do: Enum.map(variants, fn {name, _} -> name end)

  # ---------------------------------------------------------------------
  # Expected decode
  # ---------------------------------------------------------------------

  @doc """
  The exact struct `decode(encode(value))` must return for the table
  at `fqn`, given an input map produced by `root_gen/3`.
  """
  def expected(%Schema{} = schema, fqn, value) when is_binary(fqn) do
    expected_table(schema, Schema.fetch(schema, fqn), value)
  end

  defp expected_table(schema, %Table{} = t, value) do
    fields =
      Map.new(t.fields, fn f ->
        {f.name, expected_field(schema, f, Map.get(value, f.name, @absent))}
      end)

    struct(module_for(t.name), fields)
  end

  defp expected_field(schema, %Field{type: {:scalar, kind}} = f, input) do
    optional? = f.default == :null
    default = decoded_default(schema, f)

    case input do
      i when i in [@absent, nil] ->
        default

      v ->
        # A value equal to the (non-optional) default is omitted from
        # the wire by `Wire.add_field_scalar/5`, so the decoder hands
        # back the default literal. Optionals always write the slot.
        if not optional? and v == default, do: default, else: norm_scalar(kind, v)
    end
  end

  defp expected_field(schema, %Field{type: {:enum, fqn}} = f, input) do
    enum = Schema.fetch(schema, fqn)

    case {input, enum} do
      {i, _} when i in [@absent, nil] -> decoded_default(schema, f)
      {list, %SchemaEnum{bit_flags?: true}} -> decompose_flags(enum, list)
      {atom, _} -> atom
    end
  end

  defp expected_field(_schema, %Field{type: :string}, input) do
    case input do
      i when i in [@absent, nil] -> nil
      s -> s
    end
  end

  defp expected_field(schema, %Field{type: {:vector, inner}}, input) do
    case input do
      i when i in [@absent, nil] -> []
      list -> Enum.map(list, &expected_elem(schema, inner, &1))
    end
  end

  defp expected_field(schema, %Field{type: {:table, fqn}}, input) do
    case input do
      i when i in [@absent, nil] -> nil
      v -> expected_table(schema, Schema.fetch(schema, fqn), v)
    end
  end

  defp expected_field(schema, %Field{type: {:struct, fqn}}, input) do
    case input do
      i when i in [@absent, nil] -> nil
      v -> expected_struct(schema, fqn, v)
    end
  end

  defp expected_field(schema, %Field{type: {:union, fqn}}, input) do
    case input do
      i when i in [@absent, nil] -> nil
      pair -> expected_union(schema, fqn, pair)
    end
  end

  defp expected_elem(_schema, {:union, _fqn}, nil), do: nil
  defp expected_elem(schema, {:union, fqn}, pair), do: expected_union(schema, fqn, pair)
  defp expected_elem(_schema, {:scalar, kind}, v), do: norm_scalar(kind, v)
  defp expected_elem(_schema, :string, v), do: v
  defp expected_elem(_schema, {:enum, _fqn}, v), do: v
  defp expected_elem(schema, {:struct, fqn}, v), do: expected_struct(schema, fqn, v)

  defp expected_elem(schema, {:table, fqn}, v),
    do: expected_table(schema, Schema.fetch(schema, fqn), v)

  defp expected_union(schema, fqn, {name, value}) do
    %Union{variants: vs} = Schema.fetch(schema, fqn)
    {^name, vtype, _disc} = Enum.find(vs, fn {n, _, _} -> n == name end)

    expected_value =
      case vtype do
        {:table, tfqn} -> expected_table(schema, Schema.fetch(schema, tfqn), value)
        {:struct, sfqn} -> expected_struct(schema, sfqn, value)
        :string -> value
      end

    {name, expected_value}
  end

  defp expected_struct(schema, fqn, value) do
    %SchemaStruct{fields: fields, name: name} = Schema.fetch(schema, fqn)

    decoded =
      Map.new(fields, fn f ->
        {f.name, expected_struct_field(schema, f.type, Map.get(value, f.name, @absent))}
      end)

    struct(module_for(name), decoded)
  end

  defp expected_struct_field(_schema, {:scalar, kind}, @absent), do: Schema.scalar_default(kind)
  defp expected_struct_field(_schema, {:scalar, kind}, v), do: norm_scalar(kind, v)
  defp expected_struct_field(_schema, {:enum, _fqn}, v), do: v
  defp expected_struct_field(schema, {:struct, fqn}, v), do: expected_struct(schema, fqn, v)

  defp expected_struct_field(schema, {:array, inner, n}, input) do
    list = if input == @absent, do: [], else: input
    pad = List.duplicate(array_elem_default(schema, inner), max(0, n - length(list)))

    (list ++ pad)
    |> Enum.take(n)
    |> Enum.map(&expected_array_elem(schema, inner, &1))
  end

  defp expected_array_elem(_schema, {:scalar, kind}, v), do: norm_scalar(kind, v)
  defp expected_array_elem(_schema, {:enum, _fqn}, v), do: v
  defp expected_array_elem(schema, {:struct, fqn}, v), do: expected_struct(schema, fqn, v)

  # Mirrors `Flatbuf.Codegen.Struct.inner_default/2`: short fixed-size
  # arrays are zero-padded by the encoder.
  defp array_elem_default(_schema, {:scalar, kind}), do: Schema.scalar_default(kind)

  defp array_elem_default(schema, {:enum, fqn}) do
    %SchemaEnum{variants: [{first, _} | _]} = Schema.fetch(schema, fqn)
    first
  end

  defp array_elem_default(_schema, {:struct, _fqn}), do: %{}

  # ---------------------------------------------------------------------
  # Decoder defaults — mirrors Flatbuf.Codegen.Table.default_value/2
  # ---------------------------------------------------------------------

  defp decoded_default(schema, %Field{} = f) do
    case {f.type, f.default} do
      {{:scalar, kind}, nil} -> Schema.scalar_default(kind)
      {{:scalar, _}, :null} -> nil
      {{:scalar, _}, {:int, n}} -> n
      {{:scalar, _}, {:float, x}} -> x
      {{:scalar, _}, {:bool, b}} -> b
      {{:enum, fqn}, nil} -> default_enum_value(schema, fqn)
      {{:enum, _}, :null} -> nil
      {{:enum, fqn}, {:ident, name}} -> explicit_enum_default(schema, fqn, name)
      {:string, _} -> nil
      {{:vector, _}, _} -> []
      {{:table, _}, _} -> nil
      {{:struct, _}, _} -> nil
      {{:union, _}, _} -> nil
    end
  end

  defp default_enum_value(schema, fqn) do
    case Schema.fetch(schema, fqn) do
      %SchemaEnum{bit_flags?: true} -> []
      %SchemaEnum{variants: [{first, _} | _]} -> first
    end
  end

  defp explicit_enum_default(schema, fqn, name) do
    %SchemaEnum{variants: vs, bit_flags?: bit_flags?} = Schema.fetch(schema, fqn)
    {atom, _} = Enum.find(vs, fn {n, _} -> Atom.to_string(n) == name end)
    if bit_flags?, do: [atom], else: atom
  end

  # bit_flags decode as the declared-order decomposition of the OR'd
  # integer — input order and duplicates don't survive the round trip.
  defp decompose_flags(%SchemaEnum{variants: vs}, list) do
    import Bitwise

    combined =
      Enum.reduce(list, 0, fn atom, acc ->
        {_, v} = Enum.find(vs, fn {n, _} -> n == atom end)
        bor(acc, v)
      end)

    for {atom, v} <- vs, v != 0 and band(combined, v) == v, do: atom
  end

  # ---------------------------------------------------------------------
  # Misc
  # ---------------------------------------------------------------------

  @doc """
  Round a float through the f32 bit pattern (decode widens from f32).

  Magnitudes beyond the f32 range saturate to infinity bits in Elixir's
  float-32 binary construction — exactly what `push_f32/2` writes —
  and the reader spells those `:infinity` / `:neg_infinity`.
  """
  def f32_round(f) when is_float(f) do
    case <<f::little-float-32>> do
      <<r::little-float-32>> -> r
      <<0x7F800000::little-32>> -> :infinity
      <<0xFF800000::little-32>> -> :neg_infinity
    end
  end

  def f32_round(special) when is_atom(special), do: special

  defp f32_clamp(f) when f > @f32_max, do: @f32_max
  defp f32_clamp(f) when f < -@f32_max, do: -@f32_max
  defp f32_clamp(f), do: f

  defp norm_scalar(:f32, v), do: f32_round(v)
  defp norm_scalar(_kind, v), do: v

  defp module_for(fqn), do: Module.concat([Naming.module_name(fqn, nil)])
end
