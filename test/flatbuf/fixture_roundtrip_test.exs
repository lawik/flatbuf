defmodule Flatbuf.FixtureRoundtripTest do
  @moduledoc """
  Round-trip every binary/JSON fixture from the upstream corpus
  through our generated decoder and a `flatc` JSON reference.

  Each entry in `Flatbuf.Test.UpstreamFixtures.fixtures/0` becomes one
  test. The test asserts the outcome matches what's recorded in
  `test/fixtures/fixture_manifest.exs`:

  * `:ok` — buffer decodes and our JSON output equals flatc's.
  * `{:error, kind, _}` — we expect that kind of failure. The trailing
    message is ignored in the comparison so unrelated wording changes
    don't break tests.

  Refresh the manifest via `mix flatbuf.fixtures.update` after
  intentional changes.
  """

  use ExUnit.Case, async: false

  alias Flatbuf.Test.Flatc
  alias Flatbuf.Test.Upstream
  alias Flatbuf.Test.UpstreamFixtures

  @corpus_ok Flatbuf.Test.Upstream.available?()

  if @corpus_ok do
    @manifest UpstreamFixtures.load_manifest()
    @fixtures UpstreamFixtures.fixtures()

    setup_all do
      _ = Flatc.ensure_available!()
      _ = Upstream.tests_root()
      :ok
    end

    test "manifest covers every fixture" do
      manifested = Map.keys(@manifest) |> Enum.sort()
      declared = Enum.map(@fixtures, & &1.name) |> Enum.sort()

      missing = declared -- manifested

      if missing != [] do
        flunk("""
        These fixtures have no manifest entry:

          #{Enum.join(missing, "\n  ")}

        Run `mix flatbuf.fixtures.update` to record current outcomes.
        """)
      end
    end

    for fixture <- @fixtures do
      @fixture fixture
      @expected Map.get(@manifest, fixture.name, :no_manifest_entry)

      test "fixture #{fixture.name}" do
        actual = UpstreamFixtures.run(@fixture)
        compare(@expected, actual, @fixture.name)
      end
    end

    # Two outcomes match if both are `:ok`, or both are
    # `{:error, kind, _}` with the same `kind`. The trailing message
    # (flatc's `out`, an exception string, etc.) is ignored so
    # unrelated changes don't break the suite.
    defp compare(expected, actual, name) do
      cond do
        expected == :ok and actual == :ok ->
          :ok

        match?({:error, _, _}, expected) and match?({:error, _, _}, actual) and
            elem(expected, 1) == elem(actual, 1) ->
          :ok

        true ->
          flunk("""
          Fixture #{name} outcome changed.

            expected: #{inspect(expected)}
            actual:   #{inspect(actual)}

          If the change is intentional, run `mix flatbuf.fixtures.update`
          and commit the new manifest.
          """)
      end
    end
  else
    @tag skip: "upstream corpus missing — run `mix flatbuf.fetch_fixtures`"
    test "corpus prerequisites" do
      :ok
    end
  end
end
