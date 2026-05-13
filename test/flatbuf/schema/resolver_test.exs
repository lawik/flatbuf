defmodule Flatbuf.Schema.ResolverTest do
  use ExUnit.Case, async: true

  alias Flatbuf.Schema.Enum, as: SchemaEnum
  alias Flatbuf.Schema.Field
  alias Flatbuf.Schema.Resolver
  alias Flatbuf.Schema.Struct, as: SchemaStruct
  alias Flatbuf.Schema.Table

  test "applies namespace to subsequent declarations" do
    src = """
    namespace Foo.Bar;
    table T { x:int; }
    """

    {:ok, schema} = Resolver.resolve_source(src)
    assert Map.has_key?(schema.types, "Foo.Bar.T")
    %Table{namespace: "Foo.Bar", short_name: "T"} = schema.types["Foo.Bar.T"]
  end

  test "assigns vtable slots 4, 6, 8 in declaration order" do
    {:ok, schema} = Resolver.resolve_source("table T { a:int; b:int; c:int; }")
    %Table{fields: [a, b, c]} = schema.types["T"]
    assert {a.vtable_slot, b.vtable_slot, c.vtable_slot} == {4, 6, 8}
  end

  test "computes struct layout with float alignment" do
    {:ok, schema} = Resolver.resolve_source("struct V3 { x:float; y:float; z:float; }")
    %SchemaStruct{size: 12, align: 4, layout: layout} = schema.types["V3"]

    assert Enum.map(layout, & &1.offset) == [0, 4, 8]
    assert Enum.map(layout, & &1.size) == [4, 4, 4]
  end

  test "computes implicit and explicit enum values" do
    {:ok, schema} = Resolver.resolve_source("enum E : byte { A, B = 5, C }")
    %SchemaEnum{variants: variants} = schema.types["E"]
    assert variants == [{:A, 0}, {:B, 5}, {:C, 6}]
  end

  test "resolves user type references via the namespace" do
    src = """
    namespace N;
    struct V3 { x:float; y:float; z:float; }
    table T { pos: V3; }
    """

    {:ok, schema} = Resolver.resolve_source(src)
    %Table{fields: [%Field{type: {:struct, "N.V3"}}]} = schema.types["N.T"]
  end

  test "errors on a struct field that isn't a scalar/enum/struct" do
    src = """
    struct Bad { s: string; }
    """

    assert {:error, {:bad_struct_field_type, _, _, _}} = Resolver.resolve_source(src)
  end
end
