defmodule Flatbuf.ForceAlignTest do
  @moduledoc """
  `(force_align: N)` on a vector field raises the alignment of the
  vector's element body to at least N bytes. The body's starting
  offset within the final buffer is therefore N-aligned, allowing
  external readers (e.g. memory-mapped consumers, SIMD) to assume
  a known alignment.

  This is the vector half of `force_align`. Struct alignment is
  already honored in `Flatbuf.Schema.Resolver.compute_struct_layout/2`.
  """

  use ExUnit.Case, async: true

  alias Flatbuf.Test.CodegenCompiler

  @schema """
  namespace Aligned;

  table Doc {
    natural: [int];
    forced: [int] (force_align: 16);
  }

  root_type Doc;
  """

  CodegenCompiler.compile_source!(@schema, wire_module: Flatbuf.ForceAlignTest.Wire)

  test "force-aligned vector starts at a 16-byte boundary" do
    {:ok, bin} = Aligned.Doc.encode(%{forced: [1, 2, 3]})

    # Locate the `forced` vector by walking the vtable.
    root_pos = Flatbuf.ForceAlignTest.Wire.root_table_pos(bin)
    slot_offset = Flatbuf.ForceAlignTest.Wire.read_vtable_field(bin, root_pos, 6)
    vec_pos = Flatbuf.ForceAlignTest.Wire.follow_uoffset(bin, root_pos + slot_offset)

    # Body starts at vec_pos + 4 (after the u32 count). That should
    # be 16-aligned because of (force_align: 16).
    body_pos = vec_pos + 4
    assert rem(body_pos, 16) == 0
  end

  test "natural-alignment vector is just 4-aligned (no force)" do
    {:ok, bin} = Aligned.Doc.encode(%{natural: [1, 2, 3]})
    root_pos = Flatbuf.ForceAlignTest.Wire.root_table_pos(bin)
    slot_offset = Flatbuf.ForceAlignTest.Wire.read_vtable_field(bin, root_pos, 4)
    vec_pos = Flatbuf.ForceAlignTest.Wire.follow_uoffset(bin, root_pos + slot_offset)

    body_pos = vec_pos + 4
    assert rem(body_pos, 4) == 0
  end

  test "decode round-trips through both vectors" do
    {:ok, bin} = Aligned.Doc.encode(%{natural: [10, 20], forced: [1, 2, 3, 4]})
    {:ok, decoded} = Aligned.Doc.decode(bin)
    assert decoded.natural == [10, 20]
    assert decoded.forced == [1, 2, 3, 4]
  end
end
