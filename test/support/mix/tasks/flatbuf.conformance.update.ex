defmodule Mix.Tasks.Flatbuf.Conformance.Update do
  @shortdoc "Refresh the upstream conformance manifest"

  @moduledoc """
  Run the parser+resolver against every `.fbs` in the upstream corpus
  and write the result map to `test/fixtures/conformance_manifest.exs`.

  Run this whenever you intentionally change behaviour — e.g. after
  implementing unions, the union-test entries will flip from
  `{:error, {:unsupported_in_phase1, :union}}` to `:ok`, and the
  manifest needs to reflect that.

      mix flatbuf.conformance.update
  """

  use Mix.Task

  @impl Mix.Task
  def run(_argv) do
    Mix.Task.run("compile")
    Application.ensure_all_started(:flatbuf)
    _ = Code.ensure_compiled(Flatbuf.Test.Upstream)
    helper = Module.concat([Flatbuf, Test, Upstream])

    unless function_exported?(helper, :all_fbs, 0) do
      Mix.raise(
        "Flatbuf.Test.Upstream not loaded. Run the task with MIX_ENV=test " <>
          "(test/support is only on the elixirc path under :test)."
      )
    end

    unless helper.available?() do
      Mix.raise("Upstream corpus missing. Run `mix flatbuf.fetch_fixtures` first.")
    end

    results =
      helper.all_fbs()
      |> Enum.map(fn rel -> {rel, helper.run_schema(rel)} end)
      |> Enum.sort_by(&elem(&1, 0))

    ok_count = Enum.count(results, fn {_, v} -> v == :ok end)
    fail_count = length(results) - ok_count

    body =
      """
      # Conformance manifest — outcomes for every .fbs in the upstream
      # FlatBuffers test corpus. Regenerate with:
      #
      #     mix flatbuf.conformance.update
      #
      # Corpus pinned to google/flatbuffers @ #{Mix.Tasks.Flatbuf.FetchFixtures.tag()}.

      %{
      """ <>
        Enum.map_join(results, ",\n", fn {p, v} ->
          "  #{inspect(p)} => #{inspect(v)}"
        end) <>
        "\n}\n"

    File.write!(helper.manifest_path(), body)

    Mix.shell().info(
      "flatbuf.conformance.update: #{ok_count} pass, #{fail_count} fail (of #{length(results)})"
    )

    Mix.shell().info("  → #{Path.relative_to_cwd(helper.manifest_path())}")
  end
end
