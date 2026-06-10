defmodule Flatbuf.ReflectionSelfTest do
  @moduledoc """
  Reflection self-test: round-trip the upstream `reflection.fbs`.

  The upstream `reflection.fbs` schema describes a parsed FlatBuffers
  schema — it can represent itself. This test runs our pipeline end
  to end against it:

    1. Resolve `reflection.fbs` with the include paths it needs.
    2. Generate Elixir modules for every table, struct, enum, and
       union it declares.
    3. Compile the lot in one shot.
    4. Encode a minimal but legal `reflection.Schema` value (the
       `objects` and `enums` vectors are `(required)`).
    5. Decode the buffer back and confirm the field round-trip.
    6. Run our verifier on the buffer — it has to accept its own
       output.

  Reflection has unions (`KeyValue.value`? no — but a number of
  `(key)` fields, `(bit_flags)` enums, nested tables, vectors of
  tables) so this exercises a meaningful slice of the codegen.
  """

  use ExUnit.Case, async: false

  alias Flatbuf.Test.CodegenCompiler

  @reflection_path Path.expand(
                     "../fixtures/upstream/reflection/reflection.fbs",
                     __DIR__
                   )

  # `setup_all` cannot skip a suite — returning `{:skip, _}` there
  # makes ExUnit report 1 failure and 3 invalids. Instead, tag the
  # module at compile time so the whole suite is genuinely skipped
  # when the upstream corpus is missing.
  if File.exists?(@reflection_path) do
    {:ok, schema} = Flatbuf.Schema.Resolver.resolve_path(@reflection_path)
    artifacts = Flatbuf.Codegen.generate(schema, wire_module: Flatbuf.ReflectionSelfTest.Wire)
    CodegenCompiler.compile_artifacts!(artifacts)
  else
    @moduletag skip: "upstream corpus missing — run `mix flatbuf.fetch_fixtures`"
  end

  test "the resolved reflection.fbs has the expected top-level types" do
    {:ok, schema} = Flatbuf.Schema.Resolver.resolve_path(@reflection_path)

    type_names = Map.keys(schema.types) |> Enum.sort()

    for name <- [
          "reflection.AdvancedFeatures",
          "reflection.BaseType",
          "reflection.Enum",
          "reflection.EnumVal",
          "reflection.Field",
          "reflection.KeyValue",
          "reflection.Object",
          "reflection.RPCCall",
          "reflection.Schema",
          "reflection.SchemaFile",
          "reflection.Service",
          "reflection.Type"
        ] do
      assert name in type_names, "missing #{name}"
    end

    assert schema.root_type == "reflection.Schema"
    assert schema.file_identifier == "BFBS"
  end

  test "encode/decode an empty-but-required reflection.Schema round-trips" do
    {:ok, bin} = Reflection.Schema.encode(%{objects: [], enums: []})
    assert :ok = Reflection.Schema.verify(bin)
    assert {:ok, decoded} = Reflection.Schema.decode(bin)
    assert decoded.objects == []
    assert decoded.enums == []
  end

  test "encode a Schema with some Objects and Enums" do
    schema_value = %{
      objects: [
        %{name: "Foo", fields: [], is_struct: false},
        %{name: "Bar", fields: [], is_struct: true}
      ],
      enums: [
        %{
          name: "Color",
          values: [
            %{name: "Red", value: 0},
            %{name: "Green", value: 1},
            %{name: "Blue", value: 2}
          ],
          # reflection's `Enum.underlying_type` is also (required) — fill it in.
          underlying_type: %{base_type: :Byte}
        }
      ]
    }

    {:ok, bin} = Reflection.Schema.encode(schema_value)
    assert :ok = Reflection.Schema.verify(bin)

    {:ok, decoded} = Reflection.Schema.decode(bin)
    assert length(decoded.objects) == 2
    # reflection's Object.name is `(key)`, so the encoder sorted the
    # input vector ascending by name. Bar < Foo.
    assert Enum.map(decoded.objects, & &1.name) == ["Bar", "Foo"]

    [enum] = decoded.enums
    assert enum.name == "Color"
    assert Enum.map(enum.values, & &1.name) == ["Red", "Green", "Blue"]
    assert enum.underlying_type.base_type == :Byte
  end
end
