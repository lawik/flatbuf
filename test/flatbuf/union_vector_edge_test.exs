defmodule Flatbuf.UnionVectorEdgeTest do
  @moduledoc """
  Regression tests for C4 and C5 — the edges of vector-of-union
  support.

  C5: a `nil` element is a NONE entry. The wire shape matches what
  flatc's binary toolchain understands (verified against `flatc
  --annotate`): discriminator 0 in the type vector, uoffset 0 in the
  value vector. The decoder yields `nil` and the verifier skips the
  value slot, exactly like flatc's generated `Verify<U>Vector` —
  note flatc's *JSON* layer can't express NONE elements in either
  direction, so this stays a binary-level feature.

  C4: the two parallel vectors must agree. The verifier asserts
  both-or-neither presence and equal element counts (flatc checks
  both), and never raises on a mismatch.
  """

  use ExUnit.Case, async: false

  alias Flatbuf.Test.CodegenCompiler

  @schema """
  namespace UVEdge;

  table Sword { dmg: short; }
  table Shield { guard: short; }

  union Item { Sword, Shield }

  table Bag {
    name: string;
    items: [Item];
  }

  root_type Bag;
  """

  @wire Flatbuf.UnionVectorEdgeTest.Wire

  CodegenCompiler.compile_source!(@schema, wire_module: @wire)

  # The `items` field's value slot in Bag's vtable: name=4, items_type=6,
  # items=8.
  @items_value_slot 8
  @items_type_slot 6

  defp encode!(items) do
    {:ok, bin} = UVEdge.Bag.encode(%{name: "bag", items: items})
    bin
  end

  # Absolute positions of the two vectors' u32 count words.
  defp vector_count_positions(bin) do
    root_pos = @wire.root_table_pos(bin)
    type_o = @wire.read_vtable_field(bin, root_pos, @items_type_slot)
    value_o = @wire.read_vtable_field(bin, root_pos, @items_value_slot)
    types_pos = @wire.follow_uoffset(bin, root_pos + type_o)
    vals_pos = @wire.follow_uoffset(bin, root_pos + value_o)
    {types_pos, vals_pos}
  end

  defp put_u32(bin, pos, v) do
    <<head::binary-size(pos), _::little-32, tail::binary>> = bin
    <<head::binary, v::little-32, tail::binary>>
  end

  defp put_u16(bin, pos, v) do
    <<head::binary-size(pos), _::little-16, tail::binary>> = bin
    <<head::binary, v::little-16, tail::binary>>
  end

  defp safe_verify(bin) do
    UVEdge.Bag.verify(bin)
  rescue
    e -> {:raised, e}
  end

  describe "NONE (nil) elements — C5" do
    test "encode accepts nil elements; decode yields nil at the same index" do
      bin = encode!([{:Sword, %{dmg: 3}}, nil, {:Shield, %{guard: 9}}])

      assert :ok = UVEdge.Bag.verify(bin)
      assert {:ok, decoded} = UVEdge.Bag.decode(bin)
      assert [{:Sword, %{dmg: 3}}, nil, {:Shield, %{guard: 9}}] = decoded.items
    end

    test "the NONE element's value slot holds uoffset 0" do
      bin = encode!([nil, {:Sword, %{dmg: 1}}])
      {types_pos, vals_pos} = vector_count_positions(bin)

      assert @wire.read_u8(bin, @wire.vector_elem_pos(types_pos, 0, 1)) == 0
      assert @wire.read_u32(bin, @wire.vector_elem_pos(vals_pos, 0, 4)) == 0
    end

    test "an all-NONE vector round-trips" do
      bin = encode!([nil, nil])
      assert :ok = UVEdge.Bag.verify(bin)
      assert {:ok, %{items: [nil, nil]}} = UVEdge.Bag.decode(bin)
    end

    test "a verified NONE element never has its value slot dereferenced" do
      # Garbage in a NONE element's value slot must affect neither
      # verify nor decode — flatc's verifier leaves it uninspected.
      bin = encode!([nil, {:Sword, %{dmg: 1}}])
      {_types_pos, vals_pos} = vector_count_positions(bin)
      hostile = put_u32(bin, @wire.vector_elem_pos(vals_pos, 0, 4), 0xFFFF0000)

      assert :ok = safe_verify(hostile)
      assert {:ok, %{items: [nil, {:Sword, _}]}} = UVEdge.Bag.decode(hostile)
    end

    test "to_json / from_json carry NONE elements consistently" do
      bin = encode!([{:Sword, %{dmg: 3}}, nil])
      {:ok, decoded} = UVEdge.Bag.decode(bin)

      parsed = decoded |> UVEdge.Bag.to_json() |> JSON.decode!()
      assert parsed["items_type"] == ["Sword", "NONE"]
      assert parsed["items"] == [%{"dmg" => 3}, nil]

      assert {:ok, back} = UVEdge.Bag.from_json(UVEdge.Bag.to_json(decoded))
      assert [{:Sword, %{dmg: 3}}, nil] = back.items
    end

    test "empty vectors still work" do
      bin = encode!([])
      assert :ok = UVEdge.Bag.verify(bin)
      assert {:ok, %{items: []}} = UVEdge.Bag.decode(bin)
    end
  end

  describe "parallel-vector agreement — C4" do
    test "a shrunken types count fails verify with a tagged error" do
      bin = encode!([{:Sword, %{dmg: 1}}, {:Shield, %{guard: 2}}])
      {types_pos, _vals_pos} = vector_count_positions(bin)

      mutated = put_u32(bin, types_pos, 1)
      assert {:error, {:union_vector_count_mismatch, 1, 2}, [:items]} = safe_verify(mutated)
    end

    test "a shrunken values count fails verify with a tagged error" do
      bin = encode!([{:Sword, %{dmg: 1}}, {:Shield, %{guard: 2}}])
      {_types_pos, vals_pos} = vector_count_positions(bin)

      mutated = put_u32(bin, vals_pos, 1)
      assert {:error, {:union_vector_count_mismatch, 2, 1}, [:items]} = safe_verify(mutated)
    end

    test "an inflated values count fails verify without raising" do
      # Pre-fix, the verifier iterated the values count and read the
      # types vector past its verified region — raising instead of
      # returning {:error, _}.
      bin = encode!([{:Sword, %{dmg: 1}}, {:Shield, %{guard: 2}}])
      {types_pos, vals_pos} = vector_count_positions(bin)

      for pos <- [types_pos, vals_pos], count <- [3, 100, 0xFFFFFFF0] do
        mutated = put_u32(bin, pos, count)
        result = safe_verify(mutated)

        assert match?({:error, _, _}, result),
               "count #{count} at #{pos} produced #{inspect(result)}"
      end
    end

    test "one vector present without the other fails verify" do
      bin = encode!([{:Sword, %{dmg: 1}}])
      root_pos = @wire.root_table_pos(bin)
      vt_pos = root_pos - @wire.read_i32(bin, root_pos)

      no_types = put_u16(bin, vt_pos + @items_type_slot, 0)
      assert {:error, :union_vector_presence_mismatch, [:items]} = safe_verify(no_types)

      no_values = put_u16(bin, vt_pos + @items_value_slot, 0)
      assert {:error, :union_vector_presence_mismatch, [:items]} = safe_verify(no_values)
    end
  end
end
