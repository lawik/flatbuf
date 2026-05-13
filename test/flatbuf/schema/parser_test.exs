defmodule Flatbuf.Schema.ParserTest do
  use ExUnit.Case, async: true

  alias Flatbuf.Schema.Parser

  test "parses include, namespace, and root_type" do
    src = """
    include "other.fbs";
    namespace Foo.Bar;
    root_type Baz;
    """

    {:ok, decls} = Parser.parse(src)

    assert decls == [
             {:include, "other.fbs", 1},
             {:namespace, "Foo.Bar", 2},
             {:root_type, "Baz", 3}
           ]
  end

  test "parses a table with scalar, string, and vector fields" do
    {:ok, [{:table, body}]} =
      Parser.parse("table Foo { hp:short = 100; name:string; xs:[ubyte]; }")

    assert body.name == "Foo"
    [hp, name, xs] = body.fields
    assert hp.name == "hp"
    assert hp.type == {:scalar, :i16}
    assert hp.default == {:int, 100}
    assert name.type == :string
    assert xs.type == {:vector, {:scalar, :u8}}
  end

  test "parses a struct" do
    {:ok, [{:struct, body}]} = Parser.parse("struct V3 { x:float; y:float; z:float; }")
    assert body.name == "V3"
    assert Enum.map(body.fields, & &1.type) == [{:scalar, :f32}, {:scalar, :f32}, {:scalar, :f32}]
  end

  test "parses an enum with implicit increments" do
    {:ok, [{:enum, body}]} = Parser.parse("enum Color : byte { Red = 0, Green, Blue = 2 }")
    assert body.underlying_type == :i8
    assert Enum.map(body.variants, & &1.name) == ["Red", "Green", "Blue"]
    assert Enum.map(body.variants, & &1.value) == [0, nil, 2]
  end

  test "captures /// doc lines on the next decl" do
    src = """
    /// Top of the mountain.
    /// Also high.
    table Peak { height:int; }
    """

    {:ok, [{:table, body}]} = Parser.parse(src)
    assert body.docs == ["Top of the mountain.", "Also high."]
  end
end
