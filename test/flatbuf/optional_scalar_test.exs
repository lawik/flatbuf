defmodule Flatbuf.OptionalScalarTest do
  @moduledoc """
  Regression tests for C2: optional scalars (`field: int = null`) must
  encode cleanly when absent. The omission sentinel for a `= null`
  field is `nil` itself — previously it was the type default `0`, so
  `nil != 0` sent `nil` into `push_i32/2` and `encode/1` raised
  `ArgumentError` on its own struct defaults.
  """

  use ExUnit.Case, async: false

  alias Flatbuf.Test.CodegenCompiler

  @schema """
  namespace OptS;

  enum Color: ubyte { Red, Green, Blue }

  table T {
    plain: int;
    opt_int: int = null;
    opt_bool: bool = null;
    opt_float: float = null;
    opt_enum: Color = null;
  }

  root_type T;
  """

  CodegenCompiler.compile_source!(@schema, wire_module: Flatbuf.OptionalScalarTest.Wire)

  test "encode of an empty map succeeds and absent optionals decode as nil" do
    assert {:ok, bin} = OptS.T.encode(%{})
    assert :ok = OptS.T.verify(bin)
    assert {:ok, decoded} = OptS.T.decode(bin)
    assert decoded.plain == 0
    assert decoded.opt_int == nil
    assert decoded.opt_bool == nil
    assert decoded.opt_float == nil
    assert decoded.opt_enum == nil
  end

  test "encode of the bare struct (all defaults) succeeds" do
    assert {:ok, bin} = OptS.T.encode(%OptS.T{})
    assert {:ok, %OptS.T{opt_int: nil, opt_bool: nil}} = OptS.T.decode(bin)
  end

  test "explicit nil for optional fields means omit" do
    assert {:ok, bin} = OptS.T.encode(%{opt_int: nil, opt_bool: nil, opt_enum: nil})
    assert {:ok, decoded} = OptS.T.decode(bin)
    assert decoded.opt_int == nil
    assert decoded.opt_bool == nil
    assert decoded.opt_enum == nil
  end

  test "the type-level default is still a real value for an optional field" do
    # `opt_int: 0` is distinct from "absent" when the schema default is
    # null — the slot must be written so decoders see 0, not nil.
    value = %{opt_int: 0, opt_bool: false, opt_float: 0.0, opt_enum: :Red}
    assert {:ok, bin} = OptS.T.encode(value)
    assert {:ok, decoded} = OptS.T.decode(bin)
    assert decoded.opt_int == 0
    assert decoded.opt_bool == false
    assert decoded.opt_float == 0.0
    assert decoded.opt_enum == :Red
  end

  test "non-default values round-trip" do
    value = %{opt_int: -42, opt_bool: true, opt_float: 1.5, opt_enum: :Blue}
    assert {:ok, bin} = OptS.T.encode(value)
    assert {:ok, decoded} = OptS.T.decode(bin)
    assert decoded.opt_int == -42
    assert decoded.opt_bool == true
    assert decoded.opt_float == 1.5
    assert decoded.opt_enum == :Blue
  end

  test "explicit nil for a NON-optional scalar is a tagged error, not a raise" do
    assert {:error, {:invalid_scalar, :plain, :i32, nil}} = OptS.T.encode(%{plain: nil})
  end

  test "optional fields still validate their range when present" do
    assert {:error, {:scalar_out_of_range, :opt_int, :i32, 0x80000000}} =
             OptS.T.encode(%{opt_int: 0x80000000})
  end

  test "to_json emits null for absent optional scalars (flatc-compatible)" do
    {:ok, bin} = OptS.T.encode(%{})
    {:ok, decoded} = OptS.T.decode(bin)
    parsed = decoded |> OptS.T.to_json() |> JSON.decode!()

    # flatc prints `"opt_int": null` for an optional scalar whose slot
    # is absent (the `optional_scalars` corpus fixture pins this); the
    # always-emit list keeps these keys through the nil filter.
    assert Map.fetch(parsed, "opt_int") == {:ok, nil}
    assert Map.fetch(parsed, "opt_bool") == {:ok, nil}
    assert Map.fetch(parsed, "opt_float") == {:ok, nil}
    assert Map.fetch(parsed, "opt_enum") == {:ok, nil}
    assert parsed["plain"] == 0
  end
end
