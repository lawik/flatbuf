defmodule Flatbuf.RoundtripTest do
  use ExUnit.Case, async: false

  alias Flatbuf.Codegen
  alias Flatbuf.Schema.Resolver

  @fixture Path.expand("../fixtures/monster.fbs", __DIR__)

  setup_all do
    {:ok, schema} = Resolver.resolve_path(@fixture)
    artifacts = Codegen.generate(schema, wire_module: Flatbuf.RoundtripTest.Wire)

    for {_, src} <- artifacts do
      Code.compile_string(src)
    end

    :ok
  end

  test "encode/decode round-trips a fully populated Monster" do
    value = %{
      pos: %{x: 1.0, y: 2.0, z: 3.0},
      mana: 200,
      hp: 80,
      name: "Orc",
      inventory: [1, 2, 3, 4],
      color: :Red,
      weapons: [
        %{name: "Sword", damage: 3},
        %{name: "Axe", damage: 5}
      ]
    }

    {:ok, bin} = MyGame.Sample.Monster.encode(value)
    assert is_binary(bin)
    assert byte_size(bin) > 0

    {:ok, decoded} = MyGame.Sample.Monster.decode(bin)

    assert decoded.mana == 200
    assert decoded.hp == 80
    assert decoded.name == "Orc"
    assert decoded.inventory == [1, 2, 3, 4]
    assert decoded.color == :Red
    assert decoded.pos.x == 1.0
    assert decoded.pos.y == 2.0
    assert decoded.pos.z == 3.0

    assert Enum.map(decoded.weapons, & &1.name) == ["Sword", "Axe"]
    assert Enum.map(decoded.weapons, & &1.damage) == [3, 5]
  end

  test "missing scalar fields fall back to their schema defaults" do
    {:ok, bin} = MyGame.Sample.Monster.encode(%{name: "Goblin"})
    {:ok, decoded} = MyGame.Sample.Monster.decode(bin)

    # No fields set ⇒ defaults from the schema.
    assert decoded.mana == 150
    assert decoded.hp == 100
    assert decoded.color == :Blue
    assert decoded.inventory == []
    assert decoded.weapons == []
    assert decoded.pos == nil
    assert decoded.name == "Goblin"
  end

  test "empty vector encodes and decodes to []" do
    {:ok, bin} = MyGame.Sample.Monster.encode(%{name: "X", inventory: []})
    {:ok, decoded} = MyGame.Sample.Monster.decode(bin)
    assert decoded.inventory == []
  end

  test "generated code references no Flatbuf.* runtime module" do
    {:ok, schema} = Resolver.resolve_path(@fixture)
    artifacts = Codegen.generate(schema, wire_module: SomeUser.Wire)

    bad_refs =
      for {_, src} <- artifacts,
          line <- String.split(src, "\n"),
          String.match?(
            line,
            ~r/\bFlatbuf\.(Wire|Codegen|Schema|Encoder|Decoder|Table|Struct|Enum)\b/
          ),
          do: line

    assert bad_refs == []
  end
end
