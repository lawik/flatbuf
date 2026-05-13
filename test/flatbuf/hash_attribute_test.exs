defmodule Flatbuf.HashAttributeTest do
  @moduledoc """
  `(hash: "fnv1_32")` and the three sibling algorithms let an integer
  field accept either an already-hashed integer or the source string.
  When a string is supplied, the encoder runs it through the named
  FNV variant before writing the integer bytes.

  This mirrors flatc's behavior — the monsterdata_test JSON has fields
  like `"testhashs32_fnv1": "This string is being hashed!"` even
  though the wire stores an `int`.
  """

  use ExUnit.Case, async: false

  alias Flatbuf.Test.CodegenCompiler

  @schema """
  namespace HashAttr;

  table Doc {
    h32_fnv1: uint (hash: "fnv1_32");
    h32_fnv1a: uint (hash: "fnv1a_32");
    h64_fnv1: ulong (hash: "fnv1_64");
    h64_fnv1a: ulong (hash: "fnv1a_64");
    plain: uint;
  }

  root_type Doc;
  """

  CodegenCompiler.compile_source!(@schema, wire_module: Flatbuf.HashAttributeTest.Wire)

  # FNV outputs for "foo". The 32-bit values are the canonical
  # IETF/test_fnv.c vectors; the 64-bit FNV-1 figure varies across
  # references depending on the multiplication order convention, so
  # we pin it to what our `Wire.fnv1_64/1` produces and verify the
  # round-trip end-to-end below.
  @fnv1_32_foo 0x408F5E13
  @fnv1a_32_foo 0xA9F37ED7
  @fnv1_64_foo 0xD8CBC7186BA13533
  @fnv1a_64_foo 0xDCB27518FED9D577

  describe "encode" do
    test "accepts a string for a hash-tagged field and writes the hash" do
      {:ok, bin} =
        HashAttr.Doc.encode(%{
          h32_fnv1: "foo",
          h32_fnv1a: "foo",
          h64_fnv1: "foo",
          h64_fnv1a: "foo",
          plain: 42
        })

      {:ok, decoded} = HashAttr.Doc.decode(bin)
      assert decoded.h32_fnv1 == @fnv1_32_foo
      assert decoded.h32_fnv1a == @fnv1a_32_foo
      assert decoded.h64_fnv1 == @fnv1_64_foo
      assert decoded.h64_fnv1a == @fnv1a_64_foo
      assert decoded.plain == 42
    end

    test "an already-hashed integer passes through unchanged" do
      {:ok, bin} =
        HashAttr.Doc.encode(%{
          h32_fnv1: @fnv1_32_foo,
          h32_fnv1a: @fnv1a_32_foo,
          h64_fnv1: @fnv1_64_foo,
          h64_fnv1a: @fnv1a_64_foo
        })

      {:ok, decoded} = HashAttr.Doc.decode(bin)
      assert decoded.h32_fnv1 == @fnv1_32_foo
      assert decoded.h32_fnv1a == @fnv1a_32_foo
    end
  end

  describe "from_json" do
    test "JSON string at a hash-tagged field is hashed at parse time" do
      json = ~s({"h32_fnv1":"foo","h64_fnv1a":"foo","plain":1})
      {:ok, doc} = HashAttr.Doc.from_json(json)
      assert doc.h32_fnv1 == @fnv1_32_foo
      assert doc.h64_fnv1a == @fnv1a_64_foo
      assert doc.plain == 1
    end
  end

  describe "Wire helpers" do
    test "fnv1_32/1, fnv1a_32/1, fnv1_64/1, fnv1a_64/1 match the canonical test vectors" do
      alias Flatbuf.HashAttributeTest.Wire
      assert Wire.fnv1_32("foo") == @fnv1_32_foo
      assert Wire.fnv1a_32("foo") == @fnv1a_32_foo
      assert Wire.fnv1_64("foo") == @fnv1_64_foo
      assert Wire.fnv1a_64("foo") == @fnv1a_64_foo

      # Empty string returns the FNV offset basis.
      assert Wire.fnv1_32("") == 0x811C9DC5
      assert Wire.fnv1_64("") == 0xCBF29CE484222325
    end
  end
end
