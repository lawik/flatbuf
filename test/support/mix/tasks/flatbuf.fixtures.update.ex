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

    notes =
      for fx <- fixtures, note = Map.get(fx, :known_issue), into: %{}, do: {fx.name, note}

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
        Enum.map_join(results, ",\n", fn {n, v} ->
          known_issue_comment(notes[n], v) <> "  #{inspect(n)} => #{inspect(v)}"
        end) <>
        "\n}\n"

    File.write!(helper.manifest_path(), format_source(body))

    Mix.shell().info("\nflatbuf.fixtures.update: #{ok} pass, #{fail} fail (of #{total})")

    Mix.shell().info("  → #{Path.relative_to_cwd(helper.manifest_path())}")
  end

  defp outcome_tag(:ok), do: "✓"
  defp outcome_tag({:error, kind, _}), do: "✗ #{kind}"
  defp outcome_tag({:error, kind}), do: "✗ #{kind}"
  defp outcome_tag(_), do: "?"

  # Fixtures with a `:known_issue` get the reason written above their
  # pinned entry, word-wrapped into comment lines, so the manifest
  # explains itself. A note on a passing fixture is stale — drop it.
  defp known_issue_comment(nil, _outcome), do: ""
  defp known_issue_comment(_note, :ok), do: ""

  defp known_issue_comment(note, _outcome) do
    note
    |> String.split(" ")
    |> Enum.chunk_while(
      {0, []},
      fn word, {len, words} ->
        if len + String.length(word) > 66 and words != [] do
          {:cont, Enum.reverse(words), {String.length(word), [word]}}
        else
          {:cont, {len + String.length(word) + 1, [word | words]}}
        end
      end,
      fn {_, words} -> {:cont, Enum.reverse(words), nil} end
    )
    |> Enum.map_join(fn words -> "  # " <> Enum.join(words, " ") <> "\n" end)
  end

  # The manifest lives under `test/`, which `mix format` checks — keep
  # the generated file format-clean (comments survive formatting).
  defp format_source(body) do
    case Code.format_string!(body) do
      [] -> body
      formatted -> IO.iodata_to_binary([formatted, "\n"])
    end
  rescue
    _ -> body
  end
end
