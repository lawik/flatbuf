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

    def read_f32(buf, off) do
      <<v::little-float-32>> = binary_part(buf, off, 4)
      v
    end

    def read_f64(buf, off) do
      <<v::little-float-64>> = binary_part(buf, off, 8)
      v
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
    def push_f32(b, v), do: b |> align(4) |> push_raw(<<v::little-float-32>>)
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
