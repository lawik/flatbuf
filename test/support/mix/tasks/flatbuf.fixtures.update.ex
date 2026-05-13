defmodule Mix.Tasks.Flatbuf.Fixtures.Update do
  @shortdoc "Refresh the upstream fixture-round-trip manifest"

  @moduledoc """
  Run every upstream binary/JSON fixture through our decode/encode/JSON
  round-trip and write the resulting outcome map to
  `test/fixtures/fixture_manifest.exs`.

  Run this whenever you intentionally change behaviour — e.g. after
  implementing size-prefixed buffer decoding, the
  `monsterdata_cstest_sp` entry will flip from
  `{:error, :decode, _}` to `:ok`, and the manifest needs to reflect
  that.

      mix flatbuf.fixtures.update
  """

  use Mix.Task

  @impl Mix.Task
  def run(_argv) do
    Mix.Task.run("compile")
    Application.ensure_all_started(:flatbuf)
    _ = Code.ensure_compiled(Flatbuf.Test.UpstreamFixtures)

    helper = Module.concat([Flatbuf, Test, UpstreamFixtures])

    unless function_exported?(helper, :fixtures, 0) do
      Mix.raise(
        "Flatbuf.Test.UpstreamFixtures not loaded — run with MIX_ENV=test " <>
          "(test/support is only on the elixirc path under :test)."
      )
    end

    Code.ensure_loaded!(Flatbuf.Test.Upstream)

    unless Flatbuf.Test.Upstream.available?() do
      Mix.raise("Upstream corpus missing. Run `mix flatbuf.fetch_fixtures` first.")
    end

    _ = Flatbuf.Test.Flatc.ensure_available!()

    fixtures = helper.fixtures()
    total = length(fixtures)
    Mix.shell().info("flatbuf.fixtures.update: running #{total} fixtures…")

    results =
      fixtures
      |> Enum.map(fn fx ->
        outcome = helper.run(fx)
        Mix.shell().info("  #{outcome_tag(outcome)} #{fx.name}")
        {fx.name, outcome}
      end)
      |> Enum.sort_by(&elem(&1, 0))

    ok = Enum.count(results, fn {_, v} -> v == :ok end)
    fail = total - ok

    body =
      """
      # Fixture round-trip manifest — outcomes for every binary/JSON
      # round-trip we run against our generated decoders.
      #
      # Regenerate with:
      #
      #     mix flatbuf.fixtures.update
      #
      # Corpus pinned to google/flatbuffers @ #{Mix.Tasks.Flatbuf.FetchFixtures.tag()}.

      %{
      """ <>
        Enum.map_join(results, ",\n", fn {n, v} -> "  #{inspect(n)} => #{inspect(v)}" end) <>
        "\n}\n"

    File.write!(helper.manifest_path(), body)

    Mix.shell().info("\nflatbuf.fixtures.update: #{ok} pass, #{fail} fail (of #{total})")

    Mix.shell().info("  → #{Path.relative_to_cwd(helper.manifest_path())}")
  end

  defp outcome_tag(:ok), do: "✓"
  defp outcome_tag({:error, kind, _}), do: "✗ #{kind}"
  defp outcome_tag({:error, kind}), do: "✗ #{kind}"
  defp outcome_tag(_), do: "?"
end
