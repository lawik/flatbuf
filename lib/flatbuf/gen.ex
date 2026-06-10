defmodule Flatbuf.Gen do
  @moduledoc """
  Shared helpers for the `flatbuf.gen`, `flatbuf.gen.check`, and
  `compile.flatbuf` Mix tasks.

  Resolves a list of `.fbs` paths into a flat list of
  `{module_atom, source_string, output_path}` artifacts so each task
  can do its own thing (write to disk, compare to disk, manifest).
  """

  alias Flatbuf.Codegen
  alias Flatbuf.Schema.Resolver

  @known_niceties [:behaviour, :jason]

  @type artifact :: %{module: module(), source: String.t(), path: Path.t()}

  @type plan_options :: [
          out: Path.t(),
          wire_module: module() | String.t(),
          namespace: String.t() | nil,
          include: [Path.t()],
          niceties: [atom()]
        ]

  @doc """
  Resolve each schema path, generate artifacts for the entire set, and
  return a list keyed by absolute output path.

  Duplicate module names across schemas are collapsed (the first
  schema to emit a module wins). Returns `{:ok, [artifact]}` or the
  first resolver error.
  """
  @spec plan([Path.t()], plan_options()) ::
          {:ok, [artifact()]} | {:error, term()}
  def plan(paths, opts) when is_list(paths) do
    out_dir = Keyword.get(opts, :out, "lib")
    wire_module = parse_module_name(opts[:wire_module] || "Flatbuf.Generated.Wire")
    namespace = opts[:namespace]
    include_paths = Keyword.get(opts, :include, [])
    niceties = Keyword.get(opts, :niceties, [])

    codegen_opts = [
      wire_module: wire_module,
      namespace: namespace,
      niceties: niceties
    ]

    with {:ok, schemas} <- resolve_all(paths, include_paths) do
      artifacts =
        schemas
        |> Enum.flat_map(&Codegen.generate(&1, codegen_opts))
        |> Enum.uniq_by(&elem(&1, 0))
        |> Enum.map(fn {module, source} ->
          %{module: module, source: source, path: output_path(out_dir, module)}
        end)

      {:ok, artifacts}
    end
  end

  @doc """
  Convert a dotted module-name string (`"My.App"`) or already-atom into
  a module atom. Idempotent.
  """
  @spec parse_module_name(module() | String.t()) :: module()
  def parse_module_name(name) when is_atom(name), do: name

  def parse_module_name(name) when is_binary(name) do
    name |> String.split(".") |> Module.concat()
  end

  @doc """
  The niceties the code generator knows about.
  """
  @spec known_niceties() :: [atom()]
  def known_niceties(), do: @known_niceties

  @doc """
  Parse a comma-separated nicety list (`"behaviour,jason"`) into a list
  of atoms. `nil` returns `[]` so this can be used directly on
  `OptionParser` output.

  Raises `ArgumentError` for names outside `known_niceties/0`, so a
  typo (`--niceties behavior`) fails loudly instead of silently doing
  nothing.
  """
  @spec parse_niceties(nil | String.t()) :: [atom()]
  def parse_niceties(nil), do: []

  def parse_niceties(str) when is_binary(str) do
    str
    |> String.split(",", trim: true)
    |> Enum.map(&parse_nicety!(String.trim(&1)))
  end

  defp parse_nicety!(name) do
    Enum.find(@known_niceties, &(Atom.to_string(&1) == name)) ||
      raise ArgumentError,
            "unknown nicety #{inspect(name)}; valid niceties: #{known_niceties_string()}"
  end

  @doc """
  Validate a list of nicety atoms (the `niceties:` config form used by
  `compile.flatbuf`). Returns the list unchanged, or raises
  `ArgumentError` naming the unknown entries and the valid set.
  """
  @spec validate_niceties!([atom()]) :: [atom()]
  def validate_niceties!(niceties) when is_list(niceties) do
    case Enum.reject(niceties, &(&1 in @known_niceties)) do
      [] ->
        niceties

      unknown ->
        raise ArgumentError,
              "unknown niceties #{inspect(unknown)}; valid niceties: #{known_niceties_string()}"
    end
  end

  defp known_niceties_string() do
    Enum.map_join(@known_niceties, ", ", &Atom.to_string/1)
  end

  @doc """
  Translate a module atom to its on-disk path under `out_dir`, mirroring
  Elixir's standard `Macro.underscore`-per-segment layout.
  """
  @spec output_path(Path.t(), module()) :: Path.t()
  def output_path(out_dir, module) do
    relative =
      module
      |> Module.split()
      |> Enum.map(&Macro.underscore/1)
      |> Path.join()
      |> Kernel.<>(".ex")

    Path.join(out_dir, relative)
  end

  defp resolve_all(paths, include_paths) do
    Enum.reduce_while(paths, {:ok, []}, fn p, {:ok, acc} ->
      case Resolver.resolve_path(p, include_paths: include_paths) do
        {:ok, schema} -> {:cont, {:ok, [schema | acc]}}
        {:error, reason} -> {:halt, {:error, {p, reason}}}
      end
    end)
    |> case do
      {:ok, schemas} -> {:ok, Enum.reverse(schemas)}
      err -> err
    end
  end
end
