defmodule Flatbuf.UnionRoundtripTest do
  @moduledoc """
  End-to-end test that union codegen works: build a buffer with a union
  field, decode it, verify each variant round-trips.

  Uses an inline schema so we're testing the full pipeline
  (parser → resolver → codegen → encode → decode) without depending on
  any upstream schema's particular wire layout.
  """

  use ExUnit.Case, async: false

  alias Flatbuf.Codegen
  alias Flatbuf.Schema.Resolver

  @schema """
  namespace UnionTest;

  table Sword { dmg: short; }
  table Bow { range: short; pull: short; }

  union Weapon { Sword, Bow }

  union Note { Sword, string }

  table Hero {
    name: string;
    primary: Weapon;
    note: Note;
  }

  root_type Hero;
  """

  setup_all do
    {:ok, schema} = Resolver.resolve_source(@schema)
    artifacts = Codegen.generate(schema, wire_module: Flatbuf.UnionRoundtripTest.Wire)

    for {_, src} <- artifacts do
      Code.compile_string(src)
    end

    :ok
  end

  test "Sword variant round-trips" do
    value = %{name: "Alice", primary: {:Sword, %{dmg: 7}}}
    {:ok, bin} = UnionTest.Hero.encode(value)
    {:ok, decoded} = UnionTest.Hero.decode(bin)

    assert decoded.name == "Alice"
    assert {:Sword, sword} = decoded.primary
    assert sword.dmg == 7
  end

  test "Bow variant round-trips" do
    value = %{name: "Bob", primary: {:Bow, %{range: 25, pull: 60}}}
    {:ok, bin} = UnionTest.Hero.encode(value)
    {:ok, decoded} = UnionTest.Hero.decode(bin)

    assert decoded.name == "Bob"
    assert {:Bow, bow} = decoded.primary
    assert bow.range == 25
    assert bow.pull == 60
  end

  test "absent union encodes as discriminator 0 and decodes to nil" do
    {:ok, bin} = UnionTest.Hero.encode(%{name: "Anonymous"})
    {:ok, decoded} = UnionTest.Hero.decode(bin)

    assert decoded.name == "Anonymous"
    assert decoded.primary == nil
    assert decoded.note == nil
  end

  test "string variant of a union round-trips" do
    value = %{name: "Ada", note: {:string, "first programmer"}}
    {:ok, bin} = UnionTest.Hero.encode(value)
    {:ok, decoded} = UnionTest.Hero.decode(bin)

    assert decoded.name == "Ada"
    assert {:string, "first programmer"} = decoded.note
  end
end
