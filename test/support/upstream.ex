defmodule Flatbuf.Test.Upstream do
  @moduledoc """
  Helpers for the upstream-corpus conformance suite.

  The corpus is `tests/` from `google/flatbuffers`, pinned via
  `Mix.Tasks.Flatbuf.FetchFixtures`. We don't vendor it; we just check
  which commit we currently conform against and assert behaviour on that.
  """

  alias Mix.Tasks.Flatbuf.FetchFixtures

  @doc "Absolute path to the upstream tests/ directory."
  def tests_root, do: Path.join(FetchFixtures.dest(), "tests")

  @doc "True iff the upstream corpus has been pulled."
  def available?, do: File.dir?(tests_root())

  @doc """
  Every `.fbs` file in the upstream `tests/` tree, returned as paths
  relative to `tests_root/0`. Stable order (sorted).
  """
  def all_fbs do
    root = tests_root()

    Path.wildcard(Path.join(root, "**/*.fbs"))
    |> Enum.map(&Path.relative_to(&1, root))
    |> Enum.sort()
  end

  @doc """
  Run our parser+resolver on a single upstream schema and return a
  normalized outcome term suitable for comparison against the manifest.

  The include paths mirror what upstream's CMake/Bazel feeds flatc:
  the corpus root and the `include_test` subdir (and its `sub/`) so
  schemas like `monster_test.fbs` can resolve their relative includes.
  """
  def run_schema(relative_path) do
    abs = Path.join(tests_root(), relative_path)

    case Flatbuf.Schema.Resolver.resolve_path(abs, include_paths: include_paths()) do
      {:ok, _schema} -> :ok
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  end

  @doc "Include search paths used for conformance runs."
  def include_paths do
    root = tests_root()
    upstream_root = Path.dirname(root)

    [
      root,
      upstream_root,
      Path.join(root, "include_test"),
      Path.join(root, "include_test/sub"),
      Path.join(root, "prototest"),
      Path.join(root, "flatc")
    ]
  end

  @doc """
  Strip line numbers and absolute paths so the manifest stays stable
  across machines and across upstream re-numbering.
  """
  def normalize_error(reason) do
    reason
    |> normalize_token_payload()
    |> drop_trailing_line()
    |> normalize_paths()
  end

  # `{:expected_punct, :rbracket, {:punct, :colon, 4}}` → `{:expected_punct, :rbracket, :colon}`
  defp normalize_token_payload({k, w, {t_kind, _v, _l}}) when is_atom(t_kind),
    do: {k, w, t_kind}

  defp normalize_token_payload({k, {t_kind, _v, _l}}) when is_atom(t_kind),
    do: {k, t_kind}

  defp normalize_token_payload(other), do: other

  # `{:unsupported_in_phase1, :union, 42}` → `{:unsupported_in_phase1, :union}`
  defp drop_trailing_line(t) when is_tuple(t) and tuple_size(t) >= 2 do
    list = Tuple.to_list(t)
    last = List.last(list)

    if is_integer(last) and last > 0 and last < 100_000 do
      list |> Enum.drop(-1) |> List.to_tuple()
    else
      t
    end
  end

  defp drop_trailing_line(other), do: other

  # `{:cannot_read, "/abs/path/.../foo.fbs", :enoent}` → `{:cannot_read, "foo.fbs", :enoent}`
  defp normalize_paths({:cannot_read, path, reason}) do
    {:cannot_read, relativize(path), reason}
  end

  defp normalize_paths(other), do: other

  defp relativize(path) do
    root = tests_root() <> "/"

    if is_binary(path) and String.starts_with?(path, root) do
      String.replace_prefix(path, root, "")
    else
      path
    end
  end

  @doc """
  Load the conformance manifest. Returns an empty map if missing so the
  test can flag every file as 'no expectation set'.
  """
  def load_manifest do
    case File.read(manifest_path()) do
      {:ok, contents} ->
        {map, _} = Code.eval_string(contents)
        map

      {:error, _} ->
        %{}
    end
  end

  @doc "Absolute path of the manifest file we maintain."
  def manifest_path,
    do: Path.expand("../fixtures/conformance_manifest.exs", __DIR__)
end
