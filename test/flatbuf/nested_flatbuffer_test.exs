defmodule Flatbuf.NestedFlatbufferTest do
  @moduledoc """
  `(nested_flatbuffer: "Type")` on a `[ubyte]` field marks the bytes as
  an opaque sub-buffer encoded against `Type`. The generated table
  module exposes a `<field>_as_<short_type>(buf, pos)` accessor that
  slices the bytes as a contiguous binary and decodes them via
  `Type.decode/1`.

  This is the upstream convention (see `nested_flatbuffer` in
  `flatbuffers/tests/monster_test.fbs`'s `testnestedflatbuffer` field).
  """

  use ExUnit.Case, async: false

  alias Flatbuf.Test.CodegenCompiler

  @schema """
  namespace Nested;

  table Inner {
    payload: string;
    count: int;
  }

  table Outer {
    label: string;
    blob: [ubyte] (nested_flatbuffer: "Inner");
  }

  root_type Outer;
  """

  CodegenCompiler.compile_source!(@schema, wire_module: Flatbuf.NestedFlatbufferTest.Wire)

  alias Flatbuf.NestedFlatbufferTest.Wire

  test "byte vector decodes as the nested type via *_as_inner/2" do
    # Build an Inner buffer manually — only the schema's `root_type`
    # gets an `encode/1`, and that's Outer here.
    b = Wire.new_builder()
    {b, root_addr} = Nested.Inner.build(b, %{payload: "hello", count: 42})
    b = Wire.finish(b, root_addr)
    inner_bin = Wire.to_binary(b)

    # Wrap those bytes inside Outer.blob.
    {:ok, outer_bin} =
      Nested.Outer.encode(%{
        label: "wrapper",
        blob: :binary.bin_to_list(inner_bin)
      })

    # Decode Outer to find the root table position.
    {:ok, outer} = Nested.Outer.decode(outer_bin)
    assert outer.label == "wrapper"

    # The nested accessor decodes the bytes as Inner.
    root_pos = Wire.root_table_pos(outer_bin)
    {:ok, inner} = Nested.Outer.blob_as_inner(outer_bin, root_pos)
    assert inner.payload == "hello"
    assert inner.count == 42
  end

  test "the accessor returns nil when the byte vector is absent" do
    {:ok, outer_bin} = Nested.Outer.encode(%{label: "no blob"})
    root_pos = Wire.root_table_pos(outer_bin)
    assert Nested.Outer.blob_as_inner(outer_bin, root_pos) == nil
  end
end
