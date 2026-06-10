defmodule Flatbuf.VerifierBoundsTest do
  @moduledoc """
  Regression tests for C3: the verifier must bounds-check every inline
  field's voffset. The vtable header check bounds `table_pos +
  inline_size`, but `inline_size` and the per-slot voffsets are all
  attacker-controlled — a slot voffset of 0xFF00 used to pass
  `verify/1` and then blow up the zero-copy accessors with a
  `binary_part` badarg.

  The contract under test: if `verify/1` says `:ok`, `decode/1` and
  the accessors must not raise.
  """

  use ExUnit.Case, async: false

  alias Flatbuf.Test.CodegenCompiler

  @schema """
  namespace BoundsV;

  struct Pt { x: int; y: int; }

  table Inner { value: int; }

  union Item { Inner }

  table Outer {
    a: ushort;
    name: string;
    inner: Inner;
    nums: [int];
    pt: Pt;
    one: Item;
    items: [Item];
  }

  root_type Outer;
  """

  @wire Flatbuf.VerifierBoundsTest.Wire

  CodegenCompiler.compile_source!(@schema, wire_module: @wire)

  defp seed_buffer do
    {:ok, bin} =
      BoundsV.Outer.encode(%{
        a: 7,
        name: "n",
        inner: %{value: 1},
        nums: [1, 2],
        pt: %{x: 1, y: 2},
        one: {:Inner, %{value: 3}},
        items: [{:Inner, %{value: 4}}]
      })

    bin
  end

  # Root table's vtable: {vt_pos, vt_size, present_slots}.
  defp root_vtable(bin) do
    root_pos = @wire.root_table_pos(bin)
    vt_pos = root_pos - @wire.read_i32(bin, root_pos)
    vt_size = @wire.read_u16(bin, vt_pos)

    present =
      for slot <- 4..(vt_size - 2)//2,
          @wire.read_u16(bin, vt_pos + slot) != 0,
          do: slot

    {vt_pos, vt_size, present}
  end

  defp put_u16(bin, pos, v) do
    <<head::binary-size(pos), _::little-16, tail::binary>> = bin
    <<head::binary, v::little-16, tail::binary>>
  end

  defp safe_verify(bin) do
    BoundsV.Outer.verify(bin)
  rescue
    e -> {:raised, e}
  end

  test "the seed buffer is well-formed" do
    assert :ok = safe_verify(seed_buffer())
  end

  test "a slot voffset pointing far past the buffer fails verify on every field" do
    bin = seed_buffer()
    {vt_pos, _vt_size, present} = root_vtable(bin)
    assert present != []

    for slot <- present do
      mutated = put_u16(bin, vt_pos + slot, 0xFF00)

      assert {:error, {:inline_field_out_of_bounds, 0xFF00, _, _}} = safe_verify(mutated),
             "slot #{slot} patched to 0xFF00 must fail verify"
    end
  end

  test "a slot voffset inside the buffer but outside the inline area fails verify" do
    bin = seed_buffer()
    {vt_pos, _vt_size, present} = root_vtable(bin)
    root_pos = @wire.root_table_pos(bin)
    inline_size = @wire.read_u16(bin, vt_pos + 2)

    # Points past the table's inline area yet still well inside the
    # buffer — the old buffer-only thinking would let this through.
    sneaky = inline_size + 1
    assert root_pos + sneaky < byte_size(bin)

    for slot <- present do
      mutated = put_u16(bin, vt_pos + slot, sneaky)
      result = safe_verify(mutated)

      assert match?({:error, _}, result),
             "slot #{slot} patched to #{sneaky} produced #{inspect(result)}"
    end
  end

  test "after verify says :ok, decode does not raise (every slot x adversarial voffsets)" do
    bin = seed_buffer()
    {vt_pos, _vt_size, present} = root_vtable(bin)

    adversarial = [0xFF00, 0xFFFE, byte_size(bin) - 1, byte_size(bin) - 4, 4, 8, 63]

    for slot <- present, v <- adversarial do
      mutated = put_u16(bin, vt_pos + slot, v)

      case safe_verify(mutated) do
        :ok ->
          assert {:ok, _} = BoundsV.Outer.decode(mutated),
                 "verify passed slot #{slot} = #{v} but decode failed"

        {:error, _} ->
          :ok

        {:raised, e} ->
          flunk("verify raised for slot #{slot} = #{v}: #{inspect(e)}")
      end
    end
  end

  test "a hostile inline_size cannot smuggle fields past the end of the buffer" do
    bin = seed_buffer()
    {vt_pos, _, _} = root_vtable(bin)

    # Claim a giant inline area: the header check must reject it
    # before any slot check trusts it.
    mutated = put_u16(bin, vt_pos + 2, 0xFFFF)
    assert {:error, _} = safe_verify(mutated)
  end
end
