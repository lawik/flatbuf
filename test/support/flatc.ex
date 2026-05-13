defmodule Flatbuf.Test.Flatc do
  @moduledoc """
  Thin wrapper around the upstream `flatc` reference compiler so it can
  serve as the oracle for differential tests.

  `flatc` is *optional*: tests that depend on it call `available?/0`
  first and skip with a clear message when it's missing. The CI image
  should install it (the spec earmarks `Dockerfile.test` for this); a
  developer on a fresh checkout can run any test that doesn't need the
  oracle, and the oracle ones turn green once they `brew install` or
  `apt install` it.
  """

  @doc "True iff `flatc` is on `$PATH`."
  def available? do
    System.find_executable("flatc") != nil
  end

  @doc "`flatc --version` output, or `nil` if not installed."
  def version do
    if available?() do
      case System.cmd("flatc", ["--version"], stderr_to_stdout: true) do
        {out, 0} -> String.trim(out)
        _ -> nil
      end
    end
  end

  @doc """
  Convert a FlatBuffers binary to JSON using `flatc --json`.

  `schema_path` is the path to the matching `.fbs` file. `binary` is the
  buffer bytes. Returns `{:ok, decoded_json_map}` on success.
  """
  def binary_to_json(schema_path, binary) when is_binary(binary) do
    with :ok <- ensure_available(),
         {:ok, dir} <- tmp_dir(),
         bin_path = Path.join(dir, "input.bin"),
         :ok <- File.write(bin_path, binary),
         {out, _} <-
           System.cmd(
             "flatc",
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
      # flatc writes <basename>.json beside the input.
      json_path = Path.join(dir, "input.json")

      case File.read(json_path) do
        {:ok, json} ->
          {:ok, Jason.decode!(json)}

        {:error, _} ->
          {:error, {:flatc_no_json, out}}
      end
    end
  after
    cleanup_tmp()
  end

  @doc """
  Convert a JSON encoding of a flatbuffer to its binary form using
  `flatc --binary`. Returns `{:ok, binary}`.
  """
  def json_to_binary(schema_path, json) when is_binary(json) do
    with :ok <- ensure_available(),
         {:ok, dir} <- tmp_dir(),
         json_path = Path.join(dir, "input.json"),
         :ok <- File.write(json_path, json),
         {out, code} <-
           System.cmd(
             "flatc",
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

  defp ensure_available do
    if available?(), do: :ok, else: {:error, :flatc_missing}
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
