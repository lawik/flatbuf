defmodule FlatbufTest do
  @moduledoc """
  Smoke tests for the top-level entry points. The serious testing lives
  in conformance/fixture suites; these just guarantee that the public
  surface — `Flatbuf.generate_from_path/1,2` and
  `Flatbuf.Codegen.generate/2` — produces artifacts for a variety of
  real schemas without raising. They are the first thing a new user
  reaches for, so a stack trace here is a worse first impression than
  anywhere else.
  """

  use ExUnit.Case, async: true
  doctest Flatbuf

  alias Mix.Tasks.Flatbuf.FetchFixtures

  defp fixture(rel), do: Path.join(FetchFixtures.dest(), rel)

  defp need_corpus!(path) do
    unless File.exists?(path) do
      flunk("upstream corpus missing — run `mix flatbuf.fetch_fixtures`")
    end
  end

  test "generate_from_path/1 works with no options" do
    path = fixture("tests/flatc/foo.fbs")
    need_corpus!(path)

    {:ok, artifacts} = Flatbuf.generate_from_path(path)
    modules = Enum.map(artifacts, &elem(&1, 0))
    # Default wire module name when none is given.
    assert Flatbuf.Generated.Wire in modules
  end

  test "generate_from_path/2 honors :wire_module" do
    path = fixture("tests/flatc/foo.fbs")
    need_corpus!(path)

    {:ok, artifacts} = Flatbuf.generate_from_path(path, wire_module: MyTest.Wire)
    modules = Enum.map(artifacts, &elem(&1, 0))
    assert MyTest.Wire in modules
  end

  test "Codegen.generate/2 with only :wire_module succeeds on richer schemas" do
    # Every schema here exercises a different generator path: unions,
    # struct-arrays, optional scalars, empty enums (regression — used
    # to crash with `no case clause`), keyword field names.
    schemas = [
      "tests/arrays_test.fbs",
      "tests/union_vector/union_vector.fbs",
      "tests/optional_scalars.fbs",
      "tests/keyword_test.fbs"
    ]

    for rel <- schemas do
      path = fixture(rel)
      need_corpus!(path)

      {:ok, schema} = Flatbuf.Schema.Resolver.resolve_path(path)

      wire_mod = Module.concat([Flatbuf.SmokeTest, Macro.camelize(Path.basename(rel, ".fbs"))])
      artifacts = Flatbuf.Codegen.generate(schema, wire_module: wire_mod)

      assert length(artifacts) > 0, "no artifacts for #{rel}"

      Enum.each(artifacts, fn {mod, src} ->
        assert is_atom(mod)
        assert is_binary(src) and byte_size(src) > 0
      end)
    end
  end

  test "Codegen.generate/2 emits the wire helper exactly once" do
    path = fixture("tests/arrays_test.fbs")
    need_corpus!(path)

    {:ok, schema} = Flatbuf.Schema.Resolver.resolve_path(path)
    artifacts = Flatbuf.Codegen.generate(schema, wire_module: Flatbuf.SmokeTest.OnceWire)

    wire_hits = Enum.count(artifacts, fn {mod, _} -> mod == Flatbuf.SmokeTest.OnceWire end)
    assert wire_hits == 1
  end

  test "every emitted artifact is already formatted" do
    # Codegen.generate/2 runs the result through Code.format_string!/1,
    # so re-formatting should be a no-op. If a generator function
    # produces bytes the formatter further changes, this catches it.
    schemas = [
      "tests/arrays_test.fbs",
      "tests/union_vector/union_vector.fbs",
      "tests/optional_scalars.fbs",
      "tests/keyword_test.fbs"
    ]

    for rel <- schemas do
      path = fixture(rel)
      need_corpus!(path)

      {:ok, schema} = Flatbuf.Schema.Resolver.resolve_path(path)

      wire_mod =
        Module.concat([Flatbuf.SmokeTest.Fmt, Macro.camelize(Path.basename(rel, ".fbs"))])

      artifacts = Flatbuf.Codegen.generate(schema, wire_module: wire_mod)

      Enum.each(artifacts, fn {mod, source} ->
        reformatted = IO.iodata_to_binary([Code.format_string!(source), ?\n])

        assert source == reformatted,
               "#{inspect(mod)} from #{rel} is not idempotent under mix format"
      end)
    end
  end

  test "empty-enum field does not crash codegen" do
    # Regression: `enum public: int { }` with a field of that type used
    # to crash `default_enum_value/2` with a `CaseClauseError`. We don't
    # care what value the field defaults to — only that codegen completes.
    path = fixture("tests/keyword_test.fbs")
    need_corpus!(path)

    {:ok, artifacts} = Flatbuf.generate_from_path(path)
    assert length(artifacts) > 0
  end
end
