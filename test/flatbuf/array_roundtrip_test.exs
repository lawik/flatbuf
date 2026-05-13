defmodule Flatbuf.ArrayRoundtripTest do
  @moduledoc """
  End-to-end test for fixed-size arrays in struct fields.

  Exercises the parse → resolve → codegen → encode → decode pipeline with
  a struct that mixes scalar fields, scalar arrays, and a struct-typed
  array (nested fixed-size arrays).
  """

  use ExUnit.Case, async: false

  alias Flatbuf.Codegen
  alias Flatbuf.Schema.Resolver

  @schema """
  namespace ArrayTest;

  struct Inner {
    a: int;
    b: int;
  }

  struct Outer {
    scalars: [int : 3];
    inners: [Inner : 2];
  }

  table Holder {
    o: Outer;
  }

  root_type Holder;
  """

  setup_all do
    {:ok, schema} = Resolver.resolve_source(@schema)
    artifacts = Codegen.generate(schema, wire_module: Flatbuf.ArrayRoundtripTest.Wire)

    for {_, src} <- artifacts do
      Code.compile_string(src)
    end

    :ok
  end

  test "fixed-size scalar array round-trips" do
    value = %{o: %{scalars: [10, 20, 30], inners: [%{a: 1, b: 2}, %{a: 3, b: 4}]}}
    {:ok, bin} = ArrayTest.Holder.encode(value)
    {:ok, decoded} = ArrayTest.Holder.decode(bin)

    assert decoded.o.scalars == [10, 20, 30]
    assert Enum.map(decoded.o.inners, &{&1.a, &1.b}) == [{1, 2}, {3, 4}]
  end

  test "missing elements are zero-padded to the declared size" do
    {:ok, bin} = ArrayTest.Holder.encode(%{o: %{scalars: [42], inners: []}})
    {:ok, decoded} = ArrayTest.Holder.decode(bin)

    assert decoded.o.scalars == [42, 0, 0]
    assert Enum.map(decoded.o.inners, &{&1.a, &1.b}) == [{0, 0}, {0, 0}]
  end
end
