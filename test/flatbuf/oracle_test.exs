defmodule Flatbuf.OracleTest do
  @moduledoc """
  Differential tests against `flatc`, the upstream reference compiler.

  These tests are the practical answer to SPEC.md §10.2: "the library is
  correct iff `flatc` says it is." They take a schema we can fully
  generate code for, encode a value via our codegen, and ask `flatc` to
  decode it back to JSON — failing if the round-trip diverges.

  When `flatc` is missing from `$PATH` (or the upstream corpus hasn't
  been pulled), every test in this module is marked `:skip` with a
  clear notice. Install with `apt install flatbuffers-compiler` or
  `brew install flatbuffers` to turn them on.
  """

  use ExUnit.Case, async: false

  @flatc_ok Flatbuf.Test.Flatc.available?()
  @corpus_ok Flatbuf.Test.Upstream.available?()
  @ready @flatc_ok and @corpus_ok

  if @ready do
    alias Flatbuf.Test.Flatc
    alias Flatbuf.Test.Upstream

    @schema_path Path.join(Upstream.tests_root(), "long_namespace.fbs")
    @table_module Com.Company.Test.Person
    @wire_module Flatbuf.OracleTest.Wire

    setup_all do
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
    reason =
      cond do
        !@corpus_ok -> "upstream corpus missing — run `mix flatbuf.fetch_fixtures`"
        !@flatc_ok -> "flatc not on $PATH — install flatbuffers-compiler to enable oracle tests"
      end

    @tag skip: reason
    test "oracle prerequisites" do
      :ok
    end
  end
end
