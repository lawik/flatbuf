defmodule Flatbuf.NicetiesTest do
  @moduledoc """
  Niceties are off by default; tables compile dep-free. Enabling
  `:behaviour` makes the root table implement `Flatbuf.Table`;
  enabling `:jason` derives `Jason.Encoder` so a decoded struct
  encodes through the standard library JSON tooling.

  We test by code-generating into strings and asserting the relevant
  attribute lines appear (or don't), rather than compiling — `:jason`
  requires the Jason dep, which we don't pull in for the library.
  """

  use ExUnit.Case, async: true

  alias Flatbuf.Codegen
  alias Flatbuf.Schema.Resolver

  @schema """
  namespace NicetiesTest;

  table Doc { value: int; }

  root_type Doc;
  """

  defp generate(opts) do
    {:ok, schema} = Resolver.resolve_source(@schema)
    Codegen.generate(schema, [wire_module: NicetiesTest.Wire] ++ opts)
  end

  defp source_for(artifacts, module) do
    {_, src} = Enum.find(artifacts, fn {m, _} -> m == module end)
    src
  end

  test "default codegen emits no behaviour and no derive" do
    artifacts = generate([])
    src = source_for(artifacts, NicetiesTest.Doc)

    refute src =~ "@behaviour Flatbuf.Table"
    refute src =~ "@derive Jason.Encoder"
  end

  test ":behaviour nicety attaches the Flatbuf.Table behaviour to the root table" do
    artifacts = generate(niceties: [:behaviour])
    src = source_for(artifacts, NicetiesTest.Doc)

    assert src =~ "@behaviour Flatbuf.Table"
  end

  test ":jason nicety derives Jason.Encoder on the root table" do
    artifacts = generate(niceties: [:jason])
    src = source_for(artifacts, NicetiesTest.Doc)

    assert src =~ "@derive Jason.Encoder"
  end

  test ":behaviour-flagged module actually compiles and lists Flatbuf.Table" do
    schema = """
    namespace NicetiesTestCompile;
    table Doc { value: int; }
    root_type Doc;
    """

    alias Flatbuf.Test.CodegenCompiler

    CodegenCompiler.compile_source!(schema,
      wire_module: NicetiesTestCompile.Wire,
      niceties: [:behaviour]
    )

    behaviours =
      NicetiesTestCompile.Doc.module_info(:attributes)
      |> Keyword.get_values(:behaviour)
      |> List.flatten()

    assert Flatbuf.Table in behaviours
  end

  test "every emitted table gets the niceties (each can serve as a root)" do
    # Codegen emits decode/encode/verify on every table — non-root tables
    # can still be the root of a nested_flatbuffer or a freestanding
    # buffer. Niceties follow the same rule and attach to every table.
    schema = """
    namespace NicetiesTestX;

    table Inner { v: int; }
    table Outer { inner: Inner; }

    root_type Outer;
    """

    {:ok, resolved} = Resolver.resolve_source(schema)

    artifacts =
      Codegen.generate(resolved,
        wire_module: NicetiesTestX.Wire,
        niceties: [:behaviour, :jason]
      )

    for module <- [NicetiesTestX.Inner, NicetiesTestX.Outer] do
      src = source_for(artifacts, module)
      assert src =~ "@behaviour Flatbuf.Table"
      assert src =~ "@derive Jason.Encoder"
    end
  end
end
