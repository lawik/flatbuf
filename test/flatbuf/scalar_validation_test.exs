defmodule Flatbuf.ScalarValidationTest do
  @moduledoc """
  Regression tests for C1: scalar values are validated against their
  wire type on the encode path. Elixir binary construction truncates
  out-of-range integers silently, so without validation
  `encode(%{a: 70_000})` on a ushort field would "succeed" and decode
  back as 4_464. Every scalar write path — table fields, vectors,
  struct members, fixed arrays, enum underlying values, hash-attribute
  fields — must reject bad values with a tagged error tuple instead.
  """

  use ExUnit.Case, async: false

  alias Flatbuf.Test.CodegenCompiler

  @schema """
  namespace ScalarV;

  enum Color: ubyte { Red, Green, Blue }

  struct Pt {
    x: int;
    y: ushort;
    flags: [ubyte:2];
  }

  table T {
    a: ushort;
    b: byte;
    big: ulong;
    f: float;
    d: double;
    flag: bool;
    color: Color;
    nums: [ushort];
    bools: [bool];
    colors: [Color];
    pt: Pt;
    id: uint (hash: "fnv1a_32");
  }

  root_type T;
  """

  CodegenCompiler.compile_source!(@schema, wire_module: Flatbuf.ScalarValidationTest.Wire)

  describe "table scalar fields" do
    test "out-of-range ushort is a tagged error, not silent truncation" do
      assert {:error, {:scalar_out_of_range, :a, :u16, 70_000}} = ScalarV.T.encode(%{a: 70_000})
    end

    test "negative value into an unsigned field is rejected" do
      assert {:error, {:scalar_out_of_range, :a, :u16, -1}} = ScalarV.T.encode(%{a: -1})
      assert {:error, {:scalar_out_of_range, :big, :u64, -1}} = ScalarV.T.encode(%{big: -1})
    end

    test "signed byte range is enforced on both ends" do
      assert {:error, {:scalar_out_of_range, :b, :i8, 128}} = ScalarV.T.encode(%{b: 128})
      assert {:error, {:scalar_out_of_range, :b, :i8, -129}} = ScalarV.T.encode(%{b: -129})
    end

    test "wrong-typed values are tagged errors" do
      assert {:error, {:invalid_scalar, :a, :u16, "hi"}} = ScalarV.T.encode(%{a: "hi"})
      assert {:error, {:invalid_scalar, :a, :u16, 1.5}} = ScalarV.T.encode(%{a: 1.5})
      assert {:error, {:invalid_scalar, :f, :f32, "x"}} = ScalarV.T.encode(%{f: "x"})
      assert {:error, {:invalid_scalar, :flag, :bool, 1}} = ScalarV.T.encode(%{flag: 1})
      assert {:error, {:invalid_scalar, :flag, :bool, nil}} = ScalarV.T.encode(%{flag: nil})
    end

    test "boundary values are accepted and round-trip exactly" do
      value = %{
        a: 65_535,
        b: -128,
        big: 0xFFFFFFFFFFFFFFFF,
        flag: true
      }

      assert {:ok, bin} = ScalarV.T.encode(value)
      assert {:ok, decoded} = ScalarV.T.decode(bin)
      assert decoded.a == 65_535
      assert decoded.b == -128
      assert decoded.big == 0xFFFFFFFFFFFFFFFF
      assert decoded.flag == true
    end

    test "floats accept integers and the IEEE special atoms" do
      assert {:ok, bin} = ScalarV.T.encode(%{f: 3, d: :nan})
      assert {:ok, decoded} = ScalarV.T.decode(bin)
      assert decoded.f == 3.0
      assert decoded.d == :nan
    end
  end

  describe "vectors of scalars" do
    test "an out-of-range element is rejected with the field name" do
      assert {:error, {:scalar_out_of_range, :nums, :u16, 99_999}} =
               ScalarV.T.encode(%{nums: [1, 99_999]})
    end

    test "a wrong-typed element is rejected" do
      assert {:error, {:invalid_scalar, :nums, :u16, nil}} = ScalarV.T.encode(%{nums: [1, nil]})
      assert {:error, {:invalid_scalar, :bools, :bool, 0}} = ScalarV.T.encode(%{bools: [true, 0]})
    end

    test "in-range vectors round-trip" do
      assert {:ok, bin} = ScalarV.T.encode(%{nums: [0, 65_535], bools: [true, false]})
      assert {:ok, decoded} = ScalarV.T.decode(bin)
      assert decoded.nums == [0, 65_535]
      assert decoded.bools == [true, false]
    end
  end

  describe "enum underlying values" do
    test "a variant whose declared value overflows the underlying type never reaches the encoder" do
      # The resolver rejects the declaration outright, so the encoder's
      # check_scalar! on enum underlying values is pure defense-in-depth.
      assert {:error, {:enum_value_out_of_range, _, "Huge", 300, _}} =
               Flatbuf.Schema.Resolver.resolve_source("""
               enum Wide: ubyte { Small = 1, Huge = 300 }
               table T { w: Wide; }
               root_type T;
               """)
    end

    test "valid enum values still encode" do
      assert {:ok, bin} = ScalarV.T.encode(%{color: :Blue, colors: [:Green]})
      assert {:ok, decoded} = ScalarV.T.decode(bin)
      assert decoded.color == :Blue
      assert decoded.colors == [:Green]
    end
  end

  describe "struct fields" do
    test "an out-of-range struct member is rejected with the member name" do
      assert {:error, {:scalar_out_of_range, :y, :u16, 70_000}} =
               ScalarV.T.encode(%{pt: %{x: 1, y: 70_000, flags: [0, 0]}})
    end

    test "an out-of-range fixed-array element is rejected" do
      assert {:error, {:scalar_out_of_range, :flags, :u8, 256}} =
               ScalarV.T.encode(%{pt: %{x: 1, y: 2, flags: [1, 256]}})
    end

    test "a valid struct round-trips" do
      assert {:ok, bin} = ScalarV.T.encode(%{pt: %{x: -5, y: 65_535, flags: [255, 0]}})
      assert {:ok, decoded} = ScalarV.T.decode(bin)
      assert decoded.pt.x == -5
      assert decoded.pt.y == 65_535
      assert decoded.pt.flags == [255, 0]
    end
  end

  describe "hash-attribute fields" do
    test "strings hash into range and encode" do
      assert {:ok, bin} = ScalarV.T.encode(%{id: "some/asset"})
      assert {:ok, decoded} = ScalarV.T.decode(bin)
      assert decoded.id == Flatbuf.ScalarValidationTest.Wire.fnv1a_32("some/asset")
    end

    test "a pre-hashed integer is validated post-hash" do
      assert {:error, {:scalar_out_of_range, :id, :u32, 0x100000000}} =
               ScalarV.T.encode(%{id: 0x100000000})
    end
  end

  test "valid buffers decode unchanged by validation" do
    value = %{a: 12, b: -3, f: 1.5, flag: true, nums: [7], color: :Green}
    assert {:ok, bin} = ScalarV.T.encode(value)
    assert :ok = ScalarV.T.verify(bin)
    assert {:ok, decoded} = ScalarV.T.decode(bin)
    assert decoded.a == 12
    assert decoded.nums == [7]
  end
end
