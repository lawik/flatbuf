defmodule Flatbuf.DeprecatedFieldTest do
  @moduledoc """
  Pins `(deprecated)` field semantics across the whole generated
  surface (SPEC: "skip in encode, accept in decode").

  Reference semantics, probed against flatc 25.12.19:

    * Generated code (C++): the deprecated field gets no accessor, no
      builder setter, and the generated verifier skips it entirely —
      but its id keeps the vtable slot reserved, so the fields after
      it keep their slots.
    * flatc's schema-driven JSON tooling treats deprecated fields as
      *live*: `--binary` accepts a supplied value and writes the slot;
      `--json` prints the field whenever the buffer contains it.

  Our pinned behavior (generated-code semantics, with a richer read
  side):

    * defstruct/typespec keep the field (with its type default).
    * encode/1 silently ignores any supplied value — the slot is never
      written, but the following fields keep their id-derived slots.
    * decode/1 exposes a deprecated field's value when the buffer
      physically contains it (flatc's generated readers can't; its
      `--json` tool does the same as us).
    * verify/1 still bounds-checks deprecated content (our decoder
      dereferences it, so the verifier must cover it), but drops the
      `required` enforcement for deprecated fields.
    * to_json/1 omits deprecated fields — this intentionally diverges
      from `flatc --json`, which prints them; see the differential
      tests at the bottom.
    * from_json/1 accepts a document that supplies the field and
      populates the struct; a subsequent encode drops it again.
  """

  use ExUnit.Case, async: false

  alias Flatbuf.Test.CodegenCompiler
  alias Flatbuf.Test.Flatc

  # v1: every field live. v2: same table after deprecating `b` (an
  # offset-typed field) and `d` (a scalar). Explicit ids keep the two
  # layouts byte-compatible, so buffers cross-decode between them.
  @live_schema """
  namespace DepLive;

  table T {
    a: int (id: 0);
    b: string (id: 1);
    c: short (id: 2);
    d: long (id: 3);
    e: string (id: 4);
  }

  root_type T;
  """

  @gone_schema """
  namespace DepGone;

  table T {
    a: int (id: 0);
    b: string (id: 1, deprecated);
    c: short (id: 2);
    d: long (id: 3, deprecated);
    e: string (id: 4);
  }

  root_type T;
  """

  # `required` on a deprecated field: the encoder never writes the
  # slot, so enforcement is dropped (flatc's generated code does the
  # same — the required check disappears together with the field).
  @req_schema """
  namespace DepReq;

  table T {
    body: string (id: 0);
    legacy: string (id: 1, deprecated, required);
  }

  root_type T;
  """

  # Every field deprecated: encode must still produce a decodable
  # (empty) table.
  @all_schema """
  namespace DepAll;

  table T {
    x: int (id: 0, deprecated);
    y: string (id: 1, deprecated);
  }

  root_type T;
  """

  CodegenCompiler.compile_source!(@live_schema, wire_module: Flatbuf.DeprecatedFieldTest.WireLive)
  CodegenCompiler.compile_source!(@gone_schema, wire_module: Flatbuf.DeprecatedFieldTest.WireGone)
  CodegenCompiler.compile_source!(@req_schema, wire_module: Flatbuf.DeprecatedFieldTest.WireReq)
  CodegenCompiler.compile_source!(@all_schema, wire_module: Flatbuf.DeprecatedFieldTest.WireAll)

  alias Flatbuf.DeprecatedFieldTest.WireGone

  @full_value %{a: 42, b: "hello", c: 7, d: 9_876_543_210, e: "world"}

  # vtable slot indexes for ids 0..4 (4 + 2 * id).
  @slot_a 4
  @slot_b 6
  @slot_c 8
  @slot_d 10
  @slot_e 12

  defp live_buffer do
    {:ok, bin} = DepLive.T.encode(@full_value)
    bin
  end

  describe "struct shape" do
    test "deprecated fields stay in the defstruct with their type defaults" do
      assert %DepGone.T{} == %DepGone.T{a: 0, b: nil, c: 0, d: 0, e: nil}
      assert Map.has_key?(%DepGone.T{}, :b)
      assert Map.has_key?(%DepGone.T{}, :d)
    end
  end

  describe "encode skips deprecated fields" do
    test "a supplied value is silently ignored — the slot is never written" do
      {:ok, bin} = DepGone.T.encode(@full_value)
      pos = WireGone.root_table_pos(bin)

      assert WireGone.read_vtable_field(bin, pos, @slot_b) == 0
      assert WireGone.read_vtable_field(bin, pos, @slot_d) == 0
      assert WireGone.read_vtable_field(bin, pos, @slot_a) != 0
      assert WireGone.read_vtable_field(bin, pos, @slot_c) != 0
      assert WireGone.read_vtable_field(bin, pos, @slot_e) != 0

      refute bin =~ "hello"
    end

    test "supplying the deprecated field is byte-identical to omitting it" do
      {:ok, with_dep} = DepGone.T.encode(@full_value)
      {:ok, without_dep} = DepGone.T.encode(%{a: 42, c: 7, e: "world"})
      assert with_dep == without_dep
    end

    test "even a wrong-typed value for a deprecated field is ignored, not an error" do
      # The key is never read by build/2, exactly like any unknown map
      # key — no scalar/type validation runs for deprecated fields.
      assert {:ok, _bin} = DepGone.T.encode(%{a: 1, b: 12_345, d: "not a long"})
    end

    test "round-trip through the deprecated schema loses the deprecated values" do
      {:ok, bin} = DepGone.T.encode(@full_value)
      assert {:ok, decoded} = DepGone.T.decode(bin)
      # b/d come back as struct defaults: the slots were never written.
      assert decoded == %DepGone.T{a: 42, b: nil, c: 7, d: 0, e: "world"}
    end

    test "an all-fields-deprecated table encodes to a decodable empty table" do
      {:ok, bin} = DepAll.T.encode(%{x: 99, y: "ghost"})
      assert :ok = DepAll.T.verify(bin)
      assert {:ok, %DepAll.T{x: 0, y: nil}} = DepAll.T.decode(bin)
    end
  end

  describe "vtable slot reservation" do
    test "fields after a deprecated one keep their id-derived slots" do
      # The pre-deprecation module reads a deprecated-schema buffer with
      # every live field intact — only possible if c and e stayed at
      # the slots their ids assign.
      {:ok, bin} = DepGone.T.encode(@full_value)
      assert {:ok, decoded} = DepLive.T.decode(bin)
      assert decoded.a == 42
      assert decoded.b == nil
      assert decoded.c == 7
      assert decoded.d == 0
      assert decoded.e == "world"
    end
  end

  describe "decode accepts buffers that contain the deprecated field" do
    test "deprecated values are exposed and the following fields read correctly" do
      # Encoded with the pre-deprecation schema, so the buffer
      # physically contains b and d; decoded with the deprecated one.
      assert {:ok, decoded} = DepGone.T.decode(live_buffer())
      assert decoded.b == "hello"
      assert decoded.d == 9_876_543_210
      assert decoded.a == 42
      assert decoded.c == 7
      assert decoded.e == "world"
    end

    test "verify accepts a buffer containing the deprecated field" do
      assert :ok = DepGone.T.verify(live_buffer())
    end

    test "verify still bounds-checks deprecated content the decoder would read" do
      # flatc's generated verifier skips deprecated slots entirely; we
      # keep checking them because our decoder dereferences them. Point
      # the deprecated string's uoffset out of bounds: verify must
      # reject what decode would crash on.
      bin = live_buffer()
      pos = WireGone.root_table_pos(bin)
      voff = WireGone.read_vtable_field(bin, pos, @slot_b)
      assert voff != 0

      field_pos = pos + voff
      <<pre::binary-size(field_pos), _::32, post::binary>> = bin
      corrupt = pre <> <<0xFFFFFFFF::little-32>> <> post

      assert {:error, _, _} = DepGone.T.verify(corrupt)
    end
  end

  describe "JSON surface" do
    test "to_json omits deprecated fields even when the struct holds values" do
      {:ok, decoded} = DepGone.T.decode(live_buffer())
      assert decoded.b == "hello"

      json = decoded |> DepGone.T.to_json() |> JSON.decode!()
      assert json == %{"a" => 42, "c" => 7, "e" => "world"}
      refute Map.has_key?(json, "b")
      refute Map.has_key?(json, "d")
    end

    test "from_json accepts a deprecated key and populates the struct" do
      doc = ~s({"a": 1, "b": "still here", "c": 2, "d": 3, "e": "x"})
      assert {:ok, decoded} = DepGone.T.from_json(doc)
      assert decoded.b == "still here"
      assert decoded.d == 3

      # ... but a subsequent encode drops it on the wire again.
      {:ok, bin} = DepGone.T.encode(decoded)
      assert {:ok, reread} = DepGone.T.decode(bin)
      assert reread.b == nil
      assert reread.d == 0
      assert reread.e == "x"
    end
  end

  describe "deprecated + required" do
    test "required is not enforced for a deprecated field on encode" do
      assert {:ok, bin} = DepReq.T.encode(%{body: "no legacy"})
      assert :ok = DepReq.T.verify(bin)
      assert {:ok, %DepReq.T{body: "no legacy", legacy: nil}} = DepReq.T.decode(bin)
    end
  end

  # ---------------------------------------------------------------------
  # Differential vs flatc
  # ---------------------------------------------------------------------

  @flatc_ok (try do
               _ = Flatc.ensure_available!()
               true
             rescue
               _ -> false
             end)

  if @flatc_ok do
    describe "differential vs flatc" do
      setup do
        dir = Path.join(System.tmp_dir!(), "flatbuf_dep_#{:erlang.unique_integer([:positive])}")
        File.mkdir_p!(dir)

        live_path = Path.join(dir, "live.fbs")
        gone_path = Path.join(dir, "gone.fbs")
        File.write!(live_path, @live_schema)
        File.write!(gone_path, @gone_schema)

        on_exit(fn -> File.rm_rf!(dir) end)
        {:ok, live_path: live_path, gone_path: gone_path}
      end

      test "flatc-encoded pre-deprecation buffer decodes under the deprecated schema",
           %{live_path: live_path} do
        json = ~s({"a": 42, "b": "hello", "c": 7, "d": 9876543210, "e": "world"})
        {:ok, bin} = Flatc.json_to_binary(live_path, json)

        assert :ok = DepGone.T.verify(bin)
        assert {:ok, decoded} = DepGone.T.decode(bin)
        assert decoded.b == "hello"
        assert decoded.d == 9_876_543_210
        assert decoded.a == 42
        assert decoded.c == 7
        assert decoded.e == "world"
      end

      test "pinned divergence: flatc --json prints deprecated fields, our to_json drops them",
           %{gone_path: gone_path} do
        bin = live_buffer()

        {:ok, flatc_json} = Flatc.binary_to_json(gone_path, bin, defaults_json: false)
        assert flatc_json["b"] == "hello"
        assert flatc_json["d"] == 9_876_543_210

        {:ok, decoded} = DepGone.T.decode(bin)
        ours = decoded |> DepGone.T.to_json() |> JSON.decode!()
        refute Map.has_key?(ours, "b")
        refute Map.has_key?(ours, "d")

        # Everything else agrees.
        assert Map.drop(flatc_json, ["b", "d"]) == ours
      end

      test "flatc reads our deprecated-schema encoding with the slots simply absent",
           %{gone_path: gone_path} do
        {:ok, bin} = DepGone.T.encode(@full_value)
        {:ok, flatc_json} = Flatc.binary_to_json(gone_path, bin, defaults_json: false)

        assert flatc_json == %{"a" => 42, "c" => 7, "e" => "world"}
      end
    end
  end
end
