defmodule Mix.Tasks.Flatbuf.Gen.Check do
  @shortdoc "CI gate: fail if regenerating flatbuf schemas would change anything"

  @moduledoc """
  Re-run the `flatbuf.gen` pipeline and compare its output to the files
  currently on disk. Exits 0 if every emitted artifact already matches
  the committed source, non-zero otherwise. Nothing is written.

      mix flatbuf.gen.check SCHEMA.fbs [...] [--out PATH] [--namespace NAME]
                                          [--wire-module NAME] [--include PATH]
                                          [--niceties LIST]

  Designed for CI: drop it after the tests step, and a forgotten
  regenerate-after-schema-edit gets caught before merge.

  Flags mirror `mix flatbuf.gen` (no `--force`; this task never writes).
  """

  use Mix.Task

  alias Flatbuf.Gen

  @impl Mix.Task
  def run(argv) do
    {opts, paths} =
      OptionParser.parse!(argv,
        strict: [
          out: :string,
          wire_module: :string,
          namespace: :string,
          include: :keep,
          niceties: :string
        ]
      )

    if paths == [] do
      Mix.raise("flatbuf.gen.check: no schema files given")
    end

    plan_opts = [
      out: Keyword.get(opts, :out, "lib"),
      wire_module: opts[:wire_module] || "Flatbuf.Generated.Wire",
      namespace: opts[:namespace],
      include: Keyword.get_values(opts, :include),
      niceties: Flatbuf.Gen.parse_niceties(opts[:niceties])
    ]

    case Gen.plan(paths, plan_opts) do
      {:ok, artifacts} ->
        drifts = Enum.flat_map(artifacts, &diff_artifact/1)

        if drifts == [] do
          Mix.shell().info("flatbuf.gen.check: #{length(artifacts)} artifacts match")
          :ok
        else
          for {tag, path} <- drifts do
            Mix.shell().error("#{tag} #{Path.relative_to_cwd(path)}")
          end

          Mix.raise(
            "flatbuf.gen.check: #{length(drifts)} drift(s); run `mix flatbuf.gen` and commit the result"
          )
        end

      {:error, {path, reason}} ->
        Mix.raise("flatbuf.gen.check: #{path}: #{inspect(reason)}")
    end
  end

  defp diff_artifact(%{path: path, source: source}) do
    cond do
      !File.exists?(path) -> [{"missing  ", path}]
      File.read!(path) != source -> [{"differs  ", path}]
      true -> []
    end
  end
end
