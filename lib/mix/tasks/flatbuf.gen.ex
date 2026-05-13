defmodule Mix.Tasks.Flatbuf.Gen do
  @shortdoc "Generate Elixir source from FlatBuffers .fbs schemas"

  @moduledoc """
  Generate Elixir modules from one or more FlatBuffers `.fbs` files.

      mix flatbuf.gen SCHEMA.fbs [SCHEMA.fbs ...] [--out PATH] [--wire-module NAME]

  Each schema is parsed and resolved, then turned into a set of `.ex` files
  written under `--out` (default `lib/`). The Wire helper module is shared
  across all generated tables for the run; pass `--wire-module` to control
  its name (default `Flatbuf.Generated.Wire`).
  """

  use Mix.Task

  alias Flatbuf.Codegen
  alias Flatbuf.Schema.Resolver

  @impl Mix.Task
  def run(argv) do
    {opts, paths} =
      OptionParser.parse!(argv,
        strict: [
          out: :string,
          wire_module: :string,
          force: :boolean
        ]
      )

    if paths == [] do
      Mix.raise("flatbuf.gen: no schema files given")
    end

    out_dir = Keyword.get(opts, :out, "lib")
    wire_module = parse_module_name(opts[:wire_module] || "Flatbuf.Generated.Wire")
    force? = Keyword.get(opts, :force, false)

    schemas =
      Enum.map(paths, fn p ->
        case Resolver.resolve_path(p) do
          {:ok, schema} -> schema
          {:error, reason} -> Mix.raise("flatbuf.gen: #{p}: #{inspect(reason)}")
        end
      end)

    artifacts =
      schemas
      |> Enum.flat_map(&Codegen.generate(&1, wire_module: wire_module))
      |> Enum.uniq_by(&elem(&1, 0))

    File.mkdir_p!(out_dir)

    written =
      for {module, source} <- artifacts do
        path = output_path(out_dir, module)
        File.mkdir_p!(Path.dirname(path))

        write? =
          cond do
            force? -> true
            !File.exists?(path) -> true
            File.read!(path) != source -> true
            true -> false
          end

        if write? do
          File.write!(path, source)
          {:created, path}
        else
          {:unchanged, path}
        end
      end

    for {status, path} <- written do
      tag =
        case status do
          :created -> "* writing"
          :unchanged -> "  unchanged"
        end

      Mix.shell().info("#{tag} #{Path.relative_to_cwd(path)}")
    end

    :ok
  end

  defp parse_module_name(name) when is_binary(name) do
    name |> String.split(".") |> Module.concat()
  end

  defp output_path(out_dir, module) do
    relative =
      module
      |> Module.split()
      |> Enum.map(&Macro.underscore/1)
      |> Path.join()
      |> Kernel.<>(".ex")

    Path.join(out_dir, relative)
  end
end
