defmodule Flatbuf.PropertyRoundtripTest do
  @moduledoc """
  Property-based round-trip tests: StreamData generators
  driven by the schema IR produce arbitrary valid values, which are
  then pushed through every direction we can check.

  Properties, over three feature-rich inline schemas (one kitchen-sink,
  one union-heavy, one struct/array-heavy):

  1. `encode |> decode` returns exactly the value
     `Flatbuf.Test.ValueGen.expected/3` predicts (defaults filled in
     for absent fields, f32 widening, bit_flags normalization, …).
  2. `encode |> verify` returns `:ok`.
  3. `encode |> flatc --json` succeeds and agrees with our own
     `__to_json_map__/1` of the decoded value (via a deep compare that
     tolerates flatc's float-printing precision — see below). Runs
     with fewer cases — each one shells out — and is gated on flatc
     availability like `Flatbuf.EncodeOracleTest`.
  4. `flatc --binary` from our JSON rendering of the same value, then
     our `decode/1`, must agree with the expected value's JSON shape.

  Deliberate scope choices, documented per the suite's conventions:

    * No `(key)` attributes in the property schemas — the encoder
      sorts keyed vectors on the wire, which would force the expected
      model to re-implement that reordering. The dedicated
      `encode_oracle` "keys" fixture pins that behavior instead.
    * NaN/infinity: generated as `:nan` / `:infinity` /
      `:neg_infinity` atoms (low frequency) for table float fields.
      They decode back to the same atoms, so property 1 compares them
      with plain `==` — no NaN-inequality caveat. Direction 4 disables
      them (flatc's JSON parser is not a reliable consumer of the
      quoted spellings); direction 3 keeps them, since flatc emits
      `nan`/`inf` tokens we normalize to the same strings.
    * Vectors of unions include occasional `nil` (NONE) elements in
      properties 1–2; flatc's JSON text generator rejects NONE
      elements (see `Flatbuf.EncodeOracleTest`), so the oracle-backed
      directions 3–4 generate without them.
    * The union-heavy schema keeps its two union vectors in *separate*
      tables (`Holder.many` and `Cache.backup`): flatc's JSON parser
      mis-types the elements of a second union vector in the same
      table (probed against v25.12.19 — `{"a_type":["Sword"],"a":[…],
      "b_type":["Pt"],"b":[{"x":…}]}` fails with "unknown field: x"),
      which would falsely fail direction 4.
    * flatc prints a present-but-empty vector as `[]` while our
      `__to_json_map__/1` canonicalizes empty vectors away, so both
      sides pass through `drop_empty_lists/1` before the comparison —
      a JSON-shape nuance, not a wire one (property 1 pins that empty
      vectors round-trip as `[]`).
    * Direction 3 compares floats with a print-precision tolerance
      instead of `deep_diff/2`'s f32-bit rule: flatc renders floats in
      fixed notation (6 decimal places for `float`, 12 for `double`),
      so e.g. an f32 of `0.123456789` comes back as `0.123457` and
      anything below ~5.0e-7 prints as `0.0`. Exactness for those
      values is already pinned by properties 1 and 4.
  """

  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Flatbuf.Codegen.Naming
  alias Flatbuf.Schema.Resolver
  alias Flatbuf.Test.CodegenCompiler
  alias Flatbuf.Test.Flatc
  alias Flatbuf.Test.ValueGen

  # Modest run counts keep the file fast inside the full suite; bump
  # locally when hunting for something.
  @decode_runs 75
  @verify_runs 40
  @flatc_read_runs 12
  @flatc_encode_runs 8

  @sink_schema """
  namespace PropSink;

  enum Color : byte { Red = 1, Green = 2, Blue = 8 }

  enum Flags : ushort (bit_flags) { A, B, C, D }

  struct Vec3 {
    x: float;
    y: float;
    z: float;
  }

  table Item {
    label: string;
    qty: uint;
    active: bool = true;
  }

  table Everything {
    flag: bool;
    on: bool = true;
    i8v: byte;
    u8v: ubyte;
    i16v: short;
    u16v: ushort;
    i32v: int = 7;
    u32v: uint;
    i64v: long;
    u64v: ulong;
    f32v: float;
    f32d: float = 1.5;
    f64v: double;
    f64d: double = 2.5;
    opt_i: int = null;
    opt_b: bool = null;
    opt_f: float = null;
    name: string;
    bytes: [ubyte];
    nums: [int];
    longs: [long];
    bools: [bool];
    floats: [float];
    doubles: [double];
    strs: [string];
    color: Color = Green;
    colors: [Color];
    flags: Flags;
    pos: Vec3;
    positions: [Vec3];
    item: Item;
    items: [Item];
  }

  root_type Everything;
  """

  @union_schema """
  namespace PropUnion;

  struct Pt {
    x: short;
    y: short;
  }

  table Sword {
    dmg: short;
    name: string;
  }

  table Shield {
    hp: int;
    tags: [string];
  }

  union Gear { Sword, Shield, Pt, Words: string }

  table Cache {
    backup: [Gear];
  }

  table Holder {
    label: string;
    g1: Gear;
    g2: Gear;
    many: [Gear];
    cache: Cache;
  }

  root_type Holder;
  """

  @struct_schema """
  namespace PropStruct;

  enum Axis : ubyte { X, Y, Z }

  struct Inner {
    a: int;
    b: byte;
    on: bool;
  }

  struct Mid {
    id: ushort;
    ax: Axis;
    ds: [double : 2];
    inners: [Inner : 2];
    axs: [Axis : 3];
  }

  struct Outer {
    tag: ulong;
    mids: [Mid : 2];
    d: double;
    bs: [byte : 5];
  }

  table Holder {
    label: string;
    o: Outer;
    inner: Inner;
    os: [Outer];
    mid: Mid;
  }

  root_type Holder;
  """

  @schema_sources [
    sink: {"PropSink.Everything", @sink_schema},
    unions: {"PropUnion.Holder", @union_schema},
    structs: {"PropStruct.Holder", @struct_schema}
  ]

  # Resolve + compile every schema at test-module compile time and keep
  # the IR around: the generators and the expected-decode model are
  # both driven by the resolved %Flatbuf.Schema{}.
  @schemas (for {name, {fqn, source}} <- @schema_sources, into: %{} do
              {:ok, schema} = Resolver.resolve_source(source)

              CodegenCompiler.compile_schema!(schema,
                wire_module:
                  Module.concat([
                    Flatbuf.PropertyRoundtripTest.Wire,
                    Macro.camelize(Atom.to_string(name))
                  ])
              )

              {name, {schema, fqn, Module.concat([Naming.module_name(fqn, nil)])}}
            end)

  @flatc_ok (try do
               _ = Flatc.ensure_available!()
               true
             rescue
               _ -> false
             end)

  # ---------------------------------------------------------------------
  # 1 + 2: pure Elixir round trips — no flatc, no corpus required
  # ---------------------------------------------------------------------

  describe "encode → decode == expected" do
    property "kitchen-sink schema" do
      assert_decode_roundtrip(:sink)
    end

    property "union-heavy schema" do
      assert_decode_roundtrip(:unions)
    end

    property "struct/array-heavy schema" do
      assert_decode_roundtrip(:structs)
    end
  end

  describe "encode → verify == :ok" do
    property "kitchen-sink schema" do
      assert_encoded_verifies(:sink)
    end

    property "union-heavy schema" do
      assert_encoded_verifies(:unions)
    end

    property "struct/array-heavy schema" do
      assert_encoded_verifies(:structs)
    end
  end

  # ---------------------------------------------------------------------
  # 3 + 4: flatc oracle directions — gated on flatc availability
  # ---------------------------------------------------------------------

  if @flatc_ok do
    setup_all do
      _ = Flatc.ensure_available!()

      dir =
        Path.join(
          System.tmp_dir!(),
          "flatbuf_prop_schemas_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(dir)

      paths =
        Map.new(@schema_sources, fn {name, {_fqn, source}} ->
          path = Path.join(dir, "#{name}.fbs")
          File.write!(path, source)
          {name, path}
        end)

      on_exit(fn -> File.rm_rf!(dir) end)

      {:ok, schema_paths: paths}
    end

    describe "encode → flatc --json agrees" do
      property "kitchen-sink schema", %{schema_paths: paths} do
        assert_flatc_reads(:sink, paths)
      end

      property "union-heavy schema", %{schema_paths: paths} do
        assert_flatc_reads(:unions, paths)
      end

      property "struct/array-heavy schema", %{schema_paths: paths} do
        assert_flatc_reads(:structs, paths)
      end
    end

    describe "flatc --binary → our decode agrees" do
      property "kitchen-sink schema", %{schema_paths: paths} do
        assert_decode_of_flatc_binary(:sink, paths)
      end

      property "union-heavy schema", %{schema_paths: paths} do
        assert_decode_of_flatc_binary(:unions, paths)
      end

      property "struct/array-heavy schema", %{schema_paths: paths} do
        assert_decode_of_flatc_binary(:structs, paths)
      end
    end

    defp assert_flatc_reads(name, paths) do
      {schema, fqn, mod} = schema_info(name)

      check all(
              value <- ValueGen.root_gen(schema, fqn, union_vector_nils: false),
              max_runs: @flatc_read_runs
            ) do
        assert {:ok, bin} = mod.encode(value)

        case Flatc.binary_to_json(Map.fetch!(paths, name), bin) do
          {:ok, flatc_json} ->
            {:ok, decoded} = mod.decode(bin)
            ours = mod.__to_json_map__(decoded)

            case print_tolerant_diff(
                   drop_empty_lists(flatc_json),
                   drop_empty_lists(ours),
                   []
                 ) do
              :ok ->
                :ok

              diff ->
                flunk("""
                schema #{name}: flatc read our buffer differently than we do.

                  first divergence: #{inspect(diff)}

                  flatc: #{inspect(flatc_json, pretty: true)}
                  ours:  #{inspect(ours, pretty: true)}
                """)
            end

          {:error, reason} ->
            flunk("schema #{name}: flatc could not read our buffer: #{inspect(reason)}")
        end
      end
    end

    defp assert_decode_of_flatc_binary(name, paths) do
      {schema, fqn, mod} = schema_info(name)

      check all(
              value <-
                ValueGen.root_gen(schema, fqn, union_vector_nils: false, specials: false),
              max_runs: @flatc_encode_runs
            ) do
        target = mod.__to_json_map__(ValueGen.expected(schema, fqn, value))
        feed = target |> drop_none_types() |> drop_nil_values() |> ordered_json()

        assert {:ok, bin} = Flatc.json_to_binary(Map.fetch!(paths, name), feed)
        assert {:ok, decoded} = mod.decode(bin)
        ours = mod.__to_json_map__(decoded)

        case Flatbuf.Test.UpstreamFixtures.deep_diff(
               drop_empty_lists(ours),
               drop_empty_lists(target)
             ) do
          :ok ->
            :ok

          diff ->
            flunk("""
            schema #{name}: decoding flatc's binary for our JSON diverged.

              first divergence: #{inspect(diff)}

              ours:   #{inspect(ours, pretty: true)}
              target: #{inspect(target, pretty: true)}
            """)
        end
      end
    end

    # -------------------------------------------------------------------
    # JSON-shape normalization helpers (flatc directions only)
    # -------------------------------------------------------------------

    # Like UpstreamFixtures.deep_diff/2, but floats compare with the
    # tolerance flatc's fixed-notation printing imposes: ~6 decimal
    # places for f32, 12 for f64 (probed against v25.12.19).
    # Everything that isn't a float still compares exactly.
    defp print_tolerant_diff(a, a, _path), do: :ok

    defp print_tolerant_diff(a, b, path) when is_map(a) and is_map(b) do
      keys_a = a |> Map.keys() |> Enum.sort()
      keys_b = b |> Map.keys() |> Enum.sort()

      if keys_a == keys_b do
        Enum.reduce_while(keys_a, :ok, fn k, _ ->
          case print_tolerant_diff(Map.fetch!(a, k), Map.fetch!(b, k), [k | path]) do
            :ok -> {:cont, :ok}
            diff -> {:halt, diff}
          end
        end)
      else
        {:keys_diff, Enum.reverse(path), keys_a -- keys_b, keys_b -- keys_a}
      end
    end

    defp print_tolerant_diff(a, b, path) when is_list(a) and is_list(b) do
      if length(a) == length(b) do
        a
        |> Enum.zip(b)
        |> Enum.with_index()
        |> Enum.reduce_while(:ok, fn {{ae, be}, i}, _ ->
          case print_tolerant_diff(ae, be, [i | path]) do
            :ok -> {:cont, :ok}
            diff -> {:halt, diff}
          end
        end)
      else
        {:length_diff, Enum.reverse(path), length(a), length(b)}
      end
    end

    # Integers (and integer/integer mismatches) stay exact — the
    # tolerance only exists for float printing, so it only applies when
    # at least one side is a float.
    defp print_tolerant_diff(a, b, path)
         when is_number(a) and is_number(b) and (is_float(a) or is_float(b)) do
      # %.6f rounding puts the print error at up to exactly 5.0e-7
      # absolute (e.g. -0.4140625 → "-0.414062"); use 1.0e-6 so the
      # boundary case clears, plus a relative term for wide magnitudes.
      tolerance = max(1.0e-6, 1.0e-6 * max(abs(a), abs(b)))

      if abs(a - b) <= tolerance,
        do: :ok,
        else: {:value_diff, Enum.reverse(path), a, b}
    end

    defp print_tolerant_diff(a, b, path), do: {:value_diff, Enum.reverse(path), a, b}

    # flatc emits a present-but-empty vector as `[]`; our __to_json_map__
    # canonicalizes empty vectors away. Both sides go through this before
    # the comparison so it's about values, not empty-key shape.
    defp drop_empty_lists(map) when is_map(map) do
      map
      |> Enum.reject(fn {_k, v} -> v == [] end)
      |> Map.new(fn {k, v} -> {k, drop_empty_lists(v)} end)
    end

    defp drop_empty_lists(list) when is_list(list), do: Enum.map(list, &drop_empty_lists/1)
    defp drop_empty_lists(other), do: other

    # `"<f>_type": "NONE"` keys carry no information on flatc's *input*
    # side, and its parser rejects some orderings of them — strip before
    # feeding (same approach as Flatbuf.EncodeOracleTest).
    defp drop_none_types(map) when is_map(map) do
      map
      |> Enum.reject(fn {k, v} -> String.ends_with?(k, "_type") and v == "NONE" end)
      |> Map.new(fn {k, v} -> {k, drop_none_types(v)} end)
    end

    defp drop_none_types(list) when is_list(list), do: Enum.map(list, &drop_none_types/1)
    defp drop_none_types(other), do: other

    # Absent optional scalars render as JSON null in our output; flatc's
    # parser wants the key omitted instead.
    defp drop_nil_values(map) when is_map(map) do
      map
      |> Enum.reject(fn {_k, v} -> v == nil end)
      |> Map.new(fn {k, v} -> {k, drop_nil_values(v)} end)
    end

    defp drop_nil_values(list) when is_list(list), do: Enum.map(list, &drop_nil_values/1)
    defp drop_nil_values(other), do: other

    # Render a map as JSON with `<field>_type` keys emitted before their
    # companion union value keys — flatc's JSON parser requires the
    # discriminator first (same helper as Flatbuf.EncodeOracleTest).
    defp ordered_json(map) when is_map(map) do
      body =
        map
        |> Enum.sort_by(fn {k, _v} ->
          {String.replace_suffix(k, "_type", ""), not String.ends_with?(k, "_type")}
        end)
        |> Enum.map_join(",", fn {k, v} -> JSON.encode!(k) <> ":" <> ordered_json(v) end)

      "{" <> body <> "}"
    end

    defp ordered_json(list) when is_list(list) do
      "[" <> Enum.map_join(list, ",", &ordered_json/1) <> "]"
    end

    defp ordered_json(other), do: JSON.encode!(other)
  else
    @tag skip: "flatc unavailable — install it or set $FLATBUF_FLATC"
    test "flatc property prerequisites" do
      :ok
    end
  end

  # ---------------------------------------------------------------------
  # Property bodies
  # ---------------------------------------------------------------------

  defp schema_info(name), do: Map.fetch!(@schemas, name)

  defp assert_decode_roundtrip(name) do
    {schema, fqn, mod} = schema_info(name)

    check all(value <- ValueGen.root_gen(schema, fqn), max_runs: @decode_runs) do
      case mod.encode(value) do
        {:ok, bin} ->
          expected = ValueGen.expected(schema, fqn, value)
          assert {:ok, decoded} = mod.decode(bin)
          assert decoded == expected

        {:error, reason} ->
          flunk("schema #{name}: encode rejected a generated value: #{inspect(reason)}")
      end
    end
  end

  defp assert_encoded_verifies(name) do
    {schema, fqn, mod} = schema_info(name)

    check all(value <- ValueGen.root_gen(schema, fqn), max_runs: @verify_runs) do
      assert {:ok, bin} = mod.encode(value)
      assert :ok = mod.verify(bin)
    end
  end
end
