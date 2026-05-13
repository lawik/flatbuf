defmodule Flatbuf.VerifierTest do
  @moduledoc """
  Exercises the generated `verify/1` against well-formed and malformed
  buffers.

  The verifier's job is to refuse cleanly — it must never let a bad
  offset propagate to the reader where it would crash with a binary_part
  badarg or trigger unbounded recursion. Each test here checks one
  way a buffer can be malformed.
  """

  use ExUnit.Case, async: false

  alias Flatbuf.Codegen
  alias Flatbuf.Schema.Resolver

  @schema """
  namespace VerifyT;

  table Inner { value: int; }
  table Outer {
    name: string;
    inner: Inner;
    inventory: [int];
  }

  root_type Outer;
  """

  setup_all do
    {:ok, schema} = Resolver.resolve_source(@schema)
    artifacts = Codegen.generate(schema, wire_module: Flatbuf.VerifierTest.Wire)

    for {_, src} <- artifacts do
      Code.compile_string(src)
    end

    :ok
  end

  test "a well-formed buffer verifies" do
    value = %{name: "ok", inner: %{value: 7}, inventory: [1, 2, 3]}
    {:ok, bin} = VerifyT.Outer.encode(value)
    assert :ok = VerifyT.Outer.verify(bin)
  end

  test "a buffer too small for the root uoffset is rejected" do
    assert {:error, _} = VerifyT.Outer.verify(<<>>)
    assert {:error, _} = VerifyT.Outer.verify(<<1, 2, 3>>)
  end

  test "truncating the buffer mid-table is caught" do
    {:ok, bin} = VerifyT.Outer.encode(%{name: "hello", inner: %{value: 7}})

    truncated = binary_part(bin, 0, byte_size(bin) - 4)
    assert {:error, _} = VerifyT.Outer.verify(truncated)
  end

  test "an obviously bogus root pointer is rejected" do
    # Root uoffset that points way past end-of-buffer.
    junk = <<0xFF, 0xFF, 0xFF, 0xFF, 0, 0, 0, 0>>
    assert {:error, _} = VerifyT.Outer.verify(junk)
  end

  test "an empty buffer fails verify" do
    assert {:error, _} = VerifyT.Outer.verify(<<>>)
  end
end
