defmodule Flatbuf.Test.Flatc do
  @moduledoc """
  Thin wrapper around the upstream `flatc` reference compiler so it can
  serve as the oracle for differential tests.

  `flatc` is auto-installed into `_build/flatc/` on first use — we
  download the prebuilt binary from the same GitHub release tag the
  corpus is pinned to (`Flatbuf.Test.Flatc.tag/0`). If `flatc` is
  already on `$PATH`, that's used instead.

  Supported platforms for the auto-installer:

    * Linux x86_64 (uses the `g++-13` build for max libstdc++ coverage)
    * macOS arm64 (`Mac.flatc.binary.zip`)
    * macOS x86_64 (`MacIntel.flatc.binary.zip`)
    * Windows x86_64 (`Windows.flatc.binary.zip`)

  Anything else (Linux on aarch64, BSDs, …) raises with a clear notice;
  install `flatc` manually and put it on `$PATH`, or set
  `FLATBUF_FLATC` to an absolute path.
  """

  @tag "v25.12.19"

  @doc "Upstream release tag we pin the binary to."
  def tag, do: @tag

  @doc """
  True iff `flatc` is reachable, either auto-installed locally, on
  `$PATH`, or pointed to by `$FLATBUF_FLATC`.
  """
  def available? do
    executable() != nil
  end

  @doc """
  Path to the `flatc` executable we should use, or `nil` if none is
  available and the auto-installer hasn't run yet.
  """
  def executable do
    cond do
      override = System.get_env("FLATBUF_FLATC") -> if File.exists?(override), do: override
      File.exists?(local_path()) -> local_path()
      path = System.find_executable("flatc") -> path
      true -> nil
    end
  end

  @doc """
  Ensure `flatc` is available, downloading the pinned release binary
  if it isn't. Returns the executable path. Raises on unsupported
  platforms.
  """
  def ensure_available! do
    case executable() do
      nil -> install!()
      path -> path
    end
  end

  @doc "`flatc --version` output, or `nil` if not installed."
  def version do
    case executable() do
      nil ->
        nil

      path ->
        case System.cmd(path, ["--version"], stderr_to_stdout: true) do
          {out, 0} -> String.trim(out)
          _ -> nil
        end
    end
  end

  @doc """
  Absolute path where the auto-installer puts `flatc`. Lives under
  `Mix.Project.build_path()` (i.e. `_build/test/flatc/`) so it's
  scoped to the test env and never gets rolled into a release build.
  """
  def local_path do
    base = Path.join(Mix.Project.build_path(), "flatc")

    case :os.type() do
      {:win32, _} -> Path.join(base, "flatc.exe")
      _ -> Path.join(base, "flatc")
    end
  end

  # ---------------------------------------------------------------------
  # Auto-installer
  # ---------------------------------------------------------------------

  defp install! do
    asset = pick_asset!()
    url = "https://github.com/google/flatbuffers/releases/download/#{@tag}/#{asset}"
    dest_dir = Path.dirname(local_path())
    File.mkdir_p!(dest_dir)

    notify("downloading flatc #{@tag} from #{url}")
    body = http_get!(url)

    zip_path = Path.join(dest_dir, asset)
    File.write!(zip_path, body)

    {:ok, _entries} =
      :zip.unzip(String.to_charlist(zip_path), [{:cwd, String.to_charlist(dest_dir)}])

    File.rm(zip_path)

    # The archive lays out `flatc` (or `flatc.exe` on Windows) at the
    # top level. Move into the expected slot if it landed elsewhere.
    case Path.wildcard(Path.join(dest_dir, "flatc*")) do
      [] -> raise "flatc binary missing after extracting #{asset}"
      [_only] -> :ok
      _multiple -> :ok
    end

    File.chmod!(local_path(), 0o755)
    notify("flatc installed at #{local_path()}")

    local_path()
  end

  defp pick_asset! do
    case platform() do
      :linux_x86_64 ->
        "Linux.flatc.binary.g++-13.zip"

      :mac_arm ->
        "Mac.flatc.binary.zip"

      :mac_intel ->
        "MacIntel.flatc.binary.zip"

      :windows ->
        "Windows.flatc.binary.zip"

      other ->
        raise """
        flatc auto-install doesn't support this platform: #{inspect(other)}.

        Either install flatc manually (e.g. `apt install flatbuffers-compiler`,
        `brew install flatbuffers`) and put it on $PATH, or set
        FLATBUF_FLATC to an absolute path.
        """
    end
  end

  defp platform do
    arch = :erlang.system_info(:system_architecture) |> to_string()

    case :os.type() do
      {:unix, :linux} ->
        cond do
          String.contains?(arch, "x86_64") -> :linux_x86_64
          String.contains?(arch, "amd64") -> :linux_x86_64
          true -> {:unsupported, :linux, arch}
        end

      {:unix, :darwin} ->
        cond do
          String.contains?(arch, "aarch64") -> :mac_arm
          String.contains?(arch, "arm64") -> :mac_arm
          true -> :mac_intel
        end

      {:win32, _} ->
        :windows

      other ->
        {:unsupported, other, arch}
    end
  end

  defp http_get!(url) do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)

    request = {String.to_charlist(url), []}

    http_opts = [
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ]
      ],
      timeout: 60_000,
      connect_timeout: 30_000
    ]

    case :httpc.request(:get, request, http_opts, body_format: :binary) do
      {:ok, {{_, 200, _}, _hdrs, body}} ->
        body

      {:ok, {{_, status, _}, _hdrs, _body}} ->
        raise "flatc download failed (#{status}) for #{url}"

      {:error, reason} ->
        raise "flatc download error: #{inspect(reason)} (#{url})"
    end
  end

  defp notify(msg) do
    # Print via Mix.shell when running under Mix; fall back to IO so
    # the message still surfaces in ExUnit setup output.
    if Code.ensure_loaded?(Mix) and function_exported?(Mix, :shell, 0) do
      Mix.shell().info("flatbuf: " <> msg)
    else
      IO.puts("flatbuf: " <> msg)
    end
  end

  # ---------------------------------------------------------------------
  # Wrappers — same names + shape as the previous version
  # ---------------------------------------------------------------------

  @doc """
  Convert a FlatBuffers binary to a decoded JSON term using `flatc --json`.
  """
  def binary_to_json(schema_path, binary) when is_binary(binary) do
    with {:ok, dir} <- tmp_dir(),
         bin_path = Path.join(dir, "input.bin"),
         :ok <- File.write(bin_path, binary),
         {out, _} <-
           System.cmd(
             ensure_available!(),
             [
               "--json",
               "--raw-binary",
               "--strict-json",
               "--no-warnings",
               "-o",
               dir,
               schema_path,
               "--",
               bin_path
             ],
             stderr_to_stdout: true
           ) do
      json_path = Path.join(dir, "input.json")

      case File.read(json_path) do
        {:ok, json} ->
          {:ok, JSON.decode!(json)}

        {:error, _} ->
          {:error, {:flatc_no_json, out}}
      end
    end
  after
    cleanup_tmp()
  end

  @doc """
  Convert a JSON encoding to a binary buffer via `flatc --binary`.
  """
  def json_to_binary(schema_path, json) when is_binary(json) do
    with {:ok, dir} <- tmp_dir(),
         json_path = Path.join(dir, "input.json"),
         :ok <- File.write(json_path, json),
         {out, code} <-
           System.cmd(
             ensure_available!(),
             ["--binary", "--strict-json", "--no-warnings", "-o", dir, schema_path, json_path],
             stderr_to_stdout: true
           ) do
      bin_path = Path.join(dir, "input.bin")

      cond do
        code != 0 -> {:error, {:flatc_failed, out}}
        true -> File.read(bin_path)
      end
    end
  after
    cleanup_tmp()
  end

  defp tmp_dir do
    dir =
      Path.join(System.tmp_dir!(), "flatbuf_oracle_#{:erlang.unique_integer([:positive])}")

    case File.mkdir_p(dir) do
      :ok ->
        Process.put(:flatbuf_tmp_dir, dir)
        {:ok, dir}

      err ->
        err
    end
  end

  defp cleanup_tmp do
    case Process.delete(:flatbuf_tmp_dir) do
      nil -> :ok
      dir -> File.rm_rf!(dir)
    end
  end
end
