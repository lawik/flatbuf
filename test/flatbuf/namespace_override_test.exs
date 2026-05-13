defmodule Flatbuf.NamespaceOverrideTest do
  @moduledoc """
  `mix flatbuf.gen --namespace NAME` (or `Codegen.generate(schema,
  namespace: NAME)`) replaces the `.fbs` file's `namespace`
  declaration when naming Elixir modules. Used to vendor an upstream
  schema (e.g. Apache Arrow's `org.apache.arrow.flatbuf`) under a
  project's own namespace tree without rewriting the schema source.

  Every emitted module — and every cross-reference inside emitted code
  — uses the override consistently.
  """

  use ExUnit.Case, async: true

  alias Flatbuf.Codegen
  alias Flatbuf.Schema.Resolver

  @schema """
  namespace org.apache.arrow.flatbuf;

  enum DataType : byte { Int = 0, Float = 1 }

  struct FieldId { value: int; }

  table Field {
    name: string;
    type: DataType;
    id: FieldId;
  }

  table Schema {
    fields: [Field];
  }

  root_type Schema;
  """

  test "every generated module uses the override prefix, not the .fbs namespace" do
    {:ok, schema} = Resolver.resolve_source(@schema)

    artifacts =
      Codegen.generate(schema,
        wire_module: Arrow.Ipc.Flatbuf.Wire,
        namespace: "Arrow.Ipc.Flatbuf"
      )

    modules = Enum.map(artifacts, &elem(&1, 0))

    assert Arrow.Ipc.Flatbuf.Wire in modules
    assert Arrow.Ipc.Flatbuf.Field in modules
    assert Arrow.Ipc.Flatbuf.Schema in modules
    assert Arrow.Ipc.Flatbuf.DataType in modules
    assert Arrow.Ipc.Flatbuf.FieldId in modules

    # No module should carry the original namespace.
    refute Enum.any?(modules, fn m -> m |> Atom.to_string() |> String.contains?("Org.Apache") end)
  end

  test "cross-references inside generated code use the override too" do
    {:ok, schema} = Resolver.resolve_source(@schema)

    artifacts =
      Codegen.generate(schema,
        wire_module: Arrow.Ipc.Flatbuf.Wire,
        namespace: "Arrow.Ipc.Flatbuf"
      )

    {_, schema_src} = Enum.find(artifacts, fn {m, _} -> m == Arrow.Ipc.Flatbuf.Schema end)
    {_, field_src} = Enum.find(artifacts, fn {m, _} -> m == Arrow.Ipc.Flatbuf.Field end)

    # The Schema table references Field via the override-prefixed name.
    assert schema_src =~ "Arrow.Ipc.Flatbuf.Field"
    refute schema_src =~ "Org.Apache"

    # The Field table references DataType and FieldId similarly.
    assert field_src =~ "Arrow.Ipc.Flatbuf.DataType"
    assert field_src =~ "Arrow.Ipc.Flatbuf.FieldId"
    refute field_src =~ "Org.Apache"
  end

  test "without --namespace, modules still use the schema's original namespace" do
    {:ok, schema} = Resolver.resolve_source(@schema)
    artifacts = Codegen.generate(schema, wire_module: Untouched.Wire)
    modules = Enum.map(artifacts, &elem(&1, 0))

    assert Org.Apache.Arrow.Flatbuf.Field in modules
    assert Org.Apache.Arrow.Flatbuf.Schema in modules
  end
end
