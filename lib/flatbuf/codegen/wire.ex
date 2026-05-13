defmodule Flatbuf.Codegen.Wire do
  @moduledoc """
  Emits the `<Root>.Flatbuf.Wire` helper module.

  The emitted module is the only piece of code the generated readers/writers
  depend on at runtime. It is itself dependency-free Elixir source. The
  template here changes only when the wire format changes; the user re-runs
  `mix flatbuf.gen` and the file gets refreshed alongside their typed
  modules.
  """

  @template ~S'''
  defmodule <%= MODULE %> do
    @moduledoc "Generated FlatBuffers wire helper. Do not edit by hand."

    # ---------------------------------------------------------------------
    # Readers
    # ---------------------------------------------------------------------

    @compile {:inline,
              read_u8: 2,
              read_i8: 2,
              read_u16: 2,
              read_i16: 2,
              read_u32: 2,
              read_i32: 2,
              read_u64: 2,
              read_i64: 2,
              read_f32: 2,
              read_f64: 2,
              read_bool: 2,
              follow_uoffset: 2}

    def read_u8(buf, off), do: :binary.at(buf, off)

    def read_i8(buf, off) do
      <<v::signed-8>> = binary_part(buf, off, 1)
      v
    end

    def read_u16(buf, off) do
      <<v::little-16>> = binary_part(buf, off, 2)
      v
    end

    def read_i16(buf, off) do
      <<v::little-signed-16>> = binary_part(buf, off, 2)
      v
    end

    def read_u32(buf, off) do
      <<v::little-32>> = binary_part(buf, off, 4)
      v
    end

    def read_i32(buf, off) do
      <<v::little-signed-32>> = binary_part(buf, off, 4)
      v
    end

    def read_u64(buf, off) do
      <<v::little-64>> = binary_part(buf, off, 8)
      v
    end

    def read_i64(buf, off) do
      <<v::little-signed-64>> = binary_part(buf, off, 8)
      v
    end

    # NaN / Infinity have no Elixir-float representation that a
    # `<<v::float-32>>` pattern can bind, so we sniff the raw bits
    # before matching and return the corresponding atoms.
    def read_f32(buf, off) do
      <<raw::little-32>> = binary_part(buf, off, 4)
      f32_from_bits(raw)
    end

    def read_f64(buf, off) do
      <<raw::little-64>> = binary_part(buf, off, 8)
      f64_from_bits(raw)
    end

    defp f32_from_bits(0x7F800000), do: :infinity
    defp f32_from_bits(0xFF800000), do: :neg_infinity

    defp f32_from_bits(raw) do
      # Any other exponent=255 pattern is a NaN.
      if Bitwise.band(raw, 0x7F800000) == 0x7F800000 and Bitwise.band(raw, 0x007FFFFF) != 0 do
        :nan
      else
        <<v::little-float-32>> = <<raw::little-32>>
        v
      end
    end

    defp f64_from_bits(0x7FF0000000000000), do: :infinity
    defp f64_from_bits(0xFFF0000000000000), do: :neg_infinity

    defp f64_from_bits(raw) do
      exp_mask = 0x7FF0000000000000
      mantissa_mask = 0x000FFFFFFFFFFFFF

      if Bitwise.band(raw, exp_mask) == exp_mask and Bitwise.band(raw, mantissa_mask) != 0 do
        :nan
      else
        <<v::little-float-64>> = <<raw::little-64>>
        v
      end
    end

    def read_bool(buf, off), do: read_u8(buf, off) != 0

    @doc "Read a uoffset_t at `off` and return the absolute target position."
    def follow_uoffset(buf, off), do: off + read_u32(buf, off)

    @doc "Root table position: follow the uoffset at buffer position 0."
    def root_table_pos(buf), do: follow_uoffset(buf, 0)

    @doc """
    Return the offset (within the table) of `slot`, or 0 if the slot is
    absent or beyond the vtable's known size.
    """
    def read_vtable_field(buf, table_pos, slot) do
      soffset = read_i32(buf, table_pos)
      vt_pos = table_pos - soffset
      vt_size = read_u16(buf, vt_pos)

      if slot >= vt_size do
        0
      else
        read_u16(buf, vt_pos + slot)
      end
    end

    @doc "Read a length-prefixed string at `pos` (the position of the u32 length)."
    def read_string_at(buf, pos) do
      len = read_u32(buf, pos)
      binary_part(buf, pos + 4, len)
    end

    @doc "Read the element count of a vector at `pos` (the position of the u32 count)."
    def read_vector_count(buf, pos), do: read_u32(buf, pos)

    @doc "Return the absolute position of element `i` in a vector at `pos`."
    def vector_elem_pos(pos, i, elem_size), do: pos + 4 + i * elem_size

    @doc """
    Binary-search a vector of `uoffset_t` (`[Table]`) by `target` key.

    `key_fn` is `(buf, table_pos -> key_value)` — typically the
    `__key_at__/2` getter the table generator emits for its `(key)`
    field. Returns the matching table's absolute position, or `nil`.

    Assumes the vector is already sorted ascending by key (the
    FlatBuffers convention for `(key)`-marked fields).
    """
    def binary_search_offset_vector(buf, vec_pos, count, target, key_fn)
        when is_function(key_fn, 2) do
      do_binary_search(buf, vec_pos, 0, count - 1, target, key_fn)
    end

    defp do_binary_search(_buf, _vec_pos, lo, hi, _target, _key_fn) when lo > hi, do: nil

    defp do_binary_search(buf, vec_pos, lo, hi, target, key_fn) do
      mid = div(lo + hi, 2)
      elem_pos = vector_elem_pos(vec_pos, mid, 4)
      table_pos = follow_uoffset(buf, elem_pos)
      key = key_fn.(buf, table_pos)

      cond do
        key == target -> table_pos
        compare_keys(key, target) < 0 -> do_binary_search(buf, vec_pos, mid + 1, hi, target, key_fn)
        true -> do_binary_search(buf, vec_pos, lo, mid - 1, target, key_fn)
      end
    end

    # Three-way compare for arbitrary keys (numbers, strings, atoms).
    # Returns negative / 0 / positive Erlang-style.
    defp compare_keys(a, b) when is_binary(a) and is_binary(b) do
      cond do
        a < b -> -1
        a > b -> 1
        true -> 0
      end
    end

    defp compare_keys(a, b) when is_number(a) and is_number(b), do: a - b
    defp compare_keys(a, b), do: if(a < b, do: -1, else: if(a > b, do: 1, else: 0))

    # ---------------------------------------------------------------------
    # Verifier primitives — used by generated `verify/1` to bounds-check
    # every offset before the reader follows it. Returning `:ok` or
    # `{:error, reason}` (no exceptions) keeps the verifier predictable
    # in the face of malicious input.
    # ---------------------------------------------------------------------

    @doc "Check that `buf` is at least `n` bytes long."
    def verify_size(buf, n) when is_binary(buf) and is_integer(n) do
      if byte_size(buf) >= n, do: :ok, else: {:error, {:buffer_too_small, n}}
    end

    @doc "Check that `[off, off+len)` is inside `buf`."
    def verify_bounds(buf, off, len) do
      cond do
        off < 0 -> {:error, {:negative_offset, off}}
        len < 0 -> {:error, {:negative_length, len}}
        off + len > byte_size(buf) -> {:error, {:out_of_bounds, off, len}}
        true -> :ok
      end
    end

    @doc """
    Read a uoffset_t at `pos` and return `{:ok, target_pos}` if the
    target is within the buffer, `{:error, reason}` otherwise.
    """
    def verify_follow_uoffset(buf, pos) do
      with :ok <- verify_bounds(buf, pos, 4) do
        target = pos + read_u32(buf, pos)

        cond do
          target < 0 -> {:error, {:bad_uoffset, pos, target}}
          target >= byte_size(buf) -> {:error, {:bad_uoffset, pos, target}}
          true -> {:ok, target}
        end
      end
    end

    @doc """
    Verify a length-prefixed string at `pos` (where the u32 length
    lives). Checks the length, that the bytes fit, and that the null
    terminator is present.
    """
    def verify_string_at(buf, pos) do
      with :ok <- verify_bounds(buf, pos, 4),
           len = read_u32(buf, pos),
           :ok <- verify_bounds(buf, pos + 4, len + 1) do
        if :binary.at(buf, pos + 4 + len) == 0,
          do: :ok,
          else: {:error, {:missing_null_terminator, pos}}
      end
    end

    @doc """
    Verify a vector of `elem_size`-byte elements at `pos`. Returns
    `{:ok, count}` on success.
    """
    def verify_vector_at(buf, pos, elem_size) do
      with :ok <- verify_bounds(buf, pos, 4),
           count = read_u32(buf, pos),
           :ok <- verify_bounds(buf, pos + 4, count * elem_size) do
        {:ok, count}
      end
    end

    @doc """
    Verify a table header at `table_pos`. Returns
    `{:ok, vt_size, inline_size}` so the caller can iterate slots.
    """
    def verify_table_header(buf, table_pos) do
      with :ok <- verify_bounds(buf, table_pos, 4) do
        soffset = read_i32(buf, table_pos)
        vt_pos = table_pos - soffset

        with :ok <- verify_bounds(buf, vt_pos, 4) do
          vt_size = read_u16(buf, vt_pos)
          inline_size = read_u16(buf, vt_pos + 2)

          cond do
            vt_size < 4 ->
              {:error, {:bad_vtable_size, vt_pos, vt_size}}

            rem(vt_size, 2) != 0 ->
              {:error, {:bad_vtable_size, vt_pos, vt_size}}

            true ->
              with :ok <- verify_bounds(buf, vt_pos, vt_size),
                   :ok <- verify_bounds(buf, table_pos, inline_size) do
                {:ok, vt_pos, vt_size, inline_size}
              end
          end
        end
      end
    end

    # ---------------------------------------------------------------------
    # Builder
    # ---------------------------------------------------------------------

    defmodule Builder do
      @moduledoc "FlatBuffers builder state."

      @type t :: %__MODULE__{
              bytes: iolist(),
              size: non_neg_integer(),
              minalign: pos_integer(),
              current_object: nil | %{start_size: non_neg_integer(), slots: [{pos_integer(), non_neg_integer()}]}
            }

      defstruct bytes: [], size: 0, minalign: 1, current_object: nil
    end

    @doc "Create a new builder."
    def new_builder, do: %Builder{}

    @doc "Finalize the builder into the resulting binary."
    def to_binary(%Builder{bytes: bytes}), do: IO.iodata_to_binary(bytes)

    @doc "Current size of the builder."
    def size(%Builder{size: size}), do: size

    # Push a raw binary without alignment.
    defp push_raw(%Builder{} = b, bin) when is_binary(bin) do
      case byte_size(bin) do
        0 -> b
        n -> %{b | bytes: [bin | b.bytes], size: b.size + n}
      end
    end

    defp pad_to(pos, n) do
      r = rem(pos, n)
      if r == 0, do: 0, else: n - r
    end

    @doc "Pad until current size is a multiple of `n`, updating minalign."
    def align(b, n) do
      pad = pad_to(b.size, n)

      b
      |> Map.update!(:minalign, &max(&1, n))
      |> push_raw(:binary.copy(<<0>>, pad))
    end

    @doc """
    Pad so that pushing `len` more bytes will land at a multiple of `n`.
    Equivalent to `align(b.size + len, n)` but without writing those bytes.
    """
    def pre_align(b, len, n) do
      pad = pad_to(b.size + len, n)

      b
      |> Map.update!(:minalign, &max(&1, n))
      |> push_raw(:binary.copy(<<0>>, pad))
    end

    # Scalar pushes — return %Builder{} only (the addr is `b.size` after the call).

    def push_u8(b, v), do: b |> align(1) |> push_raw(<<v::8>>)
    def push_i8(b, v), do: b |> align(1) |> push_raw(<<v::signed-8>>)
    def push_u16(b, v), do: b |> align(2) |> push_raw(<<v::little-16>>)
    def push_i16(b, v), do: b |> align(2) |> push_raw(<<v::little-signed-16>>)
    def push_u32(b, v), do: b |> align(4) |> push_raw(<<v::little-32>>)
    def push_i32(b, v), do: b |> align(4) |> push_raw(<<v::little-signed-32>>)
    def push_u64(b, v), do: b |> align(8) |> push_raw(<<v::little-64>>)
    def push_i64(b, v), do: b |> align(8) |> push_raw(<<v::little-signed-64>>)
    # NaN/Infinity have no regular-float representation in Erlang, so we
    # write the canonical IEEE 754 bit pattern directly.
    def push_f32(b, :nan), do: b |> align(4) |> push_raw(<<0x7FC00000::little-32>>)
    def push_f32(b, :infinity), do: b |> align(4) |> push_raw(<<0x7F800000::little-32>>)
    def push_f32(b, :neg_infinity), do: b |> align(4) |> push_raw(<<0xFF800000::little-32>>)
    def push_f32(b, v), do: b |> align(4) |> push_raw(<<v::little-float-32>>)

    def push_f64(b, :nan), do: b |> align(8) |> push_raw(<<0x7FF8000000000000::little-64>>)

    def push_f64(b, :infinity),
      do: b |> align(8) |> push_raw(<<0x7FF0000000000000::little-64>>)

    def push_f64(b, :neg_infinity),
      do: b |> align(8) |> push_raw(<<0xFFF0000000000000::little-64>>)

    def push_f64(b, v), do: b |> align(8) |> push_raw(<<v::little-float-64>>)
    def push_bool(b, v), do: push_u8(b, if(v, do: 1, else: 0))

    # ---------------------------------------------------------------------
    # Strings
    # ---------------------------------------------------------------------

    @doc "Create a string in the buffer. Returns `{builder, addr}`."
    def create_string(b, str) when is_binary(str) do
      len = byte_size(str)
      b = pre_align(b, len + 1, 4)
      b = push_raw(b, <<0>>)
      b = push_raw(b, str)
      b = b |> Map.update!(:minalign, &max(&1, 4)) |> push_raw(<<len::little-32>>)
      {b, b.size}
    end

    # ---------------------------------------------------------------------
    # Standalone structs (used by union variants of struct type)
    # ---------------------------------------------------------------------

    @doc """
    Push a struct's pre-serialized bytes as a standalone object, aligned
    to `struct_align`. Returns `{builder, addr}` so the caller can use
    `addr` as a uoffset target. Used by union variants of struct type
    (struct-in-table is inline; struct-in-union is referenced by offset).
    """
    def create_struct(b, bin, struct_align) when is_binary(bin) do
      b =
        b
        |> align(struct_align)
        |> push_raw(bin)

      {b, b.size}
    end

    # ---------------------------------------------------------------------
    # Vectors
    # ---------------------------------------------------------------------

    @doc """
    Open a vector of `count` elements with the given element size and
    alignment. Caller pushes elements in REVERSE index order (last element
    first), then calls `end_vector/2`.
    """
    def start_vector(b, count, elem_size, elem_align) do
      total = count * elem_size

      b
      |> pre_align(total, 4)
      |> pre_align(total, elem_align)
    end

    @doc "Write the vector's count. Returns `{builder, addr}` where addr points to the count."
    def end_vector(b, count) do
      b =
        b
        |> Map.update!(:minalign, &max(&1, 4))
        |> push_raw(<<count::little-32>>)

      {b, b.size}
    end

    @doc "Convenience: build a vector of scalars in one call."
    def create_scalar_vector(b, values, elem_size, elem_align, push_fn) do
      count = length(values)
      b = start_vector(b, count, elem_size, elem_align)

      b =
        values
        |> Enum.reverse()
        |> Enum.reduce(b, fn v, acc -> push_fn.(acc, v) end)

      end_vector(b, count)
    end

    @doc """
    Build a vector of uoffsets (already-written sub-objects: strings,
    tables). `addrs` is a list of addresses in source order.
    """
    def create_offset_vector(b, addrs) do
      count = length(addrs)
      b = start_vector(b, count, 4, 4)
      # Push offsets in reverse order. Each uoffset stored value =
      # (size after this push) - target_addr.
      b =
        addrs
        |> Enum.reverse()
        |> Enum.reduce(b, fn addr, acc ->
          acc = align(acc, 4)
          uoff = acc.size + 4 - addr
          push_raw(acc, <<uoff::little-32>>)
        end)

      end_vector(b, count)
    end

    # ---------------------------------------------------------------------
    # Tables
    # ---------------------------------------------------------------------

    @doc "Begin a table. The matching `end_table/1` finalizes it."
    def start_table(b) do
      if b.current_object != nil, do: raise(ArgumentError, "table already in progress")
      %{b | current_object: %{start_size: b.size, slots: []}}
    end

    @doc "Record that `slot_num` (vtable byte offset) is filled at `field_addr`."
    def slot(b, slot_num, field_addr) do
      obj = b.current_object
      %{b | current_object: %{obj | slots: [{slot_num, field_addr} | obj.slots]}}
    end

    @doc """
    Push a scalar field with vtable slot tracking. If `value == default`,
    the field is omitted from the vtable (so decoders fall back to default).
    """
    def add_field_scalar(b, slot_num, value, default, push_fn) do
      if value == default do
        b
      else
        b = push_fn.(b, value)
        slot(b, slot_num, b.size)
      end
    end

    @doc """
    Push a uoffset field pointing at a previously-built sub-object (string,
    vector, table). `target_addr` of `nil` means the field is omitted.
    """
    def add_field_offset(b, slot_num, target_addr) do
      case target_addr do
        nil ->
          b

        addr ->
          b = align(b, 4)
          uoff = b.size + 4 - addr
          b = push_raw(b, <<uoff::little-32>>)
          slot(b, slot_num, b.size)
      end
    end

    @doc """
    Push inline struct bytes as a field. `bin` is the serialized struct.
    """
    def add_field_struct(b, slot_num, bin, struct_align) do
      b = align(b, struct_align)
      b = push_raw(b, bin)
      slot(b, slot_num, b.size)
    end

    @doc "Finish a table; returns `{builder, table_addr}`."
    def end_table(b) do
      obj = b.current_object
      slots = obj.slots
      start_size = obj.start_size

      max_slot =
        case slots do
          [] -> 0
          _ -> slots |> Enum.map(&elem(&1, 0)) |> Enum.max()
        end

      num_field_slots =
        cond do
          max_slot < 4 -> 0
          true -> div(max_slot - 4, 2) + 1
        end

      max_voffset = 4 + num_field_slots * 2

      b = align(b, 4)
      s_addr = b.size + 4
      table_object_size = s_addr - start_size

      locs_by_slot = Map.new(slots)

      entries =
        if num_field_slots == 0 do
          []
        else
          for i <- 0..(num_field_slots - 1) do
            slot_num = 4 + i * 2

            case Map.fetch(locs_by_slot, slot_num) do
              {:ok, f_addr} -> <<s_addr - f_addr::little-16>>
              :error -> <<0::little-16>>
            end
          end
        end

      vt_bin =
        IO.iodata_to_binary([
          <<max_voffset::little-16>>,
          <<table_object_size::little-16>>,
          entries
        ])

      v_addr = s_addr + max_voffset
      soffset_value = v_addr - s_addr

      b = push_raw(b, <<soffset_value::little-signed-32>>)

      b =
        b
        |> Map.update!(:minalign, &max(&1, 2))
        |> push_raw(vt_bin)

      _ = v_addr
      {%{b | current_object: nil}, s_addr}
    end

    # ---------------------------------------------------------------------
    # Finish
    # ---------------------------------------------------------------------

    @doc """
    Finalize the buffer. Writes the root uoffset, optional file_identifier,
    optional size prefix, with appropriate alignment.
    """
    def finish(b, root_addr, opts \\ []) do
      file_id = Keyword.get(opts, :file_identifier)
      size_prefix? = Keyword.get(opts, :size_prefix, false)

      total =
        4 +
          if(file_id, do: 4, else: 0) +
          if(size_prefix?, do: 4, else: 0)

      b = pre_align(b, total, b.minalign)

      b =
        if file_id do
          push_raw(b, file_id)
        else
          b
        end

      uoff = b.size + 4 - root_addr
      b = push_raw(b, <<uoff::little-32>>)

      b =
        if size_prefix? do
          push_raw(b, <<b.size::little-32>>)
        else
          b
        end

      b
    end
  end
  '''

  @doc """
  Generate the wire helper module source.

  Returns `{module_name_atom, source_string}`.
  """
  @spec generate(module()) :: {module(), String.t()}
  def generate(module_name) when is_atom(module_name) do
    src = String.replace(@template, "<%= MODULE %>", inspect(module_name))
    {module_name, src}
  end
end
