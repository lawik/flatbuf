defmodule Flatbuf.OracleTest do
  @moduledoc """
  Differential tests against `flatc`, the upstream reference compiler.

  These tests are the practical answer to SPEC.md §10.2: "the library is
  correct iff `flatc` says it is." They take a schema we can fully
  generate code for, encode a value via our codegen, and ask `flatc` to
  decode it back to JSON — failing if the round-trip diverges.

  `flatc` is auto-installed under `_build/test/flatc/` on first use; the
  binary lives outside the source tree and ships with no part of a
  release build. If the auto-installer can't run on your platform,
  install `flatc` manually and put it on `$PATH`, or point
  `$FLATBUF_FLATC` at the executable.
  """

  use ExUnit.Case, async: false

  alias Flatbuf.Test.Flatc
  alias Flatbuf.Test.Upstream

  @corpus_ok Flatbuf.Test.Upstream.available?()

  if @corpus_ok do
    @schema_path Path.join(Upstream.tests_root(), "long_namespace.fbs")
    @table_module Com.Company.Test.Person
    @wire_module Flatbuf.OracleTest.Wire

    setup_all do
      # Will auto-download the binary on first use; subsequent runs
      # reuse the cached copy under _build/test/flatc/.
      _ = Flatc.ensure_available!()

      {:ok, artifacts} =
        Flatbuf.generate_from_path(@schema_path, wire_module: @wire_module)

      for {_, src} <- artifacts do
        Code.compile_string(src)
      end

      :ok
    end

    describe "Elixir-encoded buffer survives a flatc round-trip" do
      test "long_namespace.fbs / Person" do
        value = %{name: "Ada", age: 36}
        {:ok, bin} = @table_module.encode(value)

        assert {:ok, json} = Flatc.binary_to_json(@schema_path, bin)
        assert json["name"] == "Ada"
        assert json["age"] == 36
      end
    end
  else
    @tag skip: "upstream corpus missing — run `mix flatbuf.fetch_fixtures`"
    test "oracle prerequisites" do
      :ok
    end
  end
end
