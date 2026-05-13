defmodule Mix.Tasks.Flatbuf.FetchFixtures do
  @shortdoc "Pull the upstream google/flatbuffers test corpus, pinned to a release tag"

  @moduledoc """
  Pulls the `tests/` subtree from `google/flatbuffers` into
  `test/fixtures/upstream/`, pinned to `@tag`. The directory is in
  `.gitignore` — we track *which* upstream commit we conform against
  (via the constant in this file), not the bytes themselves.

  Uses `git clone --depth=1 --filter=blob:none --sparse` so we don't
  pull the whole repo history, and then `git sparse-checkout set tests`
  to limit the working tree to the bits we test against.

      mix flatbuf.fetch_fixtures            # idempotent; no-op if up to date
      mix flatbuf.fetch_fixtures --force    # blow away and re-clone
  """

  use Mix.Task

  @repo "https://github.com/google/flatbuffers.git"
  @tag "v25.12.19"
  @dest "test/fixtures/upstream"

  @impl Mix.Task
  def run(argv) do
    {opts, _} = OptionParser.parse!(argv, strict: [force: :boolean])

    if opts[:force] do
      File.rm_rf!(@dest)
    end

    case status() do
      :up_to_date ->
        Mix.shell().info("flatbuf.fetch_fixtures: #{@dest} already at #{@tag}")

      :missing ->
        clone()

      {:wrong_tag, actual} ->
        Mix.shell().info("flatbuf.fetch_fixtures: was at #{actual}, switching to #{@tag}")
        File.rm_rf!(@dest)
        clone()
    end

    :ok
  end

  defp clone do
    File.mkdir_p!(Path.dirname(@dest))

    args = [
      "clone",
      "--depth=1",
      "--filter=blob:none",
      "--sparse",
      "--branch=#{@tag}",
      @repo,
      @dest
    ]

    Mix.shell().info("flatbuf.fetch_fixtures: cloning #{@repo} @ #{@tag}")
    run_git!(args, ".")
    run_git!(["sparse-checkout", "set", "tests"], @dest)
    Mix.shell().info("flatbuf.fetch_fixtures: ready at #{@dest}")
  end

  defp status do
    cond do
      !File.exists?(@dest) -> :missing
      !File.exists?(Path.join(@dest, ".git")) -> :missing
      true -> check_tag()
    end
  end

  defp check_tag do
    case System.cmd("git", ["describe", "--tags", "--exact-match"],
           cd: @dest,
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        actual = String.trim(output)
        if actual == @tag, do: :up_to_date, else: {:wrong_tag, actual}

      _ ->
        {:wrong_tag, "unknown"}
    end
  end

  defp run_git!(args, cwd) do
    case System.cmd("git", args, cd: cwd, into: IO.stream(:stdio, :line), stderr_to_stdout: true) do
      {_, 0} -> :ok
      {_, code} -> Mix.raise("git #{Enum.join(args, " ")} failed with status #{code}")
    end
  end

  @doc "Absolute path of the upstream corpus root."
  def dest, do: Path.expand(@dest)

  @doc "Upstream tag we pin to."
  def tag, do: @tag
end
