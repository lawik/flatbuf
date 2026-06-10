defmodule Flatbuf.UnionUnderlyingTypeTest do
  @moduledoc """
  Differential coverage for union underlying types (`union U : int { … }`).

  The wire contract (measured against flatc 25.12.19's generated C++
  and TypeScript — the only upstream implementations of the feature) is
  that the discriminator is read and written at the underlying type's
  full width and signedness: `GetField<int32_t>` for `: int`, a
  `Vector<ABC>` with 4-byte elements for the types vector, and so on.

  flatc's own text codec can't act as a direct oracle here: `--json`
  refuses any schema with a union underlying type ("not yet supported
  in at least one of the specified programming languages"), and the
  JSON→binary path mis-writes the discriminator as a single byte
  (rejecting values over 255 outright). So each union schema is paired
  with a *shadow schema* that spells the union field pair out as an
  explicit `<name>_type` scalar of the underlying type plus a plain
  table field. On the wire the two are byte-compatible — a union field
  is exactly a scalar slot plus a uoffset slot in adjacent vtable
  slots, and a union vector is a scalar vector plus an offset vector —
  which lets flatc read our buffers (through the shadow) and lets our
  decoder read flatc's buffers (encoded through the shadow).

  The explicit-`ubyte` case needs no shadow: it must be byte-identical
  to the classic annotation-free union format, which flatc's JSON codec
  fully supports.
  """

  use ExUnit.Case, async: false

  alias Flatbuf.Test.CodegenCompiler
  alias Flatbuf.Test.Flatc
  alias Flatbuf.Test.UpstreamFixtures

  @flatc_ok (try do
               _ = Flatbuf.Test.Flatc.ensure_available!()
               true
             rescue
               _ -> false
             end)

  if @flatc_ok do
    # The upstream union_underlying_type_test.fbs shape: int underlying,
    # discriminators that cannot fit a byte.
    @schema_int """
    namespace UUTInt;

    table A { a: int; }
    table B { b: string; }

    union ABC : int { A = 555, B = 666 }

    table D {
      test_union: ABC;
      test_vector_of_union: [ABC];
    }

    root_type D;
    """

    # A wider (8-byte) underlying type, with a negative discriminator —
    # legal because `long` is signed.
    @schema_long """
    namespace UUTLong;

    table A { a: int; }
    table B { b: string; }

    union UL : long { A = 5000000000, B = -7 }

    table D {
      test_union: UL;
      test_vector_of_union: [UL];
    }

    root_type D;
    """

    # Explicit ubyte — must stay wire-compatible with the classic format.
    @schema_byte """
    namespace UUTByte;

    table A { a: int; }
    table B { b: string; }

    union UB : ubyte { A, B }

    table D {
      test_union: UB;
      test_vector_of_union: [UB];
    }

    root_type D;
    """

    CodegenCompiler.compile_source!(@schema_int,
      wire_module: Flatbuf.UnionUnderlyingTypeTest.Wire.Int
    )

    CodegenCompiler.compile_source!(@schema_long,
      wire_module: Flatbuf.UnionUnderlyingTypeTest.Wire.Long
    )

    CodegenCompiler.compile_source!(@schema_byte,
      wire_module: Flatbuf.UnionUnderlyingTypeTest.Wire.Byte
    )

    setup_all do
      _ = Flatc.ensure_available!()

      dir = Path.join(System.tmp_dir!(), "flatbuf_uut_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      shadows =
        for {key, underlying, variant} <- [
              {:int_a, "int", "A"},
              {:long_a, "long", "A"},
              {:long_b, "long", "B"}
            ],
            into: %{} do
          path = Path.join(dir, "shadow_#{key}.fbs")
          File.write!(path, shadow_source(underlying, variant))
          {key, path}
        end

      classic = Path.join(dir, "classic.fbs")

      File.write!(classic, """
      table A { a: int; }
      table B { b: string; }

      union UB { A, B }

      table D {
        test_union: UB;
        test_vector_of_union: [UB];
      }

      root_type D;
      """)

      {:ok, shadows: shadows, classic: classic}
    end

    # The shadow spells out the wire layout a union field pair occupies:
    # same field order, so the implicit vtable slots line up with the
    # union schema's two-slot expansion.
    defp shadow_source(underlying, variant) do
      """
      table A { a: int; }
      table B { b: string; }

      table D {
        test_union_type: #{underlying};
        test_union: #{variant};
        test_vector_of_union_type: [#{underlying}];
        test_vector_of_union: [#{variant}];
      }

      root_type D;
      """
    end

    # ---------------------------------------------------------------
    # int underlying — the upstream union_underlying_type_test shape
    # ---------------------------------------------------------------

    describe "int underlying type" do
      test "flatc reads our 4-byte discriminators through the shadow schema", ctx do
        {:ok, bin} =
          UUTInt.D.encode(%{
            test_union: {:A, %{a: 42}},
            test_vector_of_union: [{:A, %{a: 1}}, {:A, %{a: 2}}]
          })

        assert_flatc_reads(ctx.shadows.int_a, bin, %{
          "test_union_type" => 555,
          "test_union" => %{"a" => 42},
          "test_vector_of_union_type" => [555, 555],
          "test_vector_of_union" => [%{"a" => 1}, %{"a" => 2}]
        })
      end

      test "a flatc-encoded shadow buffer decodes through the union schema", ctx do
        json = ~s({
          "test_union_type": 555,
          "test_union": {"a": 7},
          "test_vector_of_union_type": [555, 555],
          "test_vector_of_union": [{"a": 1}, {"a": 2}]
        })

        {:ok, bin} = Flatc.json_to_binary(ctx.shadows.int_a, json)

        assert :ok = UUTInt.D.verify(bin)
        assert {:ok, decoded} = UUTInt.D.decode(bin)
        assert {:A, %UUTInt.A{a: 7}} = decoded.test_union
        assert [{:A, %UUTInt.A{a: 1}}, {:A, %UUTInt.A{a: 2}}] = decoded.test_vector_of_union
      end

      test "mixed variants and NONE elements round-trip; verify accepts our encode" do
        value = %{
          test_union: {:B, %{b: "wide"}},
          test_vector_of_union: [{:A, %{a: 5}}, nil, {:B, %{b: "x"}}]
        }

        {:ok, bin} = UUTInt.D.encode(value)
        assert :ok = UUTInt.D.verify(bin)

        {:ok, decoded} = UUTInt.D.decode(bin)
        assert {:B, %UUTInt.B{b: "wide"}} = decoded.test_union

        assert [{:A, %UUTInt.A{a: 5}}, nil, {:B, %UUTInt.B{b: "x"}}] =
                 decoded.test_vector_of_union
      end

      test "a corrupted single-field discriminator is rejected by verify" do
        {:ok, bin} = UUTInt.D.encode(%{test_union: {:A, %{a: 42}}})
        corrupted = patch_unique!(bin, <<555::little-signed-32>>, <<999::little-signed-32>>)

        assert {:error, {:unknown_union_variant, 999}, [:test_union]} =
                 UUTInt.D.verify(corrupted)
      end

      test "a corrupted types-vector element is rejected by verify" do
        {:ok, bin} =
          UUTInt.D.encode(%{
            test_union: nil,
            test_vector_of_union: [{:A, %{a: 1}}, {:B, %{b: "x"}}]
          })

        corrupted = patch_unique!(bin, <<666::little-signed-32>>, <<999::little-signed-32>>)

        # The B element sits at index 1; the path pins it.
        assert {:error, {:unknown_union_variant, 999}, [:test_vector_of_union, 1]} =
                 UUTInt.D.verify(corrupted)
      end
    end

    # ---------------------------------------------------------------
    # long underlying — 8-byte discriminators, one of them negative
    # ---------------------------------------------------------------

    describe "long underlying type" do
      test "flatc reads our 8-byte discriminators through the shadow schema", ctx do
        {:ok, bin} =
          UUTLong.D.encode(%{
            test_union: {:A, %{a: 1}},
            test_vector_of_union: [{:A, %{a: 2}}, {:A, %{a: 3}}]
          })

        assert_flatc_reads(ctx.shadows.long_a, bin, %{
          "test_union_type" => 5_000_000_000,
          "test_union" => %{"a" => 1},
          "test_vector_of_union_type" => [5_000_000_000, 5_000_000_000],
          "test_vector_of_union" => [%{"a" => 2}, %{"a" => 3}]
        })
      end

      test "flatc reads a negative discriminator back as -7", ctx do
        {:ok, bin} = UUTLong.D.encode(%{test_union: {:B, %{b: "neg"}}})

        assert_flatc_reads(ctx.shadows.long_b, bin, %{
          "test_union_type" => -7,
          "test_union" => %{"b" => "neg"}
        })
      end

      test "a flatc-encoded shadow buffer decodes through the union schema", ctx do
        json = ~s({
          "test_union_type": -7,
          "test_union": {"b": "from flatc"},
          "test_vector_of_union_type": [-7],
          "test_vector_of_union": [{"b": "elem"}]
        })

        {:ok, bin} = Flatc.json_to_binary(ctx.shadows.long_b, json)

        assert :ok = UUTLong.D.verify(bin)
        assert {:ok, decoded} = UUTLong.D.decode(bin)
        assert {:B, %UUTLong.B{b: "from flatc"}} = decoded.test_union
        assert [{:B, %UUTLong.B{b: "elem"}}] = decoded.test_vector_of_union
      end

      test "a corrupted 8-byte discriminator is rejected by verify" do
        {:ok, bin} = UUTLong.D.encode(%{test_union: {:B, %{b: "neg"}}})
        corrupted = patch_unique!(bin, <<-7::little-signed-64>>, <<12_345::little-signed-64>>)

        assert {:error, {:unknown_union_variant, 12_345}, [:test_union]} =
                 UUTLong.D.verify(corrupted)
      end
    end

    # ---------------------------------------------------------------
    # explicit ubyte — byte-compatible with the classic union format
    # ---------------------------------------------------------------

    describe "explicit ubyte underlying type" do
      test "flatc reads our buffer through the annotation-free classic schema", ctx do
        {:ok, bin} =
          UUTByte.D.encode(%{
            test_union: {:A, %{a: 3}},
            test_vector_of_union: [{:B, %{b: "x"}}, {:A, %{a: 9}}]
          })

        assert_flatc_reads(ctx.classic, bin, %{
          "test_union_type" => "A",
          "test_union" => %{"a" => 3},
          "test_vector_of_union_type" => ["B", "A"],
          "test_vector_of_union" => [%{"b" => "x"}, %{"a" => 9}]
        })
      end

      test "a flatc-encoded classic buffer decodes through the explicit-ubyte schema", ctx do
        json = ~s({
          "test_union_type": "B",
          "test_union": {"b": "classic"},
          "test_vector_of_union_type": ["A", "B"],
          "test_vector_of_union": [{"a": 4}, {"b": "y"}]
        })

        {:ok, bin} = Flatc.json_to_binary(ctx.classic, json)

        assert :ok = UUTByte.D.verify(bin)
        assert {:ok, decoded} = UUTByte.D.decode(bin)
        assert {:B, %UUTByte.B{b: "classic"}} = decoded.test_union
        assert [{:A, %UUTByte.A{a: 4}}, {:B, %UUTByte.B{b: "y"}}] = decoded.test_vector_of_union
      end
    end

    # ---------------------------------------------------------------
    # Helpers
    # ---------------------------------------------------------------

    defp assert_flatc_reads(schema_path, bin, expected) do
      case Flatc.binary_to_json(schema_path, bin) do
        {:ok, json} ->
          case UpstreamFixtures.deep_diff(json, expected) do
            :ok ->
              :ok

            diff ->
              flunk("""
              flatc read our buffer differently than expected.

                first divergence: #{inspect(diff)}

                flatc:    #{inspect(json, pretty: true)}
                expected: #{inspect(expected, pretty: true)}
              """)
          end

        {:error, reason} ->
          flunk("""
          flatc could not read our buffer through #{Path.basename(schema_path)}:

            #{inspect(reason)}
          """)
      end
    end

    # Replace a byte pattern that must occur exactly once — so the
    # corruption verifiably hits the discriminator and nothing else.
    defp patch_unique!(bin, old, new) when byte_size(old) == byte_size(new) do
      assert [{pos, len}] = :binary.matches(bin, old),
             "expected exactly one occurrence of #{inspect(old)} in the buffer"

      <<pre::binary-size(pos), _::binary-size(len), post::binary>> = bin
      pre <> new <> post
    end
  else
    @tag :skip
    test "flatc is unavailable" do
      flunk("flatc could not be ensured; differential union tests skipped")
    end
  end
end
