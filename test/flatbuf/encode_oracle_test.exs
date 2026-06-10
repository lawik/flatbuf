defmodule Flatbuf.EncodeOracleTest do
  @moduledoc """
  Encode-direction differential tests against `flatc`.

  The corpus fixtures cover flatc-encode → Elixir-decode;
  `Flatbuf.OracleTest` covers our encoder with exactly one trivial
  table. This suite closes the gap: for each wire feature, build a
  value with our `encode/1`, hand the raw bytes to `flatc --json`, and
  require flatc's reading to match a hand-written expected JSON map
  (modulo the f32-bit-pattern / int-float equivalences
  `Flatbuf.Test.UpstreamFixtures.deep_diff/2` defines).

  Where it's nearly free we also pin the reverse on the same schema:
  the same expected JSON goes through `flatc --binary` and our
  `decode/1` + `__to_json_map__/1` must agree. Both directions share
  one expected map per feature, so a symmetric encoder/decoder bug
  can't hide.

  Schemas live in `test/fixtures/encode_oracle/*.fbs` (committed — no
  corpus required). Only `flatc` is needed; the suite skips with a
  placeholder when it can't be ensured.
  """

  use ExUnit.Case, async: false

  alias Flatbuf.Test.CodegenCompiler
  alias Flatbuf.Test.Flatc
  alias Flatbuf.Test.UpstreamFixtures

  @fixtures_dir Path.expand("../fixtures/encode_oracle", __DIR__)

  # Ensure flatc at compile time (downloads on first use, same as the
  # other oracle suites do in setup_all); skip the suite if that fails.
  @flatc_ok (try do
               _ = Flatbuf.Test.Flatc.ensure_available!()
               true
             rescue
               _ -> false
             end)

  if @flatc_ok do
    @schemas ~w(scalars strings vectors structs arrays enums unions
                union_vector nesting ident keys shared_strings vector_align)

    for name <- @schemas do
      CodegenCompiler.compile_path!(Path.join(@fixtures_dir, name <> ".fbs"),
        wire_module: Module.concat([Flatbuf.EncodeOracleTest.Wire, Macro.camelize(name)])
      )
    end

    setup_all do
      _ = Flatc.ensure_available!()
      :ok
    end

    # ---------------------------------------------------------------
    # 1. Scalars — every width, in-range boundary values, defaults
    # ---------------------------------------------------------------

    describe "scalars" do
      test "flatc reads back every width at its boundary value" do
        {:ok, bin} = EncOracle.Scalars.Everything.encode(scalars_input())
        assert_flatc_reads("scalars", bin, scalars_expected())
      end

      test "fields left at explicit defaults are omitted from the wire" do
        {:ok, bin} = EncOracle.Scalars.Everything.encode(scalars_input())

        # Without --defaults-json flatc only prints fields physically
        # present in the vtable — `answer` and `on` must not be there.
        expected = Map.drop(scalars_expected(), ["answer", "on"])
        assert_flatc_reads("scalars", bin, expected, defaults_json: false)
      end

      test "flatc-encoded buffer decodes to the same values" do
        assert_we_read_flatc("scalars", scalars_expected(), EncOracle.Scalars.Everything)
      end
    end

    defp scalars_input do
      %{
        i8_min: -128,
        u8_max: 255,
        i16_min: -32_768,
        u16_max: 65_535,
        i32_min: -2_147_483_648,
        u32_max: 4_294_967_295,
        i64_min: -9_223_372_036_854_775_808,
        u64_max: 18_446_744_073_709_551_615,
        f32_max: 3.4028234663852886e38,
        f32_pi: 3.14159,
        f64_e: 2.718281828459045,
        flag: true
      }
    end

    defp scalars_expected do
      %{
        "i8_min" => -128,
        "u8_max" => 255,
        "i16_min" => -32_768,
        "u16_max" => 65_535,
        "i32_min" => -2_147_483_648,
        "u32_max" => 4_294_967_295,
        "i64_min" => -9_223_372_036_854_775_808,
        "u64_max" => 18_446_744_073_709_551_615,
        "f32_max" => 3.4028234663852886e38,
        "f32_pi" => 3.14159,
        "f64_e" => 2.718281828459045,
        "flag" => true,
        # Left unset on encode; --defaults-json surfaces them.
        "answer" => 42,
        "on" => true
      }
    end

    # ---------------------------------------------------------------
    # 2. Strings — UTF-8 multibyte, empty string, vector of strings
    # ---------------------------------------------------------------

    describe "strings" do
      test "flatc reads UTF-8, empty strings, and string vectors" do
        {:ok, bin} = EncOracle.Strings.Doc.encode(strings_input())
        assert_flatc_reads("strings", bin, strings_expected())
      end

      test "flatc-encoded buffer decodes to the same strings" do
        assert_we_read_flatc("strings", strings_expected(), EncOracle.Strings.Doc)
      end
    end

    defp strings_input do
      %{
        title: "encode-oracle",
        empty: "",
        uni: "héllo wörld — 日本語 🎉",
        tags: ["alpha", "βήτα", "", "delta-4"]
      }
    end

    defp strings_expected do
      %{
        "title" => "encode-oracle",
        "empty" => "",
        "uni" => "héllo wörld — 日本語 🎉",
        "tags" => ["alpha", "βήτα", "", "delta-4"]
      }
    end

    # ---------------------------------------------------------------
    # 3. Vectors of scalars — every width, bools, empty vector
    # ---------------------------------------------------------------

    describe "scalar vectors" do
      test "flatc reads scalar vectors of every width" do
        {:ok, bin} = EncOracle.Vectors.Nums.encode(vectors_input())
        assert_flatc_reads("vectors", bin, vectors_expected())
      end

      test "flatc-encoded buffer decodes to the same vectors" do
        # `empty` is excluded: flatc prints a present-but-empty vector
        # as [], while our __to_json_map__ canonicalizes [] away — a
        # JSON-shape nuance, not a wire one (the primary-direction
        # test above pins that our encoder writes the empty vector).
        expected = Map.delete(vectors_expected(), "empty")
        assert_we_read_flatc("vectors", expected, EncOracle.Vectors.Nums)
      end
    end

    defp vectors_input do
      %{
        bytes: [0, 1, 128, 255],
        signed_bytes: [-128, -1, 127],
        shorts: [-32_768, 32_767, -2, 3],
        uints: [4_294_967_295, 0, 7],
        longs: [-9_223_372_036_854_775_808, 9_223_372_036_854_775_807, 42],
        floats: [1.5, -0.25, 3.14159],
        doubles: [2.718281828459045, -0.001],
        bools: [true, false, true, true],
        empty: []
      }
    end

    defp vectors_expected do
      %{
        "bytes" => [0, 1, 128, 255],
        "signed_bytes" => [-128, -1, 127],
        "shorts" => [-32_768, 32_767, -2, 3],
        "uints" => [4_294_967_295, 0, 7],
        "longs" => [-9_223_372_036_854_775_808, 9_223_372_036_854_775_807, 42],
        "floats" => [1.5, -0.25, 3.14159],
        "doubles" => [2.718281828459045, -0.001],
        "bools" => [true, false, true, true],
        "empty" => []
      }
    end

    # ---------------------------------------------------------------
    # 4. Structs — mixed widths, nesting, force_align, vector of
    # ---------------------------------------------------------------

    describe "structs" do
      test "flatc reads mixed-width, nested, and force-aligned structs" do
        {:ok, bin} = EncOracle.Structs.Holder.encode(structs_input())
        assert_flatc_reads("structs", bin, structs_expected())
      end

      test "flatc-encoded buffer decodes to the same structs" do
        assert_we_read_flatc("structs", structs_expected(), EncOracle.Structs.Holder)
      end
    end

    defp structs_input do
      %{
        tag: 7,
        p: %{x: 1.5, y: -2.5, z: 3.14159},
        mix: %{a: -5, b: 123_456_789_012_345, c: 65_535},
        n: %{id: 9, pos: %{x: -1.5, y: 0.5, z: 2.25}, m: %{a: 100, b: -42, c: 1}},
        big: %{v: -987_654_321, w: 11},
        vs: [%{x: 1.0, y: 2.0, z: 3.0}, %{x: -4.5, y: 5.5, z: -6.25}]
      }
    end

    defp structs_expected do
      %{
        "tag" => 7,
        "p" => %{"x" => 1.5, "y" => -2.5, "z" => 3.14159},
        "mix" => %{"a" => -5, "b" => 123_456_789_012_345, "c" => 65_535},
        "n" => %{
          "id" => 9,
          "pos" => %{"x" => -1.5, "y" => 0.5, "z" => 2.25},
          "m" => %{"a" => 100, "b" => -42, "c" => 1}
        },
        "big" => %{"v" => -987_654_321, "w" => 11},
        "vs" => [
          %{"x" => 1.0, "y" => 2.0, "z" => 3.0},
          %{"x" => -4.5, "y" => 5.5, "z" => -6.25}
        ]
      }
    end

    # ---------------------------------------------------------------
    # 5. Fixed-size arrays in structs
    # ---------------------------------------------------------------

    describe "fixed-size arrays" do
      test "flatc reads scalar and struct arrays" do
        {:ok, bin} = EncOracle.Arrays.Holder.encode(arrays_input())
        assert_flatc_reads("arrays", bin, arrays_expected())
      end

      test "flatc-encoded buffer decodes to the same arrays" do
        assert_we_read_flatc("arrays", arrays_expected(), EncOracle.Arrays.Holder)
      end
    end

    defp arrays_input do
      %{
        s: %{
          xs: [1, -2, 3],
          ys: [65_535, 0, 1, 2],
          inners: [%{a: 10, b: -20}, %{a: 30, b: 40}],
          tail: 255
        }
      }
    end

    defp arrays_expected do
      %{
        "s" => %{
          "xs" => [1, -2, 3],
          "ys" => [65_535, 0, 1, 2],
          "inners" => [%{"a" => 10, "b" => -20}, %{"a" => 30, "b" => 40}],
          "tail" => 255
        }
      }
    end

    # ---------------------------------------------------------------
    # 6. Enums — explicit values, bit_flags, vector of enums
    # ---------------------------------------------------------------

    describe "enums" do
      test "flatc reads explicit values, combined bit_flags, enum vectors" do
        {:ok, bin} = EncOracle.Enums.Painted.encode(enums_input())
        assert_flatc_reads("enums", bin, enums_expected())
      end

      test "flatc-encoded buffer decodes to the same enums" do
        assert_we_read_flatc("enums", enums_expected(), EncOracle.Enums.Painted)
      end
    end

    defp enums_input do
      # `c_default` left unset (stays at the Green default).
      %{
        c: :Blue,
        f: [:A, :C, :D],
        palette: [:Blue, :Red, :Green]
      }
    end

    defp enums_expected do
      %{
        "c" => "Blue",
        "c_default" => "Green",
        # flatc spells combined bit_flags space-separated.
        "f" => "A C D",
        "palette" => ["Blue", "Red", "Green"]
      }
    end

    # ---------------------------------------------------------------
    # 7. Unions — table, struct, and string variants + NONE
    # ---------------------------------------------------------------

    describe "unions" do
      test "flatc reads table, struct, and string variants" do
        {:ok, bin} = EncOracle.Unions.Holder.encode(unions_input())
        assert_flatc_reads("unions", bin, unions_expected())
      end

      test "flatc-encoded buffer decodes to the same variants" do
        assert_we_read_flatc("unions", unions_expected(), EncOracle.Unions.Holder)
      end
    end

    defp unions_input do
      # `fourth` left absent (NONE).
      %{
        first: {:Sword, %{dmg: 13}},
        second: {:Pos, %{x: 1.5, y: -2.5}},
        third: {:Words, "carpe diem"}
      }
    end

    defp unions_expected do
      %{
        "first_type" => "Sword",
        "first" => %{"dmg" => 13},
        "second_type" => "Pos",
        "second" => %{"x" => 1.5, "y" => -2.5},
        "third_type" => "Words",
        "third" => "carpe diem",
        "fourth_type" => "NONE"
      }
    end

    # ---------------------------------------------------------------
    # 8. Vectors of unions (mixed variants)
    # ---------------------------------------------------------------

    describe "vectors of unions" do
      test "flatc reads a union vector with mixed variants" do
        {:ok, bin} = EncOracle.UnionVec.Holder.encode(union_vector_input())
        assert_flatc_reads("union_vector", bin, union_vector_expected())
      end

      test "flatc-encoded buffer decodes to the same union vector" do
        assert_we_read_flatc("union_vector", union_vector_expected(), EncOracle.UnionVec.Holder)
      end

      # KNOWN ENCODE BUG (REVIEW C5): a nil (NONE) element in a vector
      # of unions crashes encode/1 with ArithmeticError in
      # Wire.create_offset_vector/2 — unskip when fixed.
      @tag :skip
      test "NONE elements in a vector of unions" do
        input = %{label: "with-none", things: [{:Sword, %{dmg: 1}}, nil, {:Words, "hi"}]}
        assert {:ok, bin} = EncOracle.UnionVec.Holder.encode(input)

        assert {:ok, json} = Flatc.binary_to_json(schema_path("union_vector"), bin)
        assert json["things_type"] == ["Sword", "NONE", "Words"]
      end

      # KNOWN CODEGEN BUG: a table whose only depth-recursing field is
      # a vector of unions emits a __verify_at__/3 whose head binds
      # `_depth` (recurses_field?/1, lib/flatbuf/codegen/table.ex:1204,
      # has no {:vector, {:union, _}} clause) while the union-vector
      # verify body references `depth - 1` (table.ex:1294) — the
      # generated module does not compile. union_vector.fbs carries a
      # `bonus: Sword` field purely to dodge this. Unskip when fixed.
      @tag :skip
      test "table whose only recursing field is a union vector compiles" do
        source = """
        namespace EncOracleRT.UnionVecOnly;

        table A { x: int; }
        union U { A }
        table Holder { us: [U]; }

        root_type Holder;
        """

        mods =
          CodegenCompiler.compile_source!(source,
            wire_module: Flatbuf.EncodeOracleTest.Wire.UnionVecOnly
          )

        assert EncOracleRT.UnionVecOnly.Holder in mods
      end
    end

    defp union_vector_input do
      %{
        label: "mixed",
        things: [{:Sword, %{dmg: 1}}, {:Bow, %{range: 9}}, {:Words, "hi"}, {:Sword, %{dmg: -2}}]
      }
    end

    defp union_vector_expected do
      %{
        "label" => "mixed",
        "things_type" => ["Sword", "Bow", "Words", "Sword"],
        "things" => [%{"dmg" => 1}, %{"range" => 9}, "hi", %{"dmg" => -2}]
      }
    end

    # ---------------------------------------------------------------
    # 9. Nested tables + shared subobject values
    # ---------------------------------------------------------------

    describe "nested tables" do
      test "flatc reads tables nested several levels deep" do
        {:ok, bin} = EncOracle.Nesting.Top.encode(nesting_input())
        assert_flatc_reads("nesting", bin, nesting_expected())
      end

      test "flatc-encoded buffer decodes to the same tree" do
        assert_we_read_flatc("nesting", nesting_expected(), EncOracle.Nesting.Top)
      end
    end

    defp nesting_input do
      # The same subobject value referenced from two places must come
      # out identical at both paths.
      shared = %{tag: "shared-leaf", n: 99}

      %{
        title: "top",
        mid: %{left: %{tag: "left-leaf", n: 1}, right: shared, depth: 2},
        direct: shared
      }
    end

    defp nesting_expected do
      shared = %{"tag" => "shared-leaf", "n" => 99}

      %{
        "title" => "top",
        "mid" => %{
          "left" => %{"tag" => "left-leaf", "n" => 1},
          "right" => shared,
          "depth" => 2
        },
        "direct" => shared
      }
    end

    # ---------------------------------------------------------------
    # 10. file_identifier + size-prefixed buffers
    # ---------------------------------------------------------------

    describe "file_identifier and size prefix" do
      test "identifier is emitted and flatc enforces it" do
        {:ok, bin} = EncOracle.Ident.Msg.encode(%{body: "ping", n: -7})
        assert binary_part(bin, 4, 4) == "ENOR"

        # raw_binary: false makes flatc verify the identifier instead
        # of skipping the check.
        assert_flatc_reads("ident", bin, %{"body" => "ping", "n" => -7}, raw_binary: false)
      end

      test "size-prefixed encode survives flatc --size-prefixed" do
        {:ok, bin} = EncOracle.Ident.Msg.encode_size_prefixed(%{body: "pong", n: 123})

        assert <<size::little-32, rest::binary>> = bin
        assert size == byte_size(rest)
        # Identifier sits after the prefix and the root uoffset.
        assert binary_part(rest, 4, 4) == "ENOR"

        assert_flatc_reads("ident", bin, %{"body" => "pong", "n" => 123},
          size_prefixed: true,
          raw_binary: false
        )
      end

      test "flatc's size-prefixed buffer decodes via decode_size_prefixed/1" do
        json = JSON.encode!(%{"body" => "echo", "n" => 5})

        assert {:ok, bin} =
                 Flatc.json_to_binary(schema_path("ident"), json, size_prefixed: true)

        assert {:ok, decoded} = EncOracle.Ident.Msg.decode_size_prefixed(bin)
        assert decoded.body == "echo"
        assert decoded.n == 5
      end
    end

    # ---------------------------------------------------------------
    # 11. (key) attribute — sorted vectors of tables
    # ---------------------------------------------------------------

    describe "key attribute" do
      test "encoded key vectors land sorted on the wire" do
        # Input is deliberately unsorted; flatc's JSON output reveals
        # the wire order, which must be ascending by key.
        {:ok, bin} = EncOracle.Keys.Index.encode(keys_input())
        assert_flatc_reads("keys", bin, keys_expected())
      end

      test "our binary search works against a flatc-encoded buffer" do
        json = JSON.encode!(keys_expected())
        assert {:ok, bin} = Flatc.json_to_binary(schema_path("keys"), json)

        root = Flatbuf.EncodeOracleTest.Wire.Keys.root_table_pos(bin)

        assert EncOracle.Keys.Index.find_words_by_name(bin, root, "pear").v == 4
        assert EncOracle.Keys.Index.find_nums_by_id(bin, root, 77).v == 7
        assert EncOracle.Keys.Index.find_words_by_name(bin, root, "zzz") == nil
      end
    end

    defp keys_input do
      %{
        words: [
          %{name: "pear", v: 4},
          %{name: "apple", v: 1},
          %{name: "plum", v: 3},
          %{name: "fig", v: 2}
        ],
        nums: [%{id: 900, v: 9}, %{id: 3, v: 1}, %{id: 77, v: 7}]
      }
    end

    defp keys_expected do
      # Sorted by key — proves the encoder ordered the wire vectors.
      %{
        "words" => [
          %{"name" => "apple", "v" => 1},
          %{"name" => "fig", "v" => 2},
          %{"name" => "pear", "v" => 4},
          %{"name" => "plum", "v" => 3}
        ],
        "nums" => [
          %{"id" => 3, "v" => 1},
          %{"id" => 77, "v" => 7},
          %{"id" => 900, "v" => 9}
        ]
      }
    end

    # ---------------------------------------------------------------
    # 12. (shared) strings — deduplicated on the wire
    # ---------------------------------------------------------------

    describe "shared strings" do
      test "deduped strings still read back correctly via flatc" do
        {:ok, bin} = EncOracle.SharedStr.Board.encode(shared_strings_input())

        # Dedup proof: the shared value's bytes appear exactly once in
        # the buffer even though four fields reference it.
        assert length(:binary.matches(bin, "crimson")) == 1

        assert_flatc_reads("shared_strings", bin, shared_strings_expected())
      end
    end

    defp shared_strings_input do
      %{
        entries: [
          %{label: "crimson", note: "n1"},
          %{label: "viridian", note: "n2"},
          %{label: "crimson", note: "n3"},
          %{label: "viridian", note: "n4"},
          %{label: "crimson", note: "n5"}
        ],
        motto: "crimson"
      }
    end

    defp shared_strings_expected do
      %{
        "entries" => [
          %{"label" => "crimson", "note" => "n1"},
          %{"label" => "viridian", "note" => "n2"},
          %{"label" => "crimson", "note" => "n3"},
          %{"label" => "viridian", "note" => "n4"},
          %{"label" => "crimson", "note" => "n5"}
        ],
        "motto" => "crimson"
      }
    end

    # ---------------------------------------------------------------
    # 13. force_align on vector fields
    # ---------------------------------------------------------------

    describe "force_align vectors" do
      test "force-aligned vector bodies read back intact through flatc" do
        input = %{pad: 5, forced: [-1, 9_007_199_254_740_993, 3], bytes: [1, 2, 3, 4, 5]}
        {:ok, bin} = EncOracle.VecAlign.Doc.encode(input)

        # The [long] (force_align: 16) body must start 16-aligned.
        wire = Flatbuf.EncodeOracleTest.Wire.VectorAlign
        root = wire.root_table_pos(bin)
        slot = wire.read_vtable_field(bin, root, 6)
        vec_pos = wire.follow_uoffset(bin, root + slot)
        assert rem(vec_pos + 4, 16) == 0

        expected = %{
          "pad" => 5,
          "forced" => [-1, 9_007_199_254_740_993, 3],
          "bytes" => [1, 2, 3, 4, 5]
        }

        assert_flatc_reads("vector_align", bin, expected)
      end
    end

    # ---------------------------------------------------------------
    # Helpers
    # ---------------------------------------------------------------

    defp schema_path(name), do: Path.join(@fixtures_dir, name <> ".fbs")

    # Primary direction: our bytes, flatc's reading, hand-written truth.
    defp assert_flatc_reads(schema, bin, expected, opts \\ []) do
      case Flatc.binary_to_json(schema_path(schema), bin, opts) do
        {:ok, json} ->
          case UpstreamFixtures.deep_diff(json, expected) do
            :ok ->
              :ok

            diff ->
              flunk("""
              flatc read our #{schema} buffer differently than expected.

                first divergence: #{inspect(diff)}

                flatc:    #{inspect(json, pretty: true)}
                expected: #{inspect(expected, pretty: true)}
              """)
          end

        {:error, reason} ->
          flunk("""
          flatc could not read our #{schema} buffer:

            #{inspect(reason)}
          """)
      end
    end

    # Render a map as JSON with `<field>_type` keys emitted before
    # their companion union value keys — flatc's JSON parser requires
    # the discriminator first, and `JSON.encode!/1` on a map gives no
    # ordering guarantee.
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

    # flatc's JSON parser rejects buffers where a `"<f>_type": "NONE"`
    # discriminator precedes another union's type/value pair ("illegal
    # type id"). The key carries no information on the input side, so
    # strip it from what we feed flatc — the comparison target keeps
    # it, since flatc's own output (and our __to_json_map__/1) always
    # spell absent unions as "NONE".
    defp drop_none_types(map) when is_map(map) do
      map
      |> Enum.reject(fn {k, v} -> String.ends_with?(k, "_type") and v == "NONE" end)
      |> Map.new(fn {k, v} -> {k, drop_none_types(v)} end)
    end

    defp drop_none_types(list) when is_list(list), do: Enum.map(list, &drop_none_types/1)
    defp drop_none_types(other), do: other

    # Secondary direction: flatc's bytes for the same expected JSON,
    # decoded by us, compared via the flatc-shaped __to_json_map__/1.
    defp assert_we_read_flatc(schema, expected, mod) do
      flatc_input = expected |> drop_none_types() |> ordered_json()
      assert {:ok, bin} = Flatc.json_to_binary(schema_path(schema), flatc_input)
      assert {:ok, decoded} = mod.decode(bin)
      ours = mod.__to_json_map__(decoded)

      case UpstreamFixtures.deep_diff(ours, expected) do
        :ok ->
          :ok

        diff ->
          flunk("""
          our decode of flatc's #{schema} buffer diverges.

            first divergence: #{inspect(diff)}

            ours:     #{inspect(ours, pretty: true)}
            expected: #{inspect(expected, pretty: true)}
          """)
      end
    end
  else
    @tag skip: "flatc unavailable — install it or set $FLATBUF_FLATC"
    test "encode oracle prerequisites" do
      :ok
    end
  end
end
