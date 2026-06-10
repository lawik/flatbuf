# Fixture round-trip manifest — outcomes for every binary/JSON
# round-trip we run against our generated decoders.
#
# Regenerate with:
#
#     mix flatbuf.fixtures.update
#
# Corpus pinned to google/flatbuffers @ v25.12.19.

%{
  "alignment_test" => :ok,
  "annotated_binary" => :ok,
  # flatc limitation: evolution_v1.json sets union `j` without
  # `j_type`, flatc encodes it as a NONE-typed value and its text
  # generator then crashes (SIGSEGV at v25.12.19), so no reference JSON
  # can exist; upstream never round-trips this buffer to text
  "evolution_v1" => {:error, :flatc, {:flatc_crash, {:exit_status, 139}}},
  "evolution_v2" => :ok,
  "monsterdata_cstest" => :ok,
  "monsterdata_cstest_sp" => :ok,
  "monsterdata_extra" => :ok,
  "monsterdata_javascript_wire" => :ok,
  "monsterdata_python_wire" => :ok,
  "monsterdata_swift" => :ok,
  "monsterdata_test" => :ok,
  "optional_scalars" => :ok,
  "optional_scalars_defaults" => :ok,
  # library gap + flatc limitation: we don't implement the
  # offset64/vector64 wire format (UOffset64 in-table, u64 vector
  # lengths), and flatc's own text generator can't emit JSON for 64-bit
  # buffers ("unknown type"), so there is no oracle either
  "test_64bit" =>
    {:error, :flatc, {:flatc_no_json, "Unable to generate text for input (unknown type)"}},
  "unicode_test" => :ok,
  "unicode_test_ts" => :ok,
  "union_vector" => :ok
}
