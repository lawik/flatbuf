defmodule Flatbuf.Codegen.Naming do
  @moduledoc """
  Centralized fully-qualified-name → Elixir-module-name mapping.

  Without a `:namespace` override, the FQN drives the module name
  directly: `org.apache.arrow.flatbuf.Schema` becomes
  `Org.Apache.Arrow.Flatbuf.Schema`.

  When `:namespace` is set on the codegen (or passed via
  `mix flatbuf.gen --namespace`), it replaces whatever namespace the
  schema declared. Only the type's *short* name (last dotted segment)
  is kept; the override becomes the new root. For the Arrow example:

      module_name("org.apache.arrow.flatbuf.Schema", nil)
      #=> "Org.Apache.Arrow.Flatbuf.Schema"

      module_name("org.apache.arrow.flatbuf.Schema", "Arrow.Ipc.Flatbuf")
      #=> "Arrow.Ipc.Flatbuf.Schema"

  All codegen modules thread the same override through every call, so
  cross-references inside emitted code resolve consistently.
  """

  @spec module_name(String.t(), String.t() | nil) :: String.t()
  def module_name(fqn, nil) when is_binary(fqn) do
    fqn |> String.split(".") |> Enum.map_join(".", &Macro.camelize/1)
  end

  def module_name(fqn, prefix) when is_binary(fqn) and is_binary(prefix) do
    short = fqn |> String.split(".") |> List.last()

    (String.split(prefix, ".") ++ [short])
    |> Enum.map_join(".", &Macro.camelize/1)
  end
end
