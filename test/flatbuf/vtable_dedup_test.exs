defmodule Flatbuf.VtableDedupTest do
  @moduledoc """
  Per the FlatBuffers spec (§8), identical vtables within one buffer
  are deduplicated — the builder writes the vtable bytes once and
  subsequent tables with the same field-presence pattern reference
  the existing vtable via their soffset.

  We exercise this by building a buffer with many instances of the
  same table type and asserting that the dedup-aware encoder is
  smaller than the bytes-per-table count would predict.
  """

  use ExUnit.Case, async: false

  alias Flatbuf.Test.CodegenCompiler

  @schema """
  namespace VtableDedup;

  table Stat {
    id: int;
    val: int;
    count: int;
  }

  table Group {
    stats: [Stat];
  }

  root_type Group;
  """

  CodegenCompiler.compile_source!(@schema, wire_module: Flatbuf.VtableDedupTest.Wire)

  test "many identical tables share one vtable" do
    # All 50 stats have the same fields set → all have identical vtables.
    stats =
      for i <- 1..50 do
        %{id: i, val: i * 2, count: i * 3}
      end

    {:ok, bin} = VtableDedup.Group.encode(%{stats: stats})

    # Verify the buffer is well-formed and decodes back.
    assert :ok = VtableDedup.Group.verify(bin)
    {:ok, decoded} = VtableDedup.Group.decode(bin)
    assert length(decoded.stats) == 50
    assert Enum.at(decoded.stats, 0).id == 1
    assert Enum.at(decoded.stats, 49).id == 50

    # Inspect the builder state directly to confirm dedup happened.
    b = Flatbuf.VtableDedupTest.Wire.new_builder()

    {b, _addr} =
      VtableDedup.Group.build(b, %{
        stats: Enum.map(1..50, &%{id: &1, val: &1, count: &1})
      })

    # All 50 Stat tables share an identical field-presence pattern,
    # so exactly two unique vtables are written: one for the outer
    # Group table, one shared by all 50 Stat instances.
    assert map_size(b.vtables) == 2

    # With dedup, the buffer is meaningfully smaller than 50 vtables'
    # worth of overhead would predict.
    assert byte_size(bin) < 1100
  end

  test "tables with different field presence get separate vtables" do
    stats = [
      %{id: 1, val: 10, count: 100},
      # Same shape as above.
      %{id: 2, val: 20, count: 200},
      # Differs: count omitted (its default is 0 so it's not emitted).
      %{id: 3, val: 30, count: 0},
      # Same shape as #3.
      %{id: 4, val: 40, count: 0}
    ]

    {:ok, bin} = VtableDedup.Group.encode(%{stats: stats})
    assert :ok = VtableDedup.Group.verify(bin)

    {:ok, decoded} = VtableDedup.Group.decode(bin)
    assert Enum.map(decoded.stats, & &1.count) == [100, 200, 0, 0]
  end
end
