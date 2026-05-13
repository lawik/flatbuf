defmodule Flatbuf.VerifierTest do
  @moduledoc """
  Exercises the generated `verify/1` against well-formed and malformed
  buffers.

  The verifier's job is to refuse cleanly — it must never let a bad
  offset propagate to the reader where it would crash with a binary_part
  badarg or trigger unbounded recursion. Each test here checks one
  way a buffer can be malformed.
  """

  use ExUnit.Case, async: false

  alias Flatbuf.Test.CodegenCompiler

  @schema """
  namespace VerifyT;

  table Inner { value: int; }
  table Outer {
    name: string;
    inner: Inner;
    inventory: [int];
  }

  root_type Outer;
  """

  CodegenCompiler.compile_source!(@schema, wire_module: Flatbuf.VerifierTest.Wire)

  test "a well-formed buffer verifies" do
    value = %{name: "ok", inner: %{value: 7}, inventory: [1, 2, 3]}
    {:ok, bin} = VerifyT.Outer.encode(value)
    assert :ok = VerifyT.Outer.verify(bin)
  end

  test "a buffer too small for the root uoffset is rejected" do
    assert {:error, _} = VerifyT.Outer.verify(<<>>)
    assert {:error, _} = VerifyT.Outer.verify(<<1, 2, 3>>)
  end

  test "truncating the buffer mid-table is caught" do
    {:ok, bin} = VerifyT.Outer.encode(%{name: "hello", inner: %{value: 7}})

    truncated = binary_part(bin, 0, byte_size(bin) - 4)
    assert {:error, _} = VerifyT.Outer.verify(truncated)
  end

  test "an obviously bogus root pointer is rejected" do
    # Root uoffset that points way past end-of-buffer.
    junk = <<0xFF, 0xFF, 0xFF, 0xFF, 0, 0, 0, 0>>
    assert {:error, _} = VerifyT.Outer.verify(junk)
  end

  test "an empty buffer fails verify" do
    assert {:error, _} = VerifyT.Outer.verify(<<>>)
  end

  @required_schema """
  namespace VerifyReq;

  table Doc {
    title: string (required);
    body: string;
  }

  root_type Doc;
  """

  CodegenCompiler.compile_source!(@required_schema, wire_module: Flatbuf.VerifierTest.WireReq)

  test "encode rejects a value that omits a required field" do
    assert {:error, {:flatbuf_required, :title}} =
             VerifyReq.Doc.encode(%{body: "no title"})
  end

  test "encode accepts a value with all required fields present" do
    assert {:ok, bin} = VerifyReq.Doc.encode(%{title: "ok", body: "body"})
    assert :ok = VerifyReq.Doc.verify(bin)
  end

  @relaxed_schema """
  namespace VerifyReqRelaxed;
  table Doc { title: string; body: string; }
  root_type Doc;
  """

  CodegenCompiler.compile_source!(@relaxed_schema,
    wire_module: Flatbuf.VerifierTest.WireReqRelaxed
  )

  test "verify rejects a buffer that omits a required field" do
    # Encode through a schema that lacks the `(required)` flag, then ask
    # the required-aware codec to verify the resulting buffer: it should
    # surface the missing slot as a structural error.
    {:ok, bin} = VerifyReqRelaxed.Doc.encode(%{body: "no title"})
    assert {:error, {:missing_required, :title}} = VerifyReq.Doc.verify(bin)
  end

  @file_id_schema """
  namespace VerifyFid;

  table Doc { value: int; }

  root_type Doc;
  file_identifier "FBUF";
  """

  CodegenCompiler.compile_source!(@file_id_schema, wire_module: Flatbuf.VerifierTest.WireFid)

  test "encode writes the schema's file_identifier into the buffer header" do
    {:ok, bin} = VerifyFid.Doc.encode(%{value: 42})
    assert binary_part(bin, 4, 4) == "FBUF"
    assert VerifyFid.Doc.file_identifier() == "FBUF"
  end

  test "size-prefixed encode and decode round-trip" do
    {:ok, bin} = VerifyFid.Doc.encode_size_prefixed(%{value: 99})
    <<size::little-32, body::binary>> = bin
    assert size == byte_size(body)

    assert :ok = VerifyFid.Doc.verify_size_prefixed(bin)
    assert {:ok, %{value: 99}} = VerifyFid.Doc.decode_size_prefixed(bin)
  end

  test "verify_size_prefixed rejects a mismatched length" do
    assert {:error, {:buffer_too_small, _}} = VerifyFid.Doc.verify_size_prefixed(<<>>)
    {:ok, bin} = VerifyFid.Doc.encode_size_prefixed(%{value: 1})
    truncated = binary_part(bin, 0, byte_size(bin) - 2)
    assert {:error, _} = VerifyFid.Doc.verify_size_prefixed(truncated)
  end

  test "decode_size_prefixed rejects a truncated buffer" do
    assert {:error, :truncated_size_prefix} = VerifyFid.Doc.decode_size_prefixed(<<>>)
    # Size prefix claims 99 bytes but only 2 bytes follow.
    assert {:error, :truncated_size_prefix} =
             VerifyFid.Doc.decode_size_prefixed(<<99::little-32, 0, 0>>)
  end
end
