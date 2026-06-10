defmodule Flatbuf.GenTest do
  @moduledoc """
  Tests the `Flatbuf.Gen` plan helper and the `flatbuf.gen.check`
  Mix task. The Mix task is exercised via its module so we get a
  function-level error to assert on instead of process exit code.
  """

  use ExUnit.Case, async: false

  alias Flatbuf.Gen

  @schema_source """
  namespace GenTest.Tiny;

  table Doc { value: int; }

  root_type Doc;
  """

  setup do
    tmp = Path.join(System.tmp_dir!(), "flatbuf_gen_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    schema_path = Path.join(tmp, "tiny.fbs")
    File.write!(schema_path, @schema_source)
    out_dir = Path.join(tmp, "out")

    on_exit(fn -> File.rm_rf!(tmp) end)

    {:ok, schema_path: schema_path, out_dir: out_dir, tmp: tmp}
  end

  test "plan emits one artifact per generated module under the out dir", ctx do
    {:ok, artifacts} =
      Gen.plan([ctx.schema_path],
        out: ctx.out_dir,
        wire_module: "GenTest.Tiny.Wire"
      )

    modules = Enum.map(artifacts, & &1.module)
    assert GenTest.Tiny.Wire in modules
    assert GenTest.Tiny.Doc in modules

    for %{path: p} <- artifacts do
      assert String.starts_with?(p, ctx.out_dir)
      assert String.ends_with?(p, ".ex")
    end
  end

  test "flatbuf.gen writes artifacts; flatbuf.gen.check exits clean when unchanged", ctx do
    Mix.Task.rerun("flatbuf.gen", [
      ctx.schema_path,
      "--out",
      ctx.out_dir,
      "--wire-module",
      "GenTest.Tiny.Wire"
    ])

    Mix.Task.rerun("flatbuf.gen.check", [
      ctx.schema_path,
      "--out",
      ctx.out_dir,
      "--wire-module",
      "GenTest.Tiny.Wire"
    ])
  end

  test "flatbuf.gen.check fails when on-disk output drifts from the schema", ctx do
    Mix.Task.rerun("flatbuf.gen", [
      ctx.schema_path,
      "--out",
      ctx.out_dir,
      "--wire-module",
      "GenTest.Tiny.Wire"
    ])

    # Hand-edit a generated file to simulate drift.
    doc_path = Path.join([ctx.out_dir, "gen_test", "tiny", "doc.ex"])
    File.write!(doc_path, "# drifted\n")

    assert_raise Mix.Error, ~r/flatbuf\.gen\.check: 1 drift/, fn ->
      Mix.Task.rerun("flatbuf.gen.check", [
        ctx.schema_path,
        "--out",
        ctx.out_dir,
        "--wire-module",
        "GenTest.Tiny.Wire"
      ])
    end
  end

  test "flatbuf.gen.check fails when an expected output file is missing", ctx do
    assert_raise Mix.Error, ~r/flatbuf\.gen\.check: \d+ drift/, fn ->
      Mix.Task.rerun("flatbuf.gen.check", [
        ctx.schema_path,
        "--out",
        ctx.out_dir,
        "--wire-module",
        "GenTest.Tiny.Wire"
      ])
    end
  end

  describe "niceties validation" do
    test "parse_niceties accepts the known set" do
      assert Gen.parse_niceties(nil) == []
      assert Gen.parse_niceties("behaviour") == [:behaviour]
      assert Gen.parse_niceties("behaviour, jason") == [:behaviour, :jason]
    end

    test "parse_niceties rejects unknown names with the valid set in the message" do
      assert_raise ArgumentError, ~r/unknown nicety "behavior".*behaviour, jason/, fn ->
        Gen.parse_niceties("behavior")
      end
    end

    test "validate_niceties! passes known atoms through and rejects unknowns" do
      assert Gen.validate_niceties!([]) == []
      assert Gen.validate_niceties!([:jason, :behaviour]) == [:jason, :behaviour]

      assert_raise ArgumentError, ~r/unknown niceties \[:behavior\].*behaviour, jason/, fn ->
        Gen.validate_niceties!([:behavior, :jason])
      end
    end

    test "flatbuf.gen surfaces a nicety typo as a Mix error", ctx do
      assert_raise Mix.Error, ~r/flatbuf\.gen: unknown nicety "behavior"/, fn ->
        Mix.Task.rerun("flatbuf.gen", [ctx.schema_path, "--niceties", "behavior"])
      end
    end

    test "flatbuf.gen.check surfaces a nicety typo as a Mix error", ctx do
      assert_raise Mix.Error, ~r/flatbuf\.gen\.check: unknown nicety "behavior"/, fn ->
        Mix.Task.rerun("flatbuf.gen.check", [ctx.schema_path, "--niceties", "behavior"])
      end
    end
  end
end
