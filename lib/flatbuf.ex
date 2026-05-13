defmodule Flatbuf do
  @moduledoc """
  `flatbuf` — pure-Elixir FlatBuffers with compile-time, file-emitting
  code generation.

  The user-facing entry points are the Mix tasks (`mix flatbuf.gen`) and
  the resolver/codegen modules:

  * `Flatbuf.Schema.Parser` — `.fbs` source → CST.
  * `Flatbuf.Schema.Resolver` — CST → resolved `%Flatbuf.Schema{}`.
  * `Flatbuf.Codegen` — schema → list of `{module, source}` artifacts.

  Generated code is dependency-free: a project can `mix flatbuf.gen` and
  drop `:flatbuf` from `deps` without breaking anything.
  """

  @doc """
  Convenience: parse, resolve, and generate from a schema file.

  Returns the list of `{module_name, source_string}` artifacts the way
  `Flatbuf.Codegen.generate/2` does. Useful for scripts and tests; the
  Mix task is the supported workflow.
  """
  alias Flatbuf.Codegen
  alias Flatbuf.Schema.Resolver

  @spec generate_from_path(Path.t(), keyword()) ::
          {:ok, [{module(), String.t()}]} | {:error, term()}
  def generate_from_path(path, opts \\ []) do
    with {:ok, schema} <- Resolver.resolve_path(path) do
      wire_module = Keyword.get(opts, :wire_module, Flatbuf.Generated.Wire)
      {:ok, Codegen.generate(schema, wire_module: wire_module)}
    end
  end
end
