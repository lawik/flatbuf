defmodule Flatbuf.VerifierPathTest do
  @moduledoc """
  Pins the verifier's error-path contract and the configurable
  recursion depth limit.

  Every verify failure is `{:error, reason, path}` where `path` is a
  root-first list of field atoms, vector indices (integers), and union
  variant atoms locating the failing field. The path starts at the root
  table's first field — the root table contributes no leading segment —
  and is `[]` for failures detected before any field is reached.

  The depth limit defaults to 64 nested tables and is configurable per
  call via `verify(buf, max_depth: n)`.
  """

  use ExUnit.Case, async: false

  alias Flatbuf.Test.CodegenCompiler

  # -----------------------------------------------------------------------
  # Error paths — root-first field atoms + vector indices + union variants
  # -----------------------------------------------------------------------

  @path_schema """
  namespace VerifyPath;

  table Leaf { tag: string; }
  table Node {
    label: string;
    leaves: [Leaf];
  }

  root_type Node;
  """

  @path_wire Flatbuf.VerifierPathTest.WirePath

  CodegenCompiler.compile_source!(@path_schema, wire_module: @path_wire)

  defp put_u32(bin, pos, v) do
    <<head::binary-size(pos), _::little-32, tail::binary>> = bin
    <<head::binary, v::little-32, tail::binary>>
  end

  # Corrupt the length prefix of `leaves[index].tag` so the string
  # claims to extend far past the buffer.
  defp corrupt_leaf_tag(bin, index) do
    root = @path_wire.root_table_pos(bin)
    leaves_o = @path_wire.read_vtable_field(bin, root, 6)
    vec = @path_wire.follow_uoffset(bin, root + leaves_o)
    leaf = @path_wire.follow_uoffset(bin, @path_wire.vector_elem_pos(vec, index, 4))
    tag_o = @path_wire.read_vtable_field(bin, leaf, 4)
    str = @path_wire.follow_uoffset(bin, leaf + tag_o)
    put_u32(bin, str, 0xFFFF_FFF0)
  end

  defp path_seed do
    {:ok, bin} =
      VerifyPath.Node.encode(%{
        label: "n",
        leaves: [%{tag: "a"}, %{tag: "bb"}, %{tag: "ccc"}, %{tag: "deep"}]
      })

    bin
  end

  test "a corrupted string deep inside table -> vector -> table yields the full path" do
    corrupted = corrupt_leaf_tag(path_seed(), 3)

    assert {:error, {:out_of_bounds, _, _}, [:leaves, 3, :tag]} =
             VerifyPath.Node.verify(corrupted)
  end

  test "the vector index in the path tracks the failing element" do
    corrupted = corrupt_leaf_tag(path_seed(), 1)

    assert {:error, {:out_of_bounds, _, _}, [:leaves, 1, :tag]} =
             VerifyPath.Node.verify(corrupted)
  end

  test "verify_size_prefixed reports the same reason and path as verify on the body" do
    corrupted = corrupt_leaf_tag(path_seed(), 3)
    prefixed = <<byte_size(corrupted)::little-32, corrupted::binary>>

    body_result = VerifyPath.Node.verify(corrupted)
    assert {:error, {:out_of_bounds, _, _}, [:leaves, 3, :tag]} = body_result
    assert body_result == VerifyPath.Node.verify_size_prefixed(prefixed)
  end

  @union_path_schema """
  namespace VerifyUPath;

  table Sub { txt: string; }

  union U { Sub }

  table Holder { u: U; }

  root_type Holder;
  """

  @union_path_wire Flatbuf.VerifierPathTest.WireUPath

  CodegenCompiler.compile_source!(@union_path_schema, wire_module: @union_path_wire)

  test "a corrupted string inside a union variant yields field, variant, and field path" do
    {:ok, bin} = VerifyUPath.Holder.encode(%{u: {:Sub, %{txt: "hello"}}})
    assert :ok = VerifyUPath.Holder.verify(bin)

    # Walk to the variant table's `txt` string and blow up its length.
    root = @union_path_wire.root_table_pos(bin)
    value_o = @union_path_wire.read_vtable_field(bin, root, 6)
    sub = @union_path_wire.follow_uoffset(bin, root + value_o)
    txt_o = @union_path_wire.read_vtable_field(bin, sub, 4)
    str = @union_path_wire.follow_uoffset(bin, sub + txt_o)
    corrupted = put_u32(bin, str, 0xFFFF_FFF0)

    assert {:error, {:out_of_bounds, _, _}, [:u, :Sub, :txt]} =
             VerifyUPath.Holder.verify(corrupted)
  end

  # -----------------------------------------------------------------------
  # Configurable recursion depth — `max_depth:` (default 64)
  # -----------------------------------------------------------------------

  @depth_schema """
  namespace VerifyDepth;

  table N {
    child: N;
    payload: int;
  }

  root_type N;
  """

  CodegenCompiler.compile_source!(@depth_schema, wire_module: Flatbuf.VerifierPathTest.WireDepth)

  # A chain of `n` nested tables (the root counts as one).
  defp nested(1), do: %{payload: 1}
  defp nested(n), do: %{child: nested(n - 1), payload: n}

  test "max_depth: 1 rejects a nested-table buffer that the default accepts" do
    {:ok, bin} = VerifyDepth.N.encode(nested(2))

    assert :ok = VerifyDepth.N.verify(bin)
    assert :ok = VerifyDepth.N.verify(bin, max_depth: 64)
    assert :ok = VerifyDepth.N.verify(bin, max_depth: 2)
    assert {:error, :depth_exceeded, [:child]} = VerifyDepth.N.verify(bin, max_depth: 1)
  end

  test "the default depth limit is 64 nested tables" do
    {:ok, at_limit} = VerifyDepth.N.encode(nested(64))
    assert :ok = VerifyDepth.N.verify(at_limit)

    {:ok, over_limit} = VerifyDepth.N.encode(nested(65))
    assert {:error, :depth_exceeded, path} = VerifyDepth.N.verify(over_limit)
    assert length(path) == 64
    assert Enum.all?(path, &(&1 == :child))

    # Explicit max_depth: 64 behaves exactly like the default…
    assert {:error, :depth_exceeded, ^path} = VerifyDepth.N.verify(over_limit, max_depth: 64)
    # …and raising the limit accepts the same buffer.
    assert :ok = VerifyDepth.N.verify(over_limit, max_depth: 65)
  end

  test "size-prefixed verification honors max_depth the same way" do
    {:ok, bin} = VerifyDepth.N.encode_size_prefixed(nested(2))

    assert :ok = VerifyDepth.N.verify_size_prefixed(bin)

    assert {:error, :depth_exceeded, [:child]} =
             VerifyDepth.N.verify_size_prefixed(bin, max_depth: 1)
  end
end
