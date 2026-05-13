defmodule Flatbuf.Schema do
  @moduledoc """
  Resolved FlatBuffers schema IR.

  A `%Flatbuf.Schema{}` is the single source of truth for code generation. It
  contains every type that was parsed (across `include` files), keyed by its
  fully-qualified name, plus the root_type / file_identifier / file_extension
  declarations.

  Type records live in sibling modules: `Flatbuf.Schema.Table`,
  `Flatbuf.Schema.Struct`, `Flatbuf.Schema.Enum`, and `Flatbuf.Schema.Field`.
  """

  alias Flatbuf.Schema.Enum, as: SchemaEnum
  alias Flatbuf.Schema.Struct, as: SchemaStruct
  alias Flatbuf.Schema.Table
  alias Flatbuf.Schema.Union

  @type scalar ::
          :bool
          | :u8
          | :u16
          | :u32
          | :u64
          | :i8
          | :i16
          | :i32
          | :i64
          | :f32
          | :f64

  @type type_spec ::
          {:scalar, scalar()}
          | :string
          | {:vector, type_spec()}
          | {:array, type_spec(), pos_integer()}
          | {:name, String.t()}
          | {:table, String.t()}
          | {:struct, String.t()}
          | {:enum, String.t()}
          | {:union, String.t()}

  @type type_record :: Table.t() | SchemaStruct.t() | SchemaEnum.t() | Union.t()

  @type t :: %__MODULE__{
          types: %{String.t() => type_record()},
          root_type: String.t() | nil,
          file_identifier: String.t() | nil,
          file_extension: String.t() | nil,
          source_files: [String.t()]
        }

  defstruct types: %{},
            root_type: nil,
            file_identifier: nil,
            file_extension: nil,
            source_files: []

  @doc """
  Return the type record for a fully-qualified name, or `nil` if not found.
  """
  @spec fetch(t(), String.t()) :: type_record() | nil
  def fetch(%__MODULE__{types: types}, fqn), do: Map.get(types, fqn)

  @doc """
  Return all tables in the schema, in stable order by FQN.
  """
  @spec tables(t()) :: [Table.t()]
  def tables(%__MODULE__{types: types}) do
    types
    |> Map.values()
    |> Enum.filter(&match?(%Table{}, &1))
    |> Enum.sort_by(& &1.name)
  end

  @doc """
  Return all structs in the schema, in stable order by FQN.
  """
  @spec structs(t()) :: [SchemaStruct.t()]
  def structs(%__MODULE__{types: types}) do
    types
    |> Map.values()
    |> Enum.filter(&match?(%SchemaStruct{}, &1))
    |> Enum.sort_by(& &1.name)
  end

  @doc """
  Return all enums in the schema, in stable order by FQN.
  """
  @spec enums(t()) :: [SchemaEnum.t()]
  def enums(%__MODULE__{types: types}) do
    types
    |> Map.values()
    |> Enum.filter(&match?(%SchemaEnum{}, &1))
    |> Enum.sort_by(& &1.name)
  end

  @doc """
  Return all unions in the schema, in stable order by FQN.
  """
  @spec unions(t()) :: [Union.t()]
  def unions(%__MODULE__{types: types}) do
    types
    |> Map.values()
    |> Enum.filter(&match?(%Union{}, &1))
    |> Enum.sort_by(& &1.name)
  end

  @doc """
  Byte size of a scalar kind.
  """
  @spec scalar_size(scalar()) :: 1 | 2 | 4 | 8
  def scalar_size(:bool), do: 1
  def scalar_size(:u8), do: 1
  def scalar_size(:i8), do: 1
  def scalar_size(:u16), do: 2
  def scalar_size(:i16), do: 2
  def scalar_size(:u32), do: 4
  def scalar_size(:i32), do: 4
  def scalar_size(:f32), do: 4
  def scalar_size(:u64), do: 8
  def scalar_size(:i64), do: 8
  def scalar_size(:f64), do: 8

  @doc """
  Default value used when a missing scalar field is decoded.
  """
  @spec scalar_default(scalar()) :: number() | boolean()
  def scalar_default(:bool), do: false
  def scalar_default(:f32), do: 0.0
  def scalar_default(:f64), do: 0.0
  def scalar_default(_int), do: 0
end
