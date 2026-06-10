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

  describe "duplicate names" do
    test "duplicate table field names error with name and line" do
      assert {:error, {:duplicate_field, "T", "a", 3}} =
               Resolver.resolve_source("table T {\n a:int;\n a:short;\n}")
    end

    test "duplicate struct field names error" do
      assert {:error, {:duplicate_field, "S", "x", _}} =
               Resolver.resolve_source("struct S { x:int; x:int; }")
    end

    test "duplicate enum variant names error" do
      assert {:error, {:duplicate_enum_variant, "E", "A", _}} =
               Resolver.resolve_source("enum E : byte { A, A }")
    end

    test "duplicate union variant names error" do
      assert {:error, {:duplicate_union_variant, "U", "A", _}} =
               Resolver.resolve_source("table A { x:int; } union U { A, A }")
    end

    test "the same union variant type under distinct aliases is fine (flatc accepts)" do
      assert {:ok, _} =
               Resolver.resolve_source("table A { x:int; } union U { first: A, second: A }")
    end
  end

  describe "explicit field ids" do
    test "valid contiguous ids reorder the vtable slots" do
      {:ok, schema} = Resolver.resolve_source("table T { a:int (id:1); b:int (id:0); }")
      %Table{fields: [a, b]} = schema.types["T"]
      assert {a.vtable_slot, b.vtable_slot} == {6, 4}
    end

    test "numeric-string ids are coerced (flatc accepts (id: \"0\"))" do
      {:ok, schema} = Resolver.resolve_source(~S|table T { a:int (id: "0"); }|)
      %Table{fields: [a]} = schema.types["T"]
      assert a.vtable_slot == 4
    end

    test "the same id twice is an error" do
      assert {:error, {:duplicate_field_id, "T", "b", 0, _}} =
               Resolver.resolve_source("table T { a:int (id:0); b:int (id:0); }")
    end

    test "negative ids are an error" do
      assert {:error, {:bad_field_id, "T", "a", -1, _}} =
               Resolver.resolve_source("table T { a:int (id:-1); }")
    end

    test "ids above the voffset range are an error" do
      assert {:error, {:bad_field_id, "T", "a", 65_536, _}} =
               Resolver.resolve_source("table T { a:int (id:65536); b:int (id:0); }")
    end

    test "non-numeric ids are an error" do
      assert {:error, {:bad_field_id, "T", "a", "x", _}} =
               Resolver.resolve_source(~S|table T { a:int (id: "x"); }|)

      assert {:error, {:bad_field_id, "T", "a", 1.5, _}} =
               Resolver.resolve_source("table T { a:int (id: 1.5); }")
    end

    test "ids must start at 0" do
      assert {:error, {:nonconsecutive_field_ids, "T", "a", 1, _}} =
               Resolver.resolve_source("table T { a:int (id:1); b:int (id:2); }")
    end

    test "gaps in ids are an error" do
      assert {:error, {:nonconsecutive_field_ids, "T", "b", 2, _}} =
               Resolver.resolve_source("table T { a:int (id:0); b:int (id:2); }")
    end

    test "either all fields have ids or none do (flatc's all-or-none rule)" do
      assert {:error, {:missing_field_id, "T", "b", _}} =
               Resolver.resolve_source("table T { a:int (id:0); b:int; }")
    end

    test "a union field consumes two ids; the explicit id names the value slot" do
      src = "table A { x:int; } union U { A } table T { a:int (id:0); u:U (id:2); }"
      {:ok, schema} = Resolver.resolve_source(src)
      %Table{fields: [a, u]} = schema.types["T"]
      # value slot 4 + 2*2 = 8; the discriminator implicitly sits at 6.
      assert {a.vtable_slot, u.vtable_slot} == {4, 8}
    end

    test "a union field id that ignores the hidden type slot is an error" do
      src = "table A { x:int; } union U { A } table T { a:int (id:0); u:U (id:1); }"
      assert {:error, {:duplicate_field_id, "T", _, _, _}} = Resolver.resolve_source(src)
    end

    test "a union field cannot take id 0 (its type slot would be -1)" do
      src = "table A { x:int; } union U { A } table T { u:U (id:0); }"
      assert {:error, {:bad_union_field_id, "T", "u", 0, _}} = Resolver.resolve_source(src)
    end

    test "a lone union field with id 1 is valid" do
      src = "table A { x:int; } union U { A } table T { u:U (id:1); }"
      {:ok, schema} = Resolver.resolve_source(src)
      %Table{fields: [u]} = schema.types["T"]
      assert u.vtable_slot == 6
    end

    test "a vector-of-union field also consumes two ids" do
      src = "table A { x:int; } union U { A } table T { a:int (id:0); u:[U] (id:2); }"
      assert {:ok, _} = Resolver.resolve_source(src)

      bad = "table A { x:int; } union U { A } table T { a:int (id:0); u:[U] (id:1); }"
      assert {:error, {:duplicate_field_id, "T", _, _, _}} = Resolver.resolve_source(bad)
    end
  end

  describe "default value typing" do
    test "integer defaults must fit the scalar type" do
      assert {:error, {:default_out_of_range, "T", "a", 300, :u8, 1}} =
               Resolver.resolve_source("table T { a:ubyte = 300; }")

      assert {:error, {:default_out_of_range, "T", "a", -1, :u8, _}} =
               Resolver.resolve_source("table T { a:ubyte = -1; }")

      assert {:error, {:default_out_of_range, "T", "a", 128, :i8, _}} =
               Resolver.resolve_source("table T { a:byte = 128; }")

      assert {:ok, _} = Resolver.resolve_source("table T { a:ubyte = 255; b:byte = -128; }")
    end

    test "string defaults on integer scalars parse as numbers (flatc quirk)" do
      {:ok, schema} = Resolver.resolve_source(~S|table T { a:int = "5"; }|)
      %Table{fields: [a]} = schema.types["T"]
      assert a.default == {:int, 5}

      assert {:error, {:invalid_default, "T", "a", {:string, "hi"}, _}} =
               Resolver.resolve_source(~S|table T { a:int = "hi"; }|)

      assert {:error, {:default_out_of_range, "T", "a", 300, :u8, _}} =
               Resolver.resolve_source(~S|table T { a:ubyte = "300"; }|)
    end

    test "float literals are not valid integer defaults (flatc rejects 1.0 on int)" do
      assert {:error, {:invalid_default, "T", "a", {:float, 1.0}, _}} =
               Resolver.resolve_source("table T { a:int = 1.0; }")
    end

    test "bool literals are not valid numeric defaults" do
      assert {:error, {:invalid_default, "T", "a", {:bool, true}, _}} =
               Resolver.resolve_source("table T { a:int = true; }")

      assert {:error, {:invalid_default, "T", "a", {:bool, true}, _}} =
               Resolver.resolve_source("table T { a:float = true; }")
    end

    test "float fields take int or float defaults, including nan/inf" do
      {:ok, schema} =
        Resolver.resolve_source("table T { a:float = 1; b:double = .5; c:float = nan; }")

      %Table{fields: [a, b, c]} = schema.types["T"]
      assert a.default == {:int, 1}
      assert b.default == {:float, 0.5}
      assert c.default == {:float, :nan}
    end

    test "bool fields accept true/false/null and numeric forms (flatc accepts bool = 1)" do
      {:ok, schema} =
        Resolver.resolve_source("table T { a:bool = true; b:bool = 1; c:bool = null; }")

      %Table{fields: [a, b, c]} = schema.types["T"]
      assert a.default == {:bool, true}
      assert b.default == {:bool, true}
      assert c.default == :null

      assert {:error, {:invalid_default, "T", "a", {:string, "junk"}, _}} =
               Resolver.resolve_source(~S|table T { a:bool = "junk"; }|)
    end

    test "enum defaults by identifier must name an existing variant" do
      {:ok, schema} =
        Resolver.resolve_source("enum E : byte { A, B } table T { e:E = B; }")

      %Table{fields: [e]} = schema.types["T"]
      assert e.default == {:ident, "B"}

      assert {:error, {:unknown_enum_default, "T", "e", "C", _}} =
               Resolver.resolve_source("enum E : byte { A, B } table T { e:E = C; }")
    end

    test "integer enum defaults must be a member value" do
      assert {:ok, _} = Resolver.resolve_source("enum E : byte { A, B } table T { e:E = 1; }")

      assert {:error, {:enum_default_not_member, "T", "e", 9, _}} =
               Resolver.resolve_source("enum E : byte { A, B } table T { e:E = 9; }")
    end

    test "bit_flags enum defaults may be any in-range flag combination" do
      assert {:ok, _} =
               Resolver.resolve_source("enum E : ubyte (bit_flags) { A, B } table T { e:E = 3; }")

      assert {:error, {:default_out_of_range, "T", "e", 256, :u8, _}} =
               Resolver.resolve_source(
                 "enum E : ubyte (bit_flags) { A, B } table T { e:E = 256; }"
               )
    end

    test "enum defaults as strings resolve to variants (flatc accepts \"B\")" do
      {:ok, schema} =
        Resolver.resolve_source(~S|enum E : byte { A, B } table T { e:E = "B"; }|)

      %Table{fields: [e]} = schema.types["T"]
      assert e.default == {:ident, "B"}
    end

    test "= null is allowed on scalars and enums only" do
      assert {:ok, _} =
               Resolver.resolve_source("enum E:byte { A } table T { a:int = null; e:E = null; }")

      assert {:error, {:invalid_default, "T", "s", :null, _}} =
               Resolver.resolve_source("table T { s:string = null; }")
    end

    test "string fields take string-literal defaults (flatc accepts them)" do
      assert {:ok, _} = Resolver.resolve_source(~S|table T { s:string = "hi"; t:string = ""; }|)

      assert {:error, {:invalid_default, "T", "s", {:int, 5}, _}} =
               Resolver.resolve_source("table T { s:string = 5; }")
    end

    test "vector fields take only the empty [] default" do
      assert {:ok, _} = Resolver.resolve_source("table T { v:[int] = []; }")

      assert {:error, {:invalid_default, "T", "v", {:array, [{:int, 1}]}, _}} =
               Resolver.resolve_source("table T { v:[int] = [1]; }")

      assert {:error, {:invalid_default, "T", "v", :null, _}} =
               Resolver.resolve_source("table T { v:[int] = null; }")
    end

    test "table, struct, and union fields take no default at all" do
      assert {:error, {:invalid_default, "T", "a", {:int, 0}, _}} =
               Resolver.resolve_source("table A { x:int; } table T { a:A = 0; }")

      assert {:error, {:invalid_default, "T", "s", :null, _}} =
               Resolver.resolve_source("struct S { x:int; } table T { s:S = null; }")

      assert {:error, {:invalid_default, "T", "u", {:int, 0}, _}} =
               Resolver.resolve_source("table A { x:int; } union U { A } table T { u:U = 0; }")
    end
  end

  describe "enum value validation" do
    test "explicit values must fit the underlying type" do
      assert {:error, {:enum_value_out_of_range, "E", "A", 300, _}} =
               Resolver.resolve_source("enum E : byte { A = 300 }")

      assert {:error, {:enum_value_out_of_range, "E", "A", -1, _}} =
               Resolver.resolve_source("enum E : ubyte { A = -1 }")
    end

    test "implicit increments must fit too" do
      assert {:error, {:enum_value_out_of_range, "E", "B", 128, _}} =
               Resolver.resolve_source("enum E : byte { A = 127, B }")
    end

    test "values must be unique" do
      assert {:error, {:duplicate_enum_value, "E", "B", 1, _}} =
               Resolver.resolve_source("enum E : byte { A = 1, B = 1 }")
    end

    test "non-ascending order is allowed (flatc 25.x accepts it)" do
      assert {:ok, _} = Resolver.resolve_source("enum E : byte { A = 2, B = 1 }")
    end

    test "bit_flags positions must shift to a representable value" do
      assert {:error, {:bit_flag_out_of_range, "E", "A", 9, _}} =
               Resolver.resolve_source("enum E : ubyte (bit_flags) { A = 9 }")

      # 1 <<< 7 = 128 fits ubyte but not byte — flatc draws the same line.
      assert {:ok, _} = Resolver.resolve_source("enum E : ubyte (bit_flags) { A = 7 }")

      assert {:error, {:bit_flag_out_of_range, "E", "A", 7, _}} =
               Resolver.resolve_source("enum E : byte (bit_flags) { A = 7 }")
    end

    test "underlying type must be integral" do
      assert {:error, {:bad_enum_underlying, "E", :f32}} =
               Resolver.resolve_source("enum E : float { A }")

      assert {:error, {:bad_enum_underlying, "E", :bool}} =
               Resolver.resolve_source("enum E : bool { A }")
    end

    test "empty enums and unions are accepted (flatc accepts both)" do
      assert {:ok, _} = Resolver.resolve_source("enum E : byte {}")
      assert {:ok, _} = Resolver.resolve_source("union U {}")
    end
  end

  describe "attribute placement" do
    test "required on scalar or enum fields is an error" do
      assert {:error, {:required_on_scalar, "T", "a", _}} =
               Resolver.resolve_source("table T { a:int (required); }")

      assert {:error, {:required_on_scalar, "T", "e", _}} =
               Resolver.resolve_source("enum E:byte { A } table T { e:E (required); }")
    end

    test "required on offset-typed fields is fine" do
      src = """
      struct S { x:int; }
      table A { x:int; }
      union U { A }
      table T { s:string (required); v:[int] (required); st:S (required); u:U (required); }
      """

      assert {:ok, _} = Resolver.resolve_source(src)
    end

    test "force_align must be a power of two within [natural_align, 32]" do
      assert {:error, {:bad_force_align, "S", 3, 4}} =
               Resolver.resolve_source("struct S (force_align: 3) { x:int; }")

      assert {:error, {:bad_force_align, "S", 2, 4}} =
               Resolver.resolve_source("struct S (force_align: 2) { x:int; }")

      assert {:error, {:bad_force_align, "S", 64, 4}} =
               Resolver.resolve_source("struct S (force_align: 64) { x:int; }")

      assert {:ok, schema} = Resolver.resolve_source("struct S (force_align: 16) { x:int; }")
      assert %SchemaStruct{align: 16, size: 16} = schema.types["S"]
    end

    test "force_align accepts numeric strings (flatc parses them)" do
      {:ok, schema} = Resolver.resolve_source(~S|struct S (force_align: "8") { x:int; }|)
      assert %SchemaStruct{align: 8} = schema.types["S"]

      assert {:error, {:bad_force_align, "S", "abc", _}} =
               Resolver.resolve_source(~S|struct S (force_align: "abc") { x:int; }|)
    end

    test "force_align on tables is ignored, as flatc does" do
      assert {:ok, _} = Resolver.resolve_source("table T (force_align: 3) { x:int; }")
    end
  end

  describe "fixed-size arrays" do
    test "are only legal in struct fields" do
      assert {:ok, _} = Resolver.resolve_source("struct S { a:[int:3]; }")

      assert {:error, {:array_in_table, "T", "a", _}} =
               Resolver.resolve_source("table T { a:[int:3]; }")

      assert {:error, {:array_in_table, "T", "a", _}} =
               Resolver.resolve_source("table T { a:[[int:3]]; }")
    end

    test "length must be in 1..65535" do
      assert {:error, {:bad_array_length, "S", "a", 0, _}} =
               Resolver.resolve_source("struct S { a:[int:0]; }")

      assert {:error, {:bad_array_length, "S", "a", 65_536, _}} =
               Resolver.resolve_source("struct S { a:[int:65536]; }")

      assert {:ok, _} = Resolver.resolve_source("struct S { a:[int:65535]; }")
    end
  end

  describe "union limits" do
    test "more than 255 variants overflow the u8 discriminator" do
      tables = Enum.map_join(1..256, "\n", &"table T#{&1} { x:int; }")
      variants = Enum.map_join(1..256, ", ", &"T#{&1}")

      assert {:error, {:too_many_union_variants, "U", 256}} =
               Resolver.resolve_source(tables <> "\nunion U { " <> variants <> " }")
    end

    test "exactly 255 variants is fine" do
      tables = Enum.map_join(1..255, "\n", &"table T#{&1} { x:int; }")
      variants = Enum.map_join(1..255, ", ", &"T#{&1}")

      assert {:ok, _} = Resolver.resolve_source(tables <> "\nunion U { " <> variants <> " }")
    end
  end

  describe "structs" do
    test "field defaults are an error" do
      assert {:error, {:default_on_struct_field, "S", "x", _}} =
               Resolver.resolve_source("struct S { x:int = 5; }")
    end

    test "empty structs are an error (flatc: size 0 structs not allowed)" do
      assert {:error, {:empty_struct, "S", _}} = Resolver.resolve_source("struct S {}")
    end
  end

  test "nested vectors are an error (flatc: wrap in a table first)" do
    assert {:error, {:nested_vector, "T", "v", _}} =
             Resolver.resolve_source("table T { v:[[int]]; }")
  end

  describe "root_type resolution" do
    test "qualifies with the namespace in effect at the declaration" do
      {:ok, schema} = Resolver.resolve_source("namespace Foo; table G { x:int; } root_type G;")
      assert schema.root_type == "Foo.G"
    end

    test "falls back to the name as written (flatc accepts a pre-namespace global)" do
      {:ok, schema} = Resolver.resolve_source("table G { x:int; } namespace Foo; root_type G;")
      assert schema.root_type == "G"
    end

    test "the name as written wins over the namespace-qualified candidate" do
      src = "table G { x:int; } namespace Foo; table G { y:int; } root_type G;"
      {:ok, schema} = Resolver.resolve_source(src)
      assert schema.root_type == "G"
    end

    test "no parent-namespace walk-up, matching flatc" do
      src = "namespace Foo; table G { x:int; } namespace Foo.Bar; root_type G;"
      assert {:error, {:unknown_root_type, "G", _}} = Resolver.resolve_source(src)
    end

    test "unknown root types error with the name" do
      assert {:error, {:unknown_root_type, "H", 1}} =
               Resolver.resolve_source("table G { x:int; } root_type H;")
    end
  end

  describe "include errors" do
    @tag :tmp_dir
    test "name the including file and the searched paths", %{tmp_dir: tmp} do
      includer = Path.join(tmp, "main.fbs")
      File.write!(includer, ~S|include "missing.fbs";| <> "\ntable T { x:int; }\n")

      extra = Path.join(tmp, "extra")
      File.mkdir_p!(extra)

      assert {:error, {:include_not_found, "missing.fbs", from, searched}} =
               Resolver.resolve_path(includer, include_paths: [extra])

      assert String.ends_with?(from, "main.fbs")
      assert length(searched) == 2
      assert Enum.all?(searched, &String.ends_with?(&1, "missing.fbs"))
    end

    @tag :tmp_dir
    test "includes resolve through include_paths", %{tmp_dir: tmp} do
      lib = Path.join(tmp, "lib")
      File.mkdir_p!(lib)
      File.write!(Path.join(lib, "dep.fbs"), "table D { x:int; }\n")

      main = Path.join(tmp, "main.fbs")
      File.write!(main, ~S|include "dep.fbs";| <> "\ntable T { d:D; }\n")

      assert {:ok, schema} = Resolver.resolve_path(main, include_paths: [lib])
      assert Map.has_key?(schema.types, "D")
    end
  end

  test "resolver errors carry the offending field's line number" do
    src = """
    table T {
      a:int;
      b:ubyte = 300;
    }
    """

    assert {:error, {:default_out_of_range, "T", "b", 300, :u8, 3}} =
             Resolver.resolve_source(src)
  end
end
