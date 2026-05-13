defmodule FlatbufTest do
  use ExUnit.Case, async: true
  doctest Flatbuf

  test "generate_from_path returns artifacts for a schema we can parse" do
    # `flatc/foo.fbs` is a single-table phase-1-friendly upstream schema.
    path =
      Path.join([
        Mix.Tasks.Flatbuf.FetchFixtures.dest(),
        "tests/flatc/foo.fbs"
      ])

    if File.exists?(path) do
      {:ok, artifacts} = Flatbuf.generate_from_path(path, wire_module: MyTest.Wire)
      modules = Enum.map(artifacts, &elem(&1, 0))
      assert MyTest.Wire in modules
    else
      flunk("upstream corpus missing — run `mix flatbuf.fetch_fixtures`")
    end
  end
end
