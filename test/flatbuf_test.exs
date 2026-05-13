defmodule FlatbufTest do
  use ExUnit.Case, async: true
  doctest Flatbuf

  test "generate_from_path returns artifacts for a valid schema" do
    path = Path.expand("fixtures/monster.fbs", __DIR__)
    {:ok, artifacts} = Flatbuf.generate_from_path(path, wire_module: MyTest.Wire)
    modules = Enum.map(artifacts, &elem(&1, 0))

    assert MyTest.Wire in modules
    assert MyGame.Sample.Monster in modules
    assert MyGame.Sample.Vec3 in modules
    assert MyGame.Sample.Color in modules
    assert MyGame.Sample.Weapon in modules
  end
end
