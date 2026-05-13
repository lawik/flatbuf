defmodule Mix.Tasks.Compile.Flatbuf do
  @shortdoc "Compile .fbs schemas into Elixir source files before compilation"

  @moduledoc """
  Mix compiler that regenerates Elixir source from `.fbs` schemas before
  the Elixir compiler runs. Wire it into your project by adding `:flatbuf`
  to the `:compilers` list in `mix.exs` and configuring schema paths in
  application config:

      def project do
        [
          # ...
          compilers: [:flatbuf | Mix.compilers()]
        ]
      end

      # config/config.exs
      config :my_app, :flatbuf,
        schemas: ["priv/fbs/monster.fbs"],
        out: "lib/my_app/schema",
        namespace: "MyApp.Schema",
        wire_module: "MyApp.Schema.Wire",
        include: ["priv/fbs"]

  ## How it works

  On each `mix compile`, the configured schemas are parsed and resolved.
  A manifest under
  `_build/<env>/lib/<app>/.mix/compile.flatbuf` tracks each schema's
  digest plus the list of files it last emitted. A schema is regenerated
  when:

    * its source digest no longer matches the manifest entry,
    * its expected output file is missing or has drifted on disk, or
    * the codegen options (namespace, wire module, niceties) changed.

  Outputs whose schema was removed from `:schemas` are deleted on the
  next compile, so a stale `.ex` from an old schema doesn't linger.

  ## Configuration keys (`config :my_app, :flatbuf`)

    * `:schemas` (required) — list of paths to `.fbs` files. Each is
      processed independently; cross-schema references go through
      `include` statements (or the `--include` search path).
    * `:out` — output directory; defaults to `"lib"`.
    * `:namespace` — root namespace override; see `mix flatbuf.gen`.
    * `:wire_module` — name of the emitted wire helper module;
      defaults to `Flatbuf.Generated.Wire`.
    * `:include` — list of include search paths.
    * `:niceties` — list of atoms enabling generated-table niceties:
      `:behaviour` (implements `Flatbuf.Table`), `:jason` (derives
      `Jason.Encoder`).
  """

  use Mix.Task.Compiler

  alias Flatbuf.Gen

  @manifest_vsn 1

  @impl Mix.Task.Compiler
  def run(_argv) do
    case load_config() do
      :unset ->
        # No `:flatbuf` config on the app — nothing to do. We
        # purposely don't error so that `compilers: [:flatbuf | ...]`
        # is a no-op for sub-apps that don't have schemas.
        {:noop, []}

      {:ok, schemas, plan_opts} ->
        do_compile(schemas, plan_opts, manifest_path())
    end
  end

  @impl Mix.Task.Compiler
  def manifests, do: [manifest_path()]

  @impl Mix.Task.Compiler
  def clean do
    case File.read(manifest_path()) do
      {:ok, bin} ->
        case :erlang.binary_to_term(bin) do
          %{vsn: @manifest_vsn, files: files} ->
            for path <- files, do: File.rm(path)

          _ ->
            :ok
        end

        File.rm(manifest_path())
        :ok

      _ ->
        :ok
    end
  end

  @doc """
  Internal compile entry point with the manifest path threaded
  explicitly. Used by `run/1` and by tests that want to drive the
  compiler outside Mix's project stack.
  """
  @spec do_compile([Path.t()], keyword(), Path.t()) :: {:ok | :noop, []} | {:error, [term()]}
  def do_compile(schemas, plan_opts, manifest_path) do
    manifest = load_manifest(manifest_path)

    case Gen.plan(schemas, plan_opts) do
      {:ok, artifacts} ->
        opts_digest = digest_opts(plan_opts)
        schema_digests = digest_schemas(schemas)

        artifacts_changed? =
          opts_digest != manifest.opts or
            schema_digests != manifest.schemas

        wrote =
          for %{path: path, source: source} <- artifacts do
            File.mkdir_p!(Path.dirname(path))

            write? =
              cond do
                artifacts_changed? -> true
                !File.exists?(path) -> true
                File.read!(path) != source -> true
                true -> false
              end

            if write? do
              File.write!(path, source)
              Mix.shell().info("Generated #{Path.relative_to_cwd(path)}")
              :wrote
            else
              :skipped
            end
          end

        emitted_paths = Enum.map(artifacts, & &1.path)
        clean_stale(manifest.files, emitted_paths)

        save_manifest(manifest_path, %{
          vsn: @manifest_vsn,
          files: emitted_paths,
          schemas: schema_digests,
          opts: opts_digest
        })

        status =
          cond do
            Enum.any?(wrote, &(&1 == :wrote)) -> :ok
            manifest.files == [] -> :ok
            true -> :noop
          end

        {status, []}

      {:error, {path, reason}} ->
        diag = %Mix.Task.Compiler.Diagnostic{
          file: path,
          severity: :error,
          message: "flatbuf: #{inspect(reason)}",
          position: 0,
          compiler_name: "flatbuf"
        }

        {:error, [diag]}
    end
  end

  defp load_config do
    app = Mix.Project.config()[:app]
    flatbuf = Application.get_env(app, :flatbuf)

    cond do
      is_nil(flatbuf) ->
        :unset

      !Keyword.keyword?(flatbuf) ->
        Mix.raise("config :#{app}, :flatbuf must be a keyword list, got: #{inspect(flatbuf)}")

      true ->
        schemas = Keyword.fetch!(flatbuf, :schemas)

        plan_opts = [
          out: Keyword.get(flatbuf, :out, "lib"),
          wire_module: Keyword.get(flatbuf, :wire_module, "Flatbuf.Generated.Wire"),
          namespace: Keyword.get(flatbuf, :namespace),
          include: Keyword.get(flatbuf, :include, []),
          niceties: Keyword.get(flatbuf, :niceties, [])
        ]

        {:ok, schemas, plan_opts}
    end
  end

  defp manifest_path do
    Path.join([Mix.Project.manifest_path(), "compile.flatbuf"])
  end

  defp load_manifest(path) do
    empty = %{vsn: @manifest_vsn, files: [], schemas: %{}, opts: nil}

    case File.read(path) do
      {:ok, bin} ->
        case :erlang.binary_to_term(bin) do
          %{vsn: @manifest_vsn} = m -> Map.merge(empty, m)
          _ -> empty
        end

      _ ->
        empty
    end
  end

  defp save_manifest(path, manifest) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, :erlang.term_to_binary(manifest))
  end

  # Remove files that the previous compile emitted but this one didn't.
  # Mirrors the protobuf compiler's behavior so renaming a schema or
  # dropping it from config doesn't leave a stale `.ex` behind.
  defp clean_stale(previous_files, current_files) do
    current = MapSet.new(current_files)

    for path <- previous_files, not MapSet.member?(current, path) do
      _ = File.rm(path)
      Mix.shell().info("Removing stale #{Path.relative_to_cwd(path)}")
    end
  end

  defp digest_opts(opts) do
    # Niceties / namespace / wire module changes warrant a full rebuild;
    # `out` doesn't (it's reflected in each path).
    opts
    |> Keyword.take([:wire_module, :namespace, :include, :niceties])
    |> :erlang.term_to_binary()
    |> :erlang.md5()
  end

  defp digest_schemas(paths) do
    Map.new(paths, fn path ->
      digest =
        case File.read(path) do
          {:ok, bin} -> :erlang.md5(bin)
          _ -> :missing
        end

      {path, digest}
    end)
  end
end
