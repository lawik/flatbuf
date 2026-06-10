defmodule Flatbuf.Codegen.Union do
  @moduledoc """
  Emits an Elixir module for a FlatBuffers `union` declaration.

  The module owns the discriminator ↔ variant mapping and the two
  per-direction dispatch helpers:

  * `decode_variant/3` — given a discriminator integer and the
    referenced position in the buffer, return `{variant_atom, value}`.
  * `build_variant/3` — given a variant atom and a value, write it into
    the buffer and return `{builder, addr}` so the calling table can
    add `(discriminator, uoffset)` as a pair of fields.

  Variant 0 is always the implicit `:NONE`.
  """

  alias Flatbuf.Codegen.Naming
  alias Flatbuf.Schema
  alias Flatbuf.Schema.Struct, as: SchemaStruct
  alias Flatbuf.Schema.Union

  @spec generate(Union.t(), Schema.t(), keyword()) :: {module(), String.t()}
  def generate(%Union{} = u, %Schema{} = schema, opts) do
    wire_module = Keyword.fetch!(opts, :wire_module)
    # The `:namespace` override is threaded explicitly (trailing `ns`
    # arg) through every helper that maps FQNs to module names.
    ns = Keyword.get(opts, :namespace)
    module_name = fqn_to_module(u.name, ns)
    module_atom = Module.concat([module_name])

    type_spec = build_type_spec(u, schema, ns)
    disc_clauses = build_disc_clauses(u)
    atom_clauses = build_atom_clauses(u)
    decode_clauses = build_decode_clauses(u, schema, ns)
    build_clauses = build_build_clauses(u, schema, ns)
    to_json_clauses = build_to_json_clauses(u, ns)
    from_json_clauses = build_from_json_clauses(u, ns)
    verify_clauses = build_verify_clauses(u, ns)

    # Every variant's `__verify_variant__/4` clause threads the error
    # path through `Wire.verify_path/2`, so any union with variants
    # needs the Wire alias. Only a (degenerate) empty union skips it.
    needs_wire? = u.variants != []

    wire_alias = if needs_wire?, do: "  alias #{inspect(wire_module)}, as: Wire\n", else: ""

    # A signed underlying type (`union U : int { … }`) admits negative
    # discriminator values, so the spec widens from the historical
    # non_neg_integer().
    disc_t =
      if u.underlying_type in [:i8, :i16, :i32, :i64],
        do: "integer()",
        else: "non_neg_integer()"

    source = """
    defmodule #{module_name} do
      @moduledoc "Generated from FlatBuffers union #{u.name}. Do not edit."

    #{wire_alias}
      @type t :: #{type_spec}

      @doc "Integer discriminator for a variant atom (0 for :NONE)."
      @spec discriminator(atom()) :: #{disc_t}
      def discriminator(:NONE), do: 0
    #{disc_clauses}
      @doc "Variant atom for an integer discriminator."
      @spec variant_atom(#{disc_t}) :: atom() | nil
      def variant_atom(0), do: :NONE
    #{atom_clauses}  def variant_atom(_), do: nil

      @doc \"\"\"
      Decode a union value at `abs_pos`, given its discriminator. The
      `abs_pos` is the absolute target of the uoffset_t the table field
      stored — i.e. for a table variant, the table position; for a
      string variant, the start of the u32 length; for a struct variant,
      the start of the inline struct bytes.
      \"\"\"
      def decode_variant(_buf, 0, _abs_pos), do: nil
    #{decode_clauses}  def decode_variant(_buf, disc, _abs_pos), do: {:unknown_variant, disc}

      @doc \"\"\"
      Build a variant value into the builder. Returns `{builder, addr}`.
      For `:NONE`, returns `{builder, nil}`.
      \"\"\"
      def build_variant(b, :NONE, _value), do: {b, nil}
    #{build_clauses}
      # JSON helpers — used by table codegen for the paired `_type` and
      # value keys flatc emits.

      @doc false
      # flatc emits the union `_type` key as `"NONE"` (not omitted) when
      # the discriminator is 0, so match that to keep JSON comparisons
      # aligned. The value side stays nil and gets dropped by the
      # caller's `Map.reject`.
      def __to_json_type__(nil), do: "NONE"
      def __to_json_type__({variant, _value}), do: Atom.to_string(variant)

      @doc false
      def __to_json_value__(nil), do: nil
    #{to_json_clauses}
      @doc false
      def __from_json__(nil, _value), do: nil
      def __from_json__("NONE", _value), do: nil
    #{from_json_clauses}
      @doc false
      def __verify_variant__(_buf, 0, _abs_pos, _depth), do: :ok
    #{verify_clauses}  def __verify_variant__(_buf, disc, _abs_pos, _depth), do: {:error, {:unknown_union_variant, disc}, []}
    end
    """

    {module_atom, source}
  end

  defp build_type_spec(u, _schema, ns) do
    parts =
      Enum.map(u.variants, fn {name, type, _disc} ->
        "{#{inspect(name)}, #{variant_type_t(type, ns)}}"
      end)

    Enum.join(["nil" | parts], " | ")
  end

  defp variant_type_t({:table, fqn}, ns), do: "#{fqn_to_module(fqn, ns)}.t()"
  defp variant_type_t({:struct, fqn}, ns), do: "#{fqn_to_module(fqn, ns)}.t()"
  defp variant_type_t(:string, _ns), do: "String.t()"

  defp build_disc_clauses(u) do
    u.variants
    |> Enum.map_join("", fn {name, _type, disc} ->
      "  def discriminator(#{inspect(name)}), do: #{disc}\n"
    end)
  end

  # flatc permits two variants sharing one discriminator value; the
  # first declaration wins on the read side (same as a C++ enum with
  # duplicate enumerators). Dedup keeps the generated clause heads
  # from triggering "this clause cannot match" warnings.
  defp dedup_by_disc(variants), do: Enum.uniq_by(variants, fn {_name, _type, disc} -> disc end)

  defp build_atom_clauses(u) do
    u.variants
    |> dedup_by_disc()
    |> Enum.map_join("", fn {name, _type, disc} ->
      "  def variant_atom(#{disc}), do: #{inspect(name)}\n"
    end)
  end

  defp build_decode_clauses(u, _schema, ns) do
    u.variants
    |> dedup_by_disc()
    |> Enum.map_join("", fn {name, type, disc} ->
      body =
        case type do
          {:table, fqn} ->
            "{#{inspect(name)}, #{fqn_to_module(fqn, ns)}.decode_at(buf, abs_pos)}"

          {:struct, fqn} ->
            "{#{inspect(name)}, #{fqn_to_module(fqn, ns)}.decode_at(buf, abs_pos)}"

          :string ->
            "{#{inspect(name)}, Wire.read_string_at(buf, abs_pos)}"
        end

      "  def decode_variant(buf, #{disc}, abs_pos), do: #{body}\n"
    end)
  end

  defp build_build_clauses(u, schema, ns) do
    u.variants
    |> Enum.map_join("", fn {name, type, _disc} ->
      body =
        case type do
          {:table, fqn} ->
            "#{fqn_to_module(fqn, ns)}.build(b, value)"

          {:struct, fqn} ->
            %SchemaStruct{align: al} = Schema.fetch(schema, fqn)
            "Wire.create_struct(b, #{fqn_to_module(fqn, ns)}.encode(value), #{al})"

          :string ->
            "Wire.create_string(b, value)"
        end

      "  def build_variant(b, #{inspect(name)}, value), do: #{body}\n"
    end)
  end

  defp build_to_json_clauses(u, ns) do
    u.variants
    |> Enum.map_join("", fn {name, type, _disc} ->
      expr =
        case type do
          {:table, fqn} -> "#{fqn_to_module(fqn, ns)}.__to_json_map__(value)"
          {:struct, fqn} -> "#{fqn_to_module(fqn, ns)}.__to_json_map__(value)"
          :string -> "value"
        end

      "  def __to_json_value__({#{inspect(name)}, value}), do: #{expr}\n"
    end)
  end

  defp build_from_json_clauses(u, ns) do
    u.variants
    |> Enum.map_join("", fn {name, type, _disc} ->
      expr =
        case type do
          {:table, fqn} ->
            "{#{inspect(name)}, #{fqn_to_module(fqn, ns)}.__from_json_map__(value)}"

          {:struct, fqn} ->
            "{#{inspect(name)}, #{fqn_to_module(fqn, ns)}.__from_json_map__(value)}"

          :string ->
            "{#{inspect(name)}, value}"
        end

      "  def __from_json__(#{inspect(Atom.to_string(name))}, value), do: #{expr}\n"
    end)
  end

  defp build_verify_clauses(u, ns) do
    u.variants
    |> dedup_by_disc()
    |> Enum.map_join("", fn {name, type, disc} ->
      # Only the table variant recurses with `depth - 1`; struct and
      # string variants ignore depth, so underscore it on those clauses
      # to keep the compiler quiet. Every clause wraps its result in
      # `Wire.verify_path/2` so the error path gains the variant atom;
      # the calling table prepends the field name on top.
      {expr, depth_param} =
        case type do
          {:table, fqn} ->
            {"#{fqn_to_module(fqn, ns)}.__verify_at__(buf, abs_pos, depth)", "depth"}

          {:struct, fqn} ->
            {"Wire.verify_bounds(buf, abs_pos, #{fqn_to_module(fqn, ns)}.__flatbuf__(:struct_size))",
             "_depth"}

          :string ->
            {"Wire.verify_string_at(buf, abs_pos)", "_depth"}
        end

      "  def __verify_variant__(buf, #{disc}, abs_pos, #{depth_param}), " <>
        "do: Wire.verify_path(#{expr}, #{inspect(name)})\n"
    end)
  end

  defp fqn_to_module(fqn, ns), do: Naming.module_name(fqn, ns)
end
