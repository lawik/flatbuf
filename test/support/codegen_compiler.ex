defmodule Flatbuf.Test.CodegenCompiler do
  @moduledoc """
  Compile a set of generated artifacts into the running VM as a single
  unit, so cross-module references (one generated table calling another's
  `decode_at/2`, `__verify_at__/3`, etc.) resolve at compile time.

  Calling `Code.compile_string/1` per module produces a noisy parade of
  `… is not available or is yet to be defined` warnings, because the
  static analyzer sees a reference to a module that hasn't been
  compiled yet. Concatenating them into one source string fixes that —
  every referenced module is defined in the same compile unit.

  Used by every test that exercises `mix flatbuf.gen`-style codegen.
  """

  alias Flatbuf.Codegen
  alias Flatbuf.Schema.Resolver

  @doc """
  Convenience for the most common shape: take an inline schema source
  string, generate code, and compile everything in one shot. Returns
  the list of module atoms now loaded.
  """
  def compile_source!(schema_source, opts \\ []) when is_binary(schema_source) do
    {:ok, schema} = Resolver.resolve_source(schema_source)
    compile_schema!(schema, opts)
  end

  @doc """
  Same as `compile_source!/2` but starts from a schema file path
  (with optional `:include_paths`).
  """
  def compile_path!(path, opts \\ []) do
    resolver_opts = Keyword.take(opts, [:include_paths])
    {:ok, schema} = Resolver.resolve_path(path, resolver_opts)
    codegen_opts = Keyword.drop(opts, [:include_paths])
    compile_schema!(schema, codegen_opts)
  end

  @doc """
  Generate artifacts from an already-resolved schema and compile them
  together. Returns the loaded module atoms.
  """
  def compile_schema!(%Flatbuf.Schema{} = schema, opts) do
    artifacts = Codegen.generate(schema, opts)
    compile_artifacts!(artifacts)
  end

  @doc """
  Compile a list of `{module, source}` artifacts into the running VM
  as a single unit. Returns the loaded module atoms.
  """
  def compile_artifacts!(artifacts) do
    combined = Enum.map_join(artifacts, "\n\n", fn {_mod, src} -> src end)
    Code.compile_string(combined)
    Enum.map(artifacts, &elem(&1, 0))
  end
end
