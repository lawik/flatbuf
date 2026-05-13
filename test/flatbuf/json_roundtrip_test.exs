defmodule Flatbuf.JsonRoundtripTest do
  @moduledoc """
  End-to-end JSON round-trip: build a buffer, generate JSON from the
  struct, parse the JSON back, decode-as-struct, compare.

  Exercises every codegen layer: tables, structs, enums, unions, vectors
  of tables. Uses Elixir's built-in JSON module (no extra dep).
  """

  use ExUnit.Case, async: false

  alias Flatbuf.Test.CodegenCompiler

  @schema """
  namespace Json;

  enum Color : byte { Red = 0, Green, Blue }

  struct Vec3 { x: float; y: float; z: float; }

  table Sword { dmg: short; }
  table Bow { range: short; }
  union Weapon { Sword, Bow }

  table Hero {
    name: string;
    hp: short = 100;
    pos: Vec3;
    color: Color = Blue;
    inventory: [ubyte];
    primary: Weapon;
  }

  root_type Hero;
  """

  # Compile generated modules at test-file compile time, not in
  # setup_all — that way references like `Json.Hero.encode/1` inside
  # `test do ... end` blocks resolve cleanly instead of emitting
  # `module is not available` warnings.
  CodegenCompiler.compile_source!(@schema, wire_module: Flatbuf.JsonRoundtripTest.Wire)

  test "to_json/from_json round-trips a full Hero" do
    value = %{
      name: "Ada",
      hp: 95,
      pos: %{x: 1.0, y: 2.0, z: 3.0},
      color: :Red,
      inventory: [1, 2, 3],
      primary: {:Sword, %{dmg: 7}}
    }

    json = Json.Hero.to_json(value)
    assert is_binary(json)
    {:ok, parsed} = JSON.decode(json)

    # Confirm the JSON shape matches flatc's conventions.
    assert parsed["name"] == "Ada"
    assert parsed["hp"] == 95
    assert parsed["color"] == "Red"
    assert parsed["inventory"] == [1, 2, 3]
    assert parsed["pos"] == %{"x" => 1.0, "y" => 2.0, "z" => 3.0}
    assert parsed["primary_type"] == "Sword"
    assert parsed["primary"] == %{"dmg" => 7}

    # And it round-trips back through from_json.
    {:ok, decoded} = Json.Hero.from_json(json)
    assert decoded.name == "Ada"
    assert decoded.hp == 95
    assert decoded.color == :Red
    assert decoded.inventory == [1, 2, 3]
    assert decoded.pos.x == 1.0
    assert {:Sword, sword} = decoded.primary
    assert sword.dmg == 7
  end

  test "nil/absent fields drop out of the JSON output" do
    json = Json.Hero.to_json(%{name: "Goblin"})
    {:ok, parsed} = JSON.decode(json)

    assert parsed["name"] == "Goblin"
    # No pos, no inventory, no primary.
    refute Map.has_key?(parsed, "pos")
    refute Map.has_key?(parsed, "primary")
    refute Map.has_key?(parsed, "primary_type")
  end

  test "wire and JSON paths agree on the same value" do
    value = %{
      name: "Bob",
      hp: 50,
      color: :Green,
      pos: %{x: 0.0, y: 1.0, z: 2.0},
      inventory: [10, 20],
      primary: {:Bow, %{range: 30}}
    }

    {:ok, bin} = Json.Hero.encode(value)
    {:ok, from_wire} = Json.Hero.decode(bin)

    json = Json.Hero.to_json(value)
    {:ok, from_json} = Json.Hero.from_json(json)

    assert from_wire.name == from_json.name
    assert from_wire.hp == from_json.hp
    assert from_wire.color == from_json.color
    assert from_wire.inventory == from_json.inventory
    assert from_wire.pos.x == from_json.pos.x
    assert from_wire.pos.y == from_json.pos.y
    assert from_wire.pos.z == from_json.pos.z
    assert from_wire.primary == from_json.primary
  end
end
