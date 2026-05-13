defmodule Flatbuf.SharedStringsTest do
  @moduledoc """
  `(shared)` on a string field tells the encoder it's safe to dedupe
  identical values within the buffer. The builder maintains a
  `string_cache` mapping `binary => uoffset`, so a second
  `Wire.create_shared_string/2` with the same value reuses the first
  string's address instead of writing new bytes.

  Non-shared string fields keep the per-field semantics (each write
  produces its own bytes), so plain and shared variants of the same
  schema produce different buffer sizes when many duplicates are
  present.
  """

  use ExUnit.Case, async: false

  alias Flatbuf.Test.CodegenCompiler

  @shared_schema """
  namespace SharedTest;

  table Entry {
    label: string (shared);
    note: string;
  }

  table Group {
    entries: [Entry];
  }

  root_type Group;
  """

  CodegenCompiler.compile_source!(@shared_schema,
    wire_module: Flatbuf.SharedStringsTest.WireShared
  )

  @plain_schema """
  namespace PlainTest;

  table Entry {
    label: string;
    note: string;
  }

  table Group {
    entries: [Entry];
  }

  root_type Group;
  """

  CodegenCompiler.compile_source!(@plain_schema, wire_module: Flatbuf.SharedStringsTest.WirePlain)

  defp duplicate_entries(label_count, note_count) do
    for i <- 1..10 do
      %{
        label: "label-#{rem(i - 1, label_count)}",
        note: "note-#{rem(i - 1, note_count)}"
      }
    end
  end

  test "(shared) labels dedupe; non-shared notes don't" do
    # 10 entries, only 2 distinct labels and 2 distinct notes.
    entries = duplicate_entries(2, 2)

    {:ok, shared_bin} = SharedTest.Group.encode(%{entries: entries})
    {:ok, plain_bin} = PlainTest.Group.encode(%{entries: entries})

    # Shared buffer is smaller because the 10 label uoffsets all point
    # at 2 string bodies instead of 10. (Notes still occupy 10
    # distinct strings in both.)
    assert byte_size(shared_bin) < byte_size(plain_bin)
  end

  test "decodes back to the original entries through Wire.create_shared_string" do
    entries = duplicate_entries(2, 2)
    {:ok, bin} = SharedTest.Group.encode(%{entries: entries})
    {:ok, decoded} = SharedTest.Group.decode(bin)

    assert length(decoded.entries) == length(entries)

    decoded
    |> Map.fetch!(:entries)
    |> Enum.zip(entries)
    |> Enum.each(fn {actual, expected} ->
      assert actual.label == expected.label
      assert actual.note == expected.note
    end)
  end

  test "completely unique strings cost the same in both schemas" do
    entries =
      for i <- 1..5 do
        %{label: "unique-#{i}", note: "another-#{i}"}
      end

    {:ok, shared_bin} = SharedTest.Group.encode(%{entries: entries})
    {:ok, plain_bin} = PlainTest.Group.encode(%{entries: entries})

    # When there's nothing to dedupe, the byte sizes are the same.
    # (Same vtable shapes, same field sizes.)
    assert byte_size(shared_bin) == byte_size(plain_bin)
  end
end
