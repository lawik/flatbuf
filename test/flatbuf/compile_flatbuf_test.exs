defmodule Mix.Tasks.Compile.FlatbufTest do
  @moduledoc """
  Exercises the `compile.flatbuf` Mix compiler against a temporary
  layout via its `do_compile/3` entry point (which threads the
  manifest path explicitly, so we don't need to manipulate
  `Mix.ProjectStack` from inside ExUnit).

  Verifies that:

    * a configured schema is generated into the configured `:out` dir,
    * an unchanged schema is a no-op on a second run,
    * dropping a schema from config removes its previous outputs.
  """

  use ExUnit.Case, async: false

  @schema_a """
  namespace CompileFlatbufTest.A;
  table Doc { value: int; }
  root_type Doc;
  """

  @schema_b """
  namespace CompileFlatbufTest.B;
  table Note { body: string; }
  root_type Note;
  """

  setup do
    tmp = Path.join(System.tmp_dir!(), "flatbuf_cc_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    schemas_dir = Path.join(tmp, "schemas")
    File.mkdir_p!(schemas_dir)
    out_dir = Path.join(tmp, "out")
    manifest = Path.join(tmp, "manifest")

    schema_a = Path.join(schemas_dir, "a.fbs")
    schema_b = Path.join(schemas_dir, "b.fbs")
    File.write!(schema_a, @schema_a)
    File.write!(schema_b, @schema_b)

    on_exit(fn -> File.rm_rf!(tmp) end)

    {:ok, schema_a: schema_a, schema_b: schema_b, out_dir: out_dir, manifest: manifest}
  end

  defp plan_opts(out_dir) do
    [
      out: out_dir,
      wire_module: "CompileFlatbufTest.Wire",
      namespace: nil,
      include: [],
      niceties: []
    ]
  end

  test "first compile emits files; second compile is a no-op", ctx do
    {result, _} =
      Mix.Tasks.Compile.Flatbuf.do_compile([ctx.schema_a], plan_opts(ctx.out_dir), ctx.manifest)

    assert result == :ok

    doc_path = Path.join([ctx.out_dir, "compile_flatbuf_test/a/doc.ex"])
    assert File.exists?(doc_path)
    original_mtime = File.stat!(doc_path).mtime
    original_content = File.read!(doc_path)

    # mtime resolution is seconds.
    :timer.sleep(1100)

    {result2, _} =
      Mix.Tasks.Compile.Flatbuf.do_compile([ctx.schema_a], plan_opts(ctx.out_dir), ctx.manifest)

    assert result2 in [:noop, :ok]
    assert File.exists?(doc_path)
    assert File.read!(doc_path) == original_content
    assert File.stat!(doc_path).mtime == original_mtime
  end

  test "dropping a schema from the schemas list removes its outputs", ctx do
    assert {:ok, _} =
             Mix.Tasks.Compile.Flatbuf.do_compile(
               [ctx.schema_a, ctx.schema_b],
               plan_opts(ctx.out_dir),
               ctx.manifest
             )

    doc_a = Path.join([ctx.out_dir, "compile_flatbuf_test/a/doc.ex"])
    doc_b = Path.join([ctx.out_dir, "compile_flatbuf_test/b/note.ex"])
    assert File.exists?(doc_a)
    assert File.exists?(doc_b)

    {_, _} =
      Mix.Tasks.Compile.Flatbuf.do_compile([ctx.schema_a], plan_opts(ctx.out_dir), ctx.manifest)

    assert File.exists?(doc_a)
    refute File.exists?(doc_b)
  end

  test "schema content change regenerates the output", ctx do
    {:ok, _} =
      Mix.Tasks.Compile.Flatbuf.do_compile([ctx.schema_a], plan_opts(ctx.out_dir), ctx.manifest)

    doc_path = Path.join([ctx.out_dir, "compile_flatbuf_test/a/doc.ex"])
    first = File.read!(doc_path)

    File.write!(ctx.schema_a, """
    namespace CompileFlatbufTest.A;
    table Doc { value: int; name: string; }
    root_type Doc;
    """)

    {:ok, _} =
      Mix.Tasks.Compile.Flatbuf.do_compile([ctx.schema_a], plan_opts(ctx.out_dir), ctx.manifest)

    assert File.read!(doc_path) != first
    # The new field shows up in the generated defstruct.
    assert File.read!(doc_path) =~ "name:"
  end

  test "schema that fails to resolve returns an :error tuple with a diagnostic", ctx do
    bad = Path.join(Path.dirname(ctx.schema_a), "bad.fbs")
    File.write!(bad, "this is not a schema {{")

    assert {:error, [diag]} =
             Mix.Tasks.Compile.Flatbuf.do_compile([bad], plan_opts(ctx.out_dir), ctx.manifest)

    assert diag.file == bad
    assert diag.severity == :error
    assert diag.compiler_name == "flatbuf"
    refute File.exists?(Path.join([ctx.out_dir, "compile_flatbuf_test"]))
  end
end
