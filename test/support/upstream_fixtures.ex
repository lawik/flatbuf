defmodule Flatbuf.Test.UpstreamFixtures do
  @moduledoc """
  Drives every binary/JSON fixture in the upstream corpus through a
  full round-trip against our generated code.

  For each fixture we:

  1. Resolve the `.fbs` schema (with upstream include paths).
  2. Generate code and compile every emitted module.
  3. Acquire a binary buffer — either the `.mon` on disk, or one
     produced by feeding `flatc` the reference `.json`.
  4. Decode that buffer with our generated `decode/1`.
  5. Convert the decoded struct to our flatc-shaped JSON map.
  6. Acquire the *expected* JSON by running `flatc --json --strict-json`
     against the same binary (so the comparison is byte-against-byte
     equivalent, no lax-JSON parsing required).
  7. Deep-compare the two maps.

  The outcome — `:ok` or a tagged `{:error, …}` — is recorded in
  `test/fixtures/fixture_manifest.exs`. Tests assert the *current*
  outcome equals the manifested outcome, so a known-broken fixture
  stays known-broken until we change it. Regenerate via
  `mix flatbuf.fixtures.update` after intentional changes.
  """

  alias Flatbuf.Test.CodegenCompiler
  alias Flatbuf.Test.Flatc
  alias Flatbuf.Test.Upstream

  @doc """
  Static list of fixture descriptors. Each entry has:

    * `:name` — short identifier (used as the manifest key).
    * `:schema` — path relative to the corpus root.
    * `:binary` — path to a `.mon`, or `nil` (then `flatc` makes one
      from `:json`).
    * `:json` — path to a strict/lax `.json`, or `nil` (then `flatc`
      makes one from `:binary`).
    * `:size_prefixed?` — true if the binary has a 4-byte size prefix
      we have to strip / honor before decoding.
    * `:known_issue` (optional) — one-line reason a fixture is pinned
      as failing. Copied into the manifest as a comment so the pin is
      self-explanatory.
  """
  def fixtures do
    monster_pairs = [
      {"monsterdata_test", "monsterdata_test.mon", "monsterdata_test.json"},
      {"monsterdata_python_wire", "monsterdata_python_wire.mon", "monsterdata_test.json"},
      {"monsterdata_javascript_wire", "ts/monsterdata_javascript_wire.mon",
       "monsterdata_test.json"},
      {"monsterdata_swift", "swift/Tests/Flatbuffers/monsterdata_test.mon",
       "monsterdata_test.json"},
      {"monsterdata_cstest", "FlatBuffers.Test/monsterdata_cstest.mon", "monsterdata_test.json"},
      {"unicode_test", "unicode_test.mon", "unicode_test.json"},
      {"unicode_test_ts", "ts/unicode_test.mon", "unicode_test.json"}
    ]

    monster_fixtures =
      for {name, bin, json} <- monster_pairs do
        %{
          name: name,
          schema: "monster_test.fbs",
          binary: bin,
          json: json,
          size_prefixed?: false
        }
      end

    [
      %{
        name: "monsterdata_cstest_sp",
        schema: "monster_test.fbs",
        binary: "FlatBuffers.Test/monsterdata_cstest_sp.mon",
        json: "monsterdata_test.json",
        size_prefixed?: true
      },
      %{
        name: "monsterdata_extra",
        schema: "monster_extra.fbs",
        binary: nil,
        json: "monsterdata_extra.json",
        size_prefixed?: false
      },
      %{
        # alignment_test.json is a stale orphan in upstream (referenced
        # by nothing, written for an older schema revision whose
        # SmallStructs had a `small_structs` field) — flatc itself
        # rejects it. The checked-in binary from alignment_test.cpp is
        # the real fixture: id 0 = even_structs under today's schema.
        name: "alignment_test",
        schema: "alignment_test.fbs",
        binary: "alignment_test_after_fix.bin",
        json: nil,
        size_prefixed?: false
      },
      %{
        name: "optional_scalars",
        schema: "optional_scalars.fbs",
        binary: nil,
        json: "optional_scalars.json",
        size_prefixed?: false
      },
      %{
        name: "optional_scalars_defaults",
        schema: "optional_scalars.fbs",
        binary: nil,
        json: "optional_scalars_defaults.json",
        size_prefixed?: false
      },
      %{
        name: "evolution_v1",
        schema: "evolution_test/evolution_v1.fbs",
        binary: nil,
        json: "evolution_test/evolution_v1.json",
        size_prefixed?: false,
        known_issue:
          "flatc limitation: evolution_v1.json sets union `j` without `j_type`, " <>
            "flatc encodes it as a NONE-typed value and its text generator then " <>
            "crashes (SIGSEGV at v25.12.19), so no reference JSON can exist; " <>
            "upstream never round-trips this buffer to text"
      },
      %{
        name: "evolution_v2",
        schema: "evolution_test/evolution_v2.fbs",
        binary: nil,
        json: "evolution_test/evolution_v2.json",
        size_prefixed?: false
      },
      %{
        name: "test_64bit",
        schema: "64bit/test_64bit.fbs",
        binary: nil,
        json: "64bit/test_64bit.json",
        size_prefixed?: false,
        known_issue:
          "library gap + flatc limitation: we don't implement the offset64/" <>
            "vector64 wire format (UOffset64 in-table, u64 vector lengths), " <>
            "and flatc's own text generator can't emit JSON for 64-bit " <>
            "buffers (\"unknown type\"), so there is no oracle either"
      },
      %{
        name: "annotated_binary",
        schema: "annotated_binary/annotated_binary.fbs",
        binary: nil,
        json: "annotated_binary/annotated_binary.json",
        size_prefixed?: false
      },
      %{
        name: "union_vector",
        schema: "union_vector/union_vector.fbs",
        binary: nil,
        json: "union_vector/union_vector.json",
        size_prefixed?: false
      }
      | monster_fixtures
    ]
    |> Enum.sort_by(& &1.name)
  end

  @doc """
  Run one fixture and return its outcome:

    * `:ok` — decoded buffer matches the reference JSON byte-for-byte.
    * `{:error, :resolve, reason}` — schema parser/resolver failed.
    * `{:error, :compile, reason}` — codegen produced something that
      doesn't compile (we surface the message, not the line number).
    * `{:error, :flatc, reason}` — flatc couldn't help us obtain the
      binary or reference JSON.
    * `{:error, :decode, reason}` — our `decode/1` returned `{:error, …}`
      or raised.
    * `{:error, :mismatch, diff}` — the decoded value differs from the
      reference. `diff` is the path to the first divergence.
  """
  def run(fixture) do
    try do
      do_run(fixture)
    rescue
      e -> {:error, :crash, Exception.message(e) |> String.split("\n") |> List.first()}
    catch
      kind, reason ->
        {:error, kind, inspect(reason) |> String.slice(0, 100)}
    end
  end

  defp do_run(fixture) do
    with {:ok, root_module} <- compile_schema(fixture),
         {:ok, bin} <- obtain_binary(fixture),
         bin = strip_size_prefix(bin, fixture.size_prefixed?),
         {:ok, decoded} <- safe_decode(root_module, bin),
         ours = apply(root_module, :__to_json_map__, [decoded]),
         {:ok, expected} <- flatc_json_for(fixture, bin) do
      case deep_diff(ours, expected) do
        :ok -> :ok
        diff -> {:error, :mismatch, diff}
      end
    end
  end

  # ----- schema → modules ------------------------------------------------

  defp compile_schema(fixture) do
    schema_path = Path.join(Upstream.tests_root(), fixture.schema)

    case Flatbuf.Schema.Resolver.resolve_path(schema_path,
           include_paths: Upstream.include_paths()
         ) do
      {:ok, schema} when is_binary(schema.root_type) ->
        try do
          # Wire module is keyed by the *schema*, not the fixture, so
          # all fixtures sharing a schema (e.g. the 8 Monster wire
          # variants) reuse the same compiled artifacts via the
          # CodegenCompiler cache instead of redefining everything.
          wire = wire_module_for_schema(fixture.schema)
          CodegenCompiler.compile_schema!(schema, wire_module: wire)
          {:ok, Module.concat([fqn_to_module(schema.root_type)])}
        rescue
          e ->
            {:error, :compile, Exception.message(e) |> String.split("\n") |> List.first()}
        end

      {:ok, _schema} ->
        {:error, :resolve, :no_root_type}

      {:error, reason} ->
        {:error, :resolve, reason}
    end
  end

  defp fqn_to_module(fqn) do
    Enum.map_join(String.split(fqn, "."), ".", &Macro.camelize/1)
  end

  # Deterministic wire-module atom derived from the schema's relative
  # path. Reused across fixtures that share a schema so the
  # CodegenCompiler cache hits.
  defp wire_module_for_schema(rel_path) do
    suffix =
      rel_path
      |> Path.rootname()
      |> String.split(["/", "_", "-", "."])
      |> Enum.map_join("", &Macro.camelize/1)

    Module.concat([Flatbuf.Fixture, Wire, String.to_atom(suffix)])
  end

  # ----- binary acquisition ---------------------------------------------

  defp obtain_binary(%{binary: nil, json: nil}), do: {:error, :flatc, :no_fixture_data}

  defp obtain_binary(%{binary: nil, json: json_rel} = fixture) do
    json_path = Path.join(Upstream.tests_root(), json_rel)
    schema_path = Path.join(Upstream.tests_root(), fixture.schema)
    flatc_encode(schema_path, json_path)
  end

  defp obtain_binary(%{binary: bin_rel}) do
    File.read(Path.join(Upstream.tests_root(), bin_rel))
  end

  defp flatc_encode(schema_path, json_path) do
    case Flatc.json_to_binary(schema_path, File.read!(json_path),
           include_paths: Upstream.include_paths()
         ) do
      {:ok, bin} -> {:ok, bin}
      {:error, reason} -> {:error, :flatc, reason}
    end
  end

  defp strip_size_prefix(<<_size::little-32, rest::binary>>, true), do: rest
  defp strip_size_prefix(bin, _), do: bin

  # ----- decode ----------------------------------------------------------

  defp safe_decode(mod, bin) do
    case apply(mod, :decode, [bin]) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, reason} -> {:error, :decode, summarize(reason)}
    end
  rescue
    e -> {:error, :decode, Exception.message(e) |> String.split("\n") |> List.first()}
  end

  defp summarize(term) when is_atom(term) or is_binary(term), do: term

  defp summarize(term),
    do: term |> inspect(limit: 5, printable_limit: 60) |> String.slice(0, 100)

  # ----- reference JSON via flatc ---------------------------------------

  defp flatc_json_for(fixture, bin) do
    schema_path = Path.join(Upstream.tests_root(), fixture.schema)

    case Flatc.binary_to_json(schema_path, bin, include_paths: Upstream.include_paths()) do
      {:ok, map} -> {:ok, map}
      {:error, reason} -> {:error, :flatc, reason}
    end
  end

  # ----- comparison ------------------------------------------------------

  @doc false
  def deep_diff(a, b), do: do_diff(a, b, [])

  defp do_diff(a, a, _path), do: :ok

  defp do_diff(a, b, path) when is_map(a) and is_map(b) do
    keys_a = Map.keys(a) |> Enum.sort()
    keys_b = Map.keys(b) |> Enum.sort()

    cond do
      keys_a != keys_b ->
        only_a = keys_a -- keys_b
        only_b = keys_b -- keys_a
        {:keys_diff, Enum.reverse(path), only_a, only_b}

      true ->
        Enum.reduce_while(keys_a, :ok, fn k, _ ->
          case do_diff(Map.fetch!(a, k), Map.fetch!(b, k), [k | path]) do
            :ok -> {:cont, :ok}
            diff -> {:halt, diff}
          end
        end)
    end
  end

  defp do_diff(a, b, path) when is_list(a) and is_list(b) do
    cond do
      length(a) != length(b) ->
        {:length_diff, Enum.reverse(path), length(a), length(b)}

      true ->
        a
        |> Enum.zip(b)
        |> Enum.with_index()
        |> Enum.reduce_while(:ok, fn {{ae, be}, i}, _ ->
          case do_diff(ae, be, [i | path]) do
            :ok -> {:cont, :ok}
            diff -> {:halt, diff}
          end
        end)
    end
  end

  defp do_diff(a, b, _path) when is_float(a) and is_integer(b),
    do: if(a == b * 1.0, do: :ok, else: {:value_diff, _ = nil, a, b})

  defp do_diff(a, b, _path) when is_integer(a) and is_float(b),
    do: if(a * 1.0 == b, do: :ok, else: {:value_diff, _ = nil, a, b})

  defp do_diff(a, b, path) when is_float(a) and is_float(b) do
    # Compare floats at f32 precision: if both values round to the
    # same 4-byte little-endian f32 bit pattern, treat them as equal.
    # This bridges the gap where flatc emits "3.1452" (shortest-f32
    # round-trip) and our `<<v::little-float-32>>` decode widens that
    # to 3.14520001411438 in f64 — both round to the same f32 bits,
    # so they're "the same value" by FlatBuffers wire-format standards.
    if <<a::little-float-32>> == <<b::little-float-32>>,
      do: :ok,
      else: {:value_diff, Enum.reverse(path), a, b}
  end

  defp do_diff(a, b, path), do: {:value_diff, Enum.reverse(path), a, b}

  @doc "Path of the conformance-style manifest we maintain."
  def manifest_path,
    do: Path.expand("../fixtures/fixture_manifest.exs", __DIR__)

  @doc "Load the manifest, returning an empty map if it doesn't exist yet."
  def load_manifest do
    case File.read(manifest_path()) do
      {:ok, src} ->
        {map, _} = Code.eval_string(src)
        map

      _ ->
        %{}
    end
  end
end
