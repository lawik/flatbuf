defmodule Flatbuf.KeyLookupTest do
  @moduledoc """
  `(key)` on a table field marks that field as the sortable key. When
  the table appears in a vector field of a parent table, codegen emits
  `find_<field>_by_<key>(buf, table_pos, target)` on the parent — a
  binary-search lookup against the (assumed sorted) vector.

  The vector must already be sorted by key; on the wire side
  FlatBuffers expects encoders to sort before writing. This test
  builds the vector in already-sorted order and verifies both
  numeric and string key lookups land on the right row.
  """

  use ExUnit.Case, async: false

  alias Flatbuf.Test.CodegenCompiler

  @schema """
  namespace KeyTest;

  table Stat {
    id: string;
    val: long = 0;
    count: ushort = 0 (key);
  }

  table NamedStat {
    name: string (key);
    score: int;
  }

  table Group {
    stats: [Stat];
    named: [NamedStat];
  }

  root_type Group;
  """

  CodegenCompiler.compile_source!(@schema, wire_module: Flatbuf.KeyLookupTest.Wire)

  describe "numeric key lookup" do
    test "find_stats_by_count/3 returns the matching entry" do
      # Intentionally unsorted — the encoder sorts by `(key)` before
      # writing so the binary search reader finds matches anyway.
      stats = [
        %{id: "delta", val: 400, count: 99},
        %{id: "alpha", val: 100, count: 1},
        %{id: "gamma", val: 300, count: 10},
        %{id: "beta", val: 200, count: 5}
      ]

      {:ok, bin} = KeyTest.Group.encode(%{stats: stats})
      {:ok, _decoded} = KeyTest.Group.decode(bin)

      root_pos = Flatbuf.KeyLookupTest.Wire.root_table_pos(bin)

      hit = KeyTest.Group.find_stats_by_count(bin, root_pos, 5)
      assert hit.id == "beta"
      assert hit.val == 200
      assert hit.count == 5

      far = KeyTest.Group.find_stats_by_count(bin, root_pos, 99)
      assert far.id == "delta"
    end

    test "miss returns nil" do
      stats = [%{id: "only", val: 1, count: 10}]
      {:ok, bin} = KeyTest.Group.encode(%{stats: stats})
      root_pos = Flatbuf.KeyLookupTest.Wire.root_table_pos(bin)

      assert KeyTest.Group.find_stats_by_count(bin, root_pos, 999) == nil
    end

    test "absent vector returns nil" do
      {:ok, bin} = KeyTest.Group.encode(%{})
      root_pos = Flatbuf.KeyLookupTest.Wire.root_table_pos(bin)
      assert KeyTest.Group.find_stats_by_count(bin, root_pos, 5) == nil
    end
  end

  describe "string key lookup" do
    test "find_named_by_name/3 returns the matching entry" do
      # Unsorted — encoder sorts before writing.
      named = [
        %{name: "cherry", score: 3},
        %{name: "apple", score: 1},
        %{name: "banana", score: 2}
      ]

      {:ok, bin} = KeyTest.Group.encode(%{named: named})
      root_pos = Flatbuf.KeyLookupTest.Wire.root_table_pos(bin)

      assert KeyTest.Group.find_named_by_name(bin, root_pos, "banana").score == 2
      assert KeyTest.Group.find_named_by_name(bin, root_pos, "zebra") == nil
    end
  end

  test "tables with a (key) field expose __flatbuf__(:key_field)" do
    assert KeyTest.Stat.__flatbuf__(:key_field) == :count
    assert KeyTest.NamedStat.__flatbuf__(:key_field) == :name
  end
end
