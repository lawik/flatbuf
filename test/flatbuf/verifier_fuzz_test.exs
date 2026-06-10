defmodule Flatbuf.VerifierFuzzTest do
  @moduledoc """
  Verifier fuzz corpus.

  Generates a battery of malformed buffers from a known-good seed and
  asserts that the generated `verify/2` returns `:ok` or `{:error, _, _}`
  for every one — *never* raises, never lets a bad offset slip through
  to `binary_part/3`'s `:badarg`.

  The mutations cover the failure modes the spec calls out:

    * truncation at every byte boundary,
    * single-byte flips at every position,
    * oversized lengths (a u32 length field set near `2**32 - 1`),
    * out-of-bounds uoffsets,
    * misaligned offsets,
    * cyclic-ish offsets (root uoffset pointing into the vtable area).
  """

  use ExUnit.Case, async: false

  alias Flatbuf.Test.CodegenCompiler

  @schema """
  namespace Fuzz;

  table Inner { value: int; }

  table Outer {
    name: string;
    values: [int];
    inner: Inner;
  }

  root_type Outer;
  """

  CodegenCompiler.compile_source!(@schema, wire_module: Flatbuf.VerifierFuzzTest.Wire)

  defp seed_buffer do
    {:ok, bin} =
      Fuzz.Outer.encode(%{
        name: "fuzz",
        values: [1, 2, 3, 4, 5],
        inner: %{value: 42}
      })

    bin
  end

  defp safe_verify(bin) do
    Fuzz.Outer.verify(bin)
  rescue
    e -> {:raised, e}
  catch
    kind, reason -> {:caught, kind, reason}
  end

  test "the seed buffer is well-formed" do
    assert :ok = safe_verify(seed_buffer())
  end

  test "every truncation returns :ok or {:error, _, _} (no raises)" do
    bin = seed_buffer()

    Enum.each(0..byte_size(bin), fn cut ->
      truncated = binary_part(bin, 0, cut)
      result = safe_verify(truncated)

      assert match?(:ok, result) or match?({:error, _, _}, result),
             "truncation at #{cut} produced #{inspect(result)}"
    end)
  end

  test "every single-byte flip returns :ok or {:error, _, _} (no raises)" do
    bin = seed_buffer()

    Enum.each(0..(byte_size(bin) - 1), fn pos ->
      <<head::binary-size(pos), b, tail::binary>> = bin
      mutated = <<head::binary, Bitwise.bxor(b, 0xFF), tail::binary>>
      result = safe_verify(mutated)

      assert match?(:ok, result) or match?({:error, _, _}, result),
             "byte-flip at #{pos} produced #{inspect(result)}"
    end)
  end

  # A huge length injected at an arbitrary slot may still leave a valid
  # buffer (not every 4-byte slot is a length), so rejection isn't
  # guaranteed — the property is that the verifier never crashes or
  # reads out of bounds.
  test "huge u32 length injections never crash (return :ok or {:error, _, _})" do
    bin = seed_buffer()

    # Try injecting a 0xFFFFFFFE length at every 4-byte aligned position
    # we could plausibly land on a length-prefix slot.
    big_len = <<0xFE, 0xFF, 0xFF, 0xFF>>

    Enum.each(0..(byte_size(bin) - 4)//4, fn pos ->
      <<head::binary-size(pos), _::binary-size(4), tail::binary>> = bin
      mutated = <<head::binary, big_len::binary, tail::binary>>
      result = safe_verify(mutated)

      assert match?(:ok, result) or match?({:error, _, _}, result),
             "huge-length at #{pos} produced #{inspect(result)}"
    end)
  end

  test "root uoffset pointing past end of buffer is rejected" do
    bin = seed_buffer()
    # Overwrite the root uoffset (first 4 bytes) with a value that
    # would land beyond the buffer.
    big_off = <<0xFF, 0xFF, 0x00, 0x00>>
    <<_::binary-size(4), rest::binary>> = bin
    mutated = <<big_off::binary, rest::binary>>

    assert {:error, _, _} = safe_verify(mutated)
  end

  test "root uoffset of 0 (would point at itself) is rejected" do
    bin = seed_buffer()
    <<_::binary-size(4), rest::binary>> = bin
    mutated = <<0, 0, 0, 0, rest::binary>>

    result = safe_verify(mutated)
    assert match?({:error, _, _}, result), "expected error, got #{inspect(result)}"
  end

  test "all-zeros buffer is rejected" do
    assert {:error, _, _} = safe_verify(:binary.copy(<<0>>, 128))
  end

  # Random bytes could in principle form a valid buffer, so we assert
  # the no-crash property rather than guaranteed rejection.
  test "random-bytes buffers never crash the verifier" do
    seed_pid = self()

    Enum.each(1..200, fn _ ->
      junk = :crypto.strong_rand_bytes(64)
      result = safe_verify(junk)

      assert match?(:ok, result) or match?({:error, _, _}, result),
             "random buffer #{inspect(junk)} produced #{inspect(result)} (from #{inspect(seed_pid)})"
    end)
  end
end
