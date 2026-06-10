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

  test "non-UTF-8 source returns an error tuple instead of raising" do
    assert {:error, {:invalid_byte, 0xFF, 1}} = Parser.parse(<<0xFF>>)
    assert {:error, {:illegal_utf8_in_string, 1}} = Parser.parse(<<"include \"a", 0xFF, "\";">>)
  end

  describe "source locations" do
    test "table fields carry their line number" do
      src = """
      table Foo {
        hp:short;
        name:string;
      }
      """

      {:ok, [{:table, body}]} = Parser.parse(src)
      assert Enum.map(body.fields, & &1.line) == [2, 3]
    end

    test "struct fields carry their line number" do
      {:ok, [{:struct, body}]} = Parser.parse("struct V2 {\n x:float;\n y:float;\n}")
      assert Enum.map(body.fields, & &1.line) == [2, 3]
    end

    test "enum variants carry their line number" do
      {:ok, [{:enum, body}]} = Parser.parse("enum E : byte {\n A,\n B = 4\n}")
      assert Enum.map(body.variants, & &1.line) == [2, 3]
    end

    test "union variants carry their line number" do
      {:ok, [{:union, body}]} = Parser.parse("union U {\n A,\n alias: B,\n Some.C\n}")
      assert Enum.map(body.variants, & &1.line) == [2, 3, 4]
    end
  end

  test "parses .5 and 1. float defaults" do
    {:ok, [{:table, body}]} = Parser.parse("table T { a:float = .5; b:float = 1.; }")
    assert Enum.map(body.fields, & &1.default) == [{:float, 0.5}, {:float, 1.0}]
  end

  test "fixed-size array type in the CST" do
    {:ok, [{:struct, body}]} = Parser.parse("struct S { a:[int:3]; }")
    assert [%{type: {:array, {:scalar, :i32}, 3}}] = body.fields
  end

  describe "union underlying types" do
    test "scalar underlying type and explicit discriminator values" do
      {:ok, [{:union, body}]} = Parser.parse("union ABC : int { A = 555, B = 666, C = 777 }")
      assert body.underlying_type == {:scalar, :i32}
      assert Enum.map(body.variants, & &1.name) == ["A", "B", "C"]
      assert Enum.map(body.variants, & &1.value) == [555, 666, 777]
    end

    test "no underlying type stays nil; implicit values stay nil" do
      {:ok, [{:union, body}]} = Parser.parse("union U { A, B }")
      assert body.underlying_type == nil
      assert Enum.map(body.variants, & &1.value) == [nil, nil]
    end

    test "a named (enum) underlying type is recorded as a name ref" do
      {:ok, [{:union, body}]} = Parser.parse("union U : Some.Enum { A }")
      assert body.underlying_type == {:name, "Some.Enum"}
    end

    test "aliased and dotted variants take explicit values too" do
      {:ok, [{:union, body}]} = Parser.parse("union U { alias: B = 5, Some.C = 9 }")
      assert Enum.map(body.variants, & &1.name) == ["alias", "Some_C"]
      assert Enum.map(body.variants, & &1.value) == [5, 9]
    end

    test "negative explicit values parse (range is the resolver's call)" do
      {:ok, [{:union, body}]} = Parser.parse("union U : int { A = -5 }")
      assert Enum.map(body.variants, & &1.value) == [-5]
    end

    test "a non-integer variant value is a parse error" do
      assert {:error, {:bad_union_value, {:float, 1.5}}} = Parser.parse("union U { A = 1.5 }")
    end
  end
end
