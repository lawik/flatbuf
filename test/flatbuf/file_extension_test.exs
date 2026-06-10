defmodule Flatbuf.FileExtensionTest do
  @moduledoc """
  `file_extension "ext";` is schema-level metadata: the conventional
  file suffix for buffers rooted in this schema (flatc uses it to name
  `--binary` output, defaulting to ".bin"). It never appears on the
  wire.

  The resolver stores it on the `Flatbuf.Schema`, and codegen surfaces
  it as `file_extension/0` on every generated table module — exactly
  parallel to `file_identifier/0`: emitted when the schema declares
  one, not emitted at all otherwise.
  """

  use ExUnit.Case, async: true

  alias Flatbuf.Schema.Resolver
  alias Flatbuf.Test.CodegenCompiler

  @with_ext """
  namespace FileExt;

  table Doc { value: int; }
  table Other { x: int; }

  root_type Doc;
  file_identifier "FEXT";
  file_extension "mon";
  """

  @without_ext """
  namespace FileExtNone;

  table Doc { value: int; }

  root_type Doc;
  """

  CodegenCompiler.compile_source!(@with_ext, wire_module: Flatbuf.FileExtensionTest.WireA)
  CodegenCompiler.compile_source!(@without_ext, wire_module: Flatbuf.FileExtensionTest.WireB)

  describe "resolver" do
    test "stores a declared file_extension on the schema" do
      assert {:ok, schema} = Resolver.resolve_source(@with_ext)
      assert schema.file_extension == "mon"
    end

    test "leaves file_extension nil when undeclared" do
      assert {:ok, schema} = Resolver.resolve_source(@without_ext)
      assert schema.file_extension == nil
    end
  end

  describe "generated modules" do
    test "the root table exposes file_extension/0" do
      assert FileExt.Doc.file_extension() == "mon"
    end

    test "file_extension/0 lands on every table of the schema, like file_identifier/0" do
      assert FileExt.Other.file_extension() == "mon"
      assert FileExt.Other.file_identifier() == "FEXT"
    end

    test "absent declaration: the function is not emitted, mirroring file_identifier/0" do
      refute function_exported?(FileExtNone.Doc, :file_extension, 0)
      refute function_exported?(FileExtNone.Doc, :file_identifier, 0)
    end

    test "the extension is metadata only — never written into the buffer" do
      {:ok, bin} = FileExt.Doc.encode(%{value: 1})
      assert :binary.match(bin, "mon") == :nomatch
      # The file_identifier, by contrast, *is* in the header.
      assert binary_part(bin, 4, 4) == "FEXT"
    end
  end
end
