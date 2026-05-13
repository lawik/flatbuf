defmodule Flatbuf.Schema.Parser do
  @moduledoc """
  Recursive-descent parser for FlatBuffers `.fbs` source.

  Consumes tokens produced by `Flatbuf.Schema.Lexer` and returns a list of
  declaration records (the CST). The resolver later promotes these into the
  semantic `%Flatbuf.Schema{}`.
  """

  alias Flatbuf.Schema.Lexer

  @scalar_types %{
    "bool" => :bool,
    "byte" => :i8,
    "ubyte" => :u8,
    "int8" => :i8,
    "uint8" => :u8,
    "short" => :i16,
    "ushort" => :u16,
    "int16" => :i16,
    "uint16" => :u16,
    "int" => :i32,
    "uint" => :u32,
    "int32" => :i32,
    "uint32" => :u32,
    "long" => :i64,
    "ulong" => :u64,
    "int64" => :i64,
    "uint64" => :u64,
    "float" => :f32,
    "float32" => :f32,
    "double" => :f64,
    "float64" => :f64,
    "string" => :string
  }

  @type decl ::
          {:include, String.t(), pos_integer()}
          | {:namespace, String.t(), pos_integer()}
          | {:root_type, String.t(), pos_integer()}
          | {:file_identifier, String.t(), pos_integer()}
          | {:file_extension, String.t(), pos_integer()}
          | {:attribute_decl, String.t(), pos_integer()}
          | {:table, map()}
          | {:struct, map()}
          | {:enum, map()}

  @spec parse(binary()) :: {:ok, [decl()]} | {:error, term()}
  def parse(source) when is_binary(source) do
    with {:ok, tokens} <- Lexer.tokenize(source) do
      try do
        {:ok, parse_file(tokens, [], [])}
      catch
        {:parse_error, reason} -> {:error, reason}
      end
    end
  end

  # File-level loop -------------------------------------------------------

  defp parse_file([{:eof, _, _}], pending_docs, acc) do
    _ = pending_docs
    Enum.reverse(acc)
  end

  defp parse_file([{:doc, body, _line} | rest], pending_docs, acc) do
    parse_file(rest, pending_docs ++ [body], acc)
  end

  defp parse_file([{:kw, :include, line} | rest], _pending_docs, acc) do
    {path, rest2} = expect_string(rest, "include path")
    rest3 = expect_punct(rest2, :semi)
    parse_file(rest3, [], [{:include, path, line} | acc])
  end

  defp parse_file([{:kw, :namespace, line} | rest], _pending_docs, acc) do
    {name, rest2} = parse_dotted_name(rest)
    rest3 = expect_punct(rest2, :semi)
    parse_file(rest3, [], [{:namespace, name, line} | acc])
  end

  defp parse_file([{:kw, :root_type, line} | rest], _pending_docs, acc) do
    {name, rest2} = parse_dotted_name(rest)
    rest3 = expect_punct(rest2, :semi)
    parse_file(rest3, [], [{:root_type, name, line} | acc])
  end

  defp parse_file([{:kw, :file_identifier, line} | rest], _pending_docs, acc) do
    {id, rest2} = expect_string(rest, "file_identifier value")
    rest3 = expect_punct(rest2, :semi)
    parse_file(rest3, [], [{:file_identifier, id, line} | acc])
  end

  defp parse_file([{:kw, :file_extension, line} | rest], _pending_docs, acc) do
    {ext, rest2} = expect_string(rest, "file_extension value")
    rest3 = expect_punct(rest2, :semi)
    parse_file(rest3, [], [{:file_extension, ext, line} | acc])
  end

  defp parse_file([{:kw, :attribute, line} | rest], _pending_docs, acc) do
    case rest do
      [{:string, name, _} | rest2] ->
        rest3 = expect_punct(rest2, :semi)
        parse_file(rest3, [], [{:attribute_decl, name, line} | acc])

      [{:ident, name, _} | rest2] ->
        rest3 = expect_punct(rest2, :semi)
        parse_file(rest3, [], [{:attribute_decl, name, line} | acc])

      _ ->
        throw({:parse_error, {:expected, :attribute_name, head_line(rest)}})
    end
  end

  defp parse_file([{:kw, :table, line} | rest], pending_docs, acc) do
    {decl, rest2} = parse_type_body(rest, line, :table, pending_docs)
    parse_file(rest2, [], [decl | acc])
  end

  defp parse_file([{:kw, :struct, line} | rest], pending_docs, acc) do
    {decl, rest2} = parse_type_body(rest, line, :struct, pending_docs)
    parse_file(rest2, [], [decl | acc])
  end

  defp parse_file([{:kw, :enum, line} | rest], pending_docs, acc) do
    {decl, rest2} = parse_enum(rest, line, pending_docs)
    parse_file(rest2, [], [decl | acc])
  end

  defp parse_file([{:kw, :union, line} | rest], pending_docs, acc) do
    {decl, rest2} = parse_union(rest, line, pending_docs)
    parse_file(rest2, [], [decl | acc])
  end

  defp parse_file([{:kw, :rpc_service, line} | rest], pending_docs, acc) do
    {decl, rest2} = parse_rpc_service(rest, line, pending_docs)
    parse_file(rest2, [], [decl | acc])
  end

  defp parse_file([tok | _rest], _pending_docs, _acc) do
    throw({:parse_error, {:unexpected_token, tok}})
  end

  # Table/struct ----------------------------------------------------------

  defp parse_type_body(tokens, line, kind, docs) do
    {name, rest} = expect_ident(tokens, "type name")
    {attrs, rest2} = maybe_parse_attribute_list(rest)
    rest3 = expect_punct(rest2, :lbrace)
    {fields, rest4} = parse_fields(rest3, [], [])
    rest5 = expect_punct(rest4, :rbrace)

    decl =
      {kind,
       %{
         name: name,
         fields: fields,
         attributes: attrs,
         docs: docs,
         line: line
       }}

    {decl, rest5}
  end

  defp parse_fields([{:punct, :rbrace, _} | _] = rest, _pending_docs, acc),
    do: {Enum.reverse(acc), rest}

  defp parse_fields([{:doc, body, _line} | rest], pending_docs, acc) do
    parse_fields(rest, pending_docs ++ [body], acc)
  end

  defp parse_fields(rest, pending_docs, acc) do
    {field, rest2} = parse_field(rest, pending_docs)
    parse_fields(rest2, [], [field | acc])
  end

  defp parse_field(tokens, docs) do
    {name, rest} = expect_ident(tokens, "field name")
    rest2 = expect_punct(rest, :colon)
    {type_ref, rest3} = parse_type_ref(rest2)
    {default, rest4} = maybe_parse_default(rest3)
    {attrs, rest5} = maybe_parse_attribute_list(rest4)
    rest6 = expect_punct(rest5, :semi)

    {%{
       name: name,
       type: type_ref,
       default: default,
       attributes: attrs,
       docs: docs
     }, rest6}
  end

  defp parse_type_ref([{:punct, :lbracket, _} | rest]) do
    {inner, rest2} = parse_type_ref(rest)
    rest3 = expect_punct(rest2, :rbracket)
    {{:vector, inner}, rest3}
  end

  defp parse_type_ref([{:ident, name, _} | rest]) do
    case Map.fetch(@scalar_types, name) do
      {:ok, :string} ->
        {:string, rest}

      {:ok, scalar} ->
        {{:scalar, scalar}, rest}

      :error ->
        # User type reference; may be dotted
        case rest do
          [{:punct, :dot, _} | _] ->
            {full, rest2} = continue_dotted(rest, name)
            {{:name, full}, rest2}

          _ ->
            {{:name, name}, rest}
        end
    end
  end

  defp parse_type_ref([tok | _]),
    do: throw({:parse_error, {:expected_type_ref, tok}})

  defp parse_type_ref([]),
    do: throw({:parse_error, :unexpected_eof_in_type_ref})

  defp continue_dotted([{:punct, :dot, _} | rest], acc) do
    {next, rest2} = expect_ident(rest, "dotted name part")
    continue_dotted(rest2, acc <> "." <> next)
  end

  defp continue_dotted(rest, acc), do: {acc, rest}

  defp maybe_parse_default([{:punct, :eq, _} | rest]) do
    {val, rest2} = parse_literal(rest)
    {val, rest2}
  end

  defp maybe_parse_default(rest), do: {nil, rest}

  # Literal: handles signed numbers, strings, idents (for enum variants), bools, null
  defp parse_literal([{:punct, :minus, _} | rest]) do
    {val, rest2} = parse_literal(rest)

    case val do
      {:int, n} -> {{:int, -n}, rest2}
      {:float, :infinity} -> {{:float, :neg_infinity}, rest2}
      {:float, :neg_infinity} -> {{:float, :infinity}, rest2}
      {:float, :nan} -> {{:float, :nan}, rest2}
      {:float, f} when is_float(f) -> {{:float, -f}, rest2}
      _ -> throw({:parse_error, {:bad_negative_literal, val}})
    end
  end

  defp parse_literal([{:punct, :plus, _} | rest]), do: parse_literal(rest)
  defp parse_literal([{:int, n, _} | rest]), do: {{:int, n}, rest}
  defp parse_literal([{:float, f, _} | rest]), do: {{:float, f}, rest}
  defp parse_literal([{:string, s, _} | rest]), do: {{:string, s}, rest}
  defp parse_literal([{:kw, true, _} | rest]), do: {{:bool, true}, rest}
  defp parse_literal([{:kw, false, _} | rest]), do: {{:bool, false}, rest}
  defp parse_literal([{:kw, :null, _} | rest]), do: {:null, rest}

  defp parse_literal([{:ident, name, _} | rest]) do
    case name do
      "inf" -> {{:float, :infinity}, rest}
      "infinity" -> {{:float, :infinity}, rest}
      "nan" -> {{:float, :nan}, rest}
      _ -> {{:ident, name}, rest}
    end
  end

  # Array literal: `= [ … ]`. Used as a default for vector fields.
  # FlatBuffers can't actually express a non-empty vector default on the
  # wire, so we record whatever the schema author wrote but the codegen
  # collapses everything down to `[]` at runtime.
  defp parse_literal([{:punct, :lbracket, _} | rest]) do
    {items, rest2} = parse_array_items(rest, [])
    rest3 = expect_punct(rest2, :rbracket)
    {{:array, items}, rest3}
  end

  defp parse_literal([tok | _]),
    do: throw({:parse_error, {:expected_literal, tok}})

  defp parse_array_items([{:punct, :rbracket, _} | _] = rest, acc),
    do: {Enum.reverse(acc), rest}

  defp parse_array_items(tokens, acc) do
    {item, rest} = parse_literal(tokens)

    case rest do
      [{:punct, :comma, _} | r] -> parse_array_items(r, [item | acc])
      _ -> {Enum.reverse([item | acc]), rest}
    end
  end

  # Attribute list: (name [: value] [, ...])
  defp maybe_parse_attribute_list([{:punct, :lparen, _} | rest]) do
    {pairs, rest2} = parse_attribute_pairs(rest, [])
    rest3 = expect_punct(rest2, :rparen)
    {pairs, rest3}
  end

  defp maybe_parse_attribute_list(rest), do: {[], rest}

  defp parse_attribute_pairs([{:punct, :rparen, _} | _] = rest, acc),
    do: {Enum.reverse(acc), rest}

  defp parse_attribute_pairs(tokens, acc) do
    {name, rest} =
      case tokens do
        [{:ident, n, _} | r] ->
          {n, r}

        [{:kw, kw, _} | r] ->
          {Atom.to_string(kw), r}

        [{:string, n, _} | r] ->
          {n, r}

        _ ->
          throw({:parse_error, {:expected, :attribute_name, head_line(tokens)}})
      end

    {value, rest2} =
      case rest do
        [{:punct, :colon, _} | r] -> parse_literal(r)
        _ -> {nil, rest}
      end

    case rest2 do
      [{:punct, :comma, _} | r] -> parse_attribute_pairs(r, [{name, value} | acc])
      _ -> {Enum.reverse([{name, value} | acc]), rest2}
    end
  end

  # RPC service -----------------------------------------------------------
  #
  # Parsed for completeness, surfaced as a CST node, then discarded by the
  # resolver. We don't implement a transport — per the spec we just want
  # the data available so other tooling can build on top.

  defp parse_rpc_service(tokens, line, docs) do
    {name, rest} = expect_ident(tokens, "rpc_service name")
    {attrs, rest2} = maybe_parse_attribute_list(rest)
    rest3 = expect_punct(rest2, :lbrace)
    {methods, rest4} = parse_rpc_methods(rest3, [], [])
    rest5 = expect_punct(rest4, :rbrace)

    {{:rpc_service,
      %{
        name: name,
        methods: methods,
        attributes: attrs,
        docs: docs,
        line: line
      }}, rest5}
  end

  defp parse_rpc_methods([{:punct, :rbrace, _} | _] = rest, _docs, acc),
    do: {Enum.reverse(acc), rest}

  defp parse_rpc_methods([{:doc, body, _} | rest], docs, acc),
    do: parse_rpc_methods(rest, docs ++ [body], acc)

  defp parse_rpc_methods(tokens, docs, acc) do
    {name, rest} = expect_ident(tokens, "rpc method name")
    rest2 = expect_punct(rest, :lparen)
    {input, rest3} = parse_type_ref(rest2)
    rest4 = expect_punct(rest3, :rparen)
    rest5 = expect_punct(rest4, :colon)
    {output, rest6} = parse_type_ref(rest5)
    {method_attrs, rest7} = maybe_parse_attribute_list(rest6)
    rest8 = expect_punct(rest7, :semi)

    method = %{
      name: name,
      input: input,
      output: output,
      attributes: method_attrs,
      docs: docs
    }

    parse_rpc_methods(rest8, [], [method | acc])
  end

  # Union -----------------------------------------------------------------

  defp parse_union(tokens, line, docs) do
    {name, rest} = expect_ident(tokens, "union name")
    {attrs, rest2} = maybe_parse_attribute_list(rest)
    rest3 = expect_punct(rest2, :lbrace)
    {variants, rest4} = parse_union_variants(rest3, [], [])
    rest5 = expect_punct(rest4, :rbrace)

    {{:union,
      %{
        name: name,
        variants: variants,
        attributes: attrs,
        docs: docs,
        line: line
      }}, rest5}
  end

  defp parse_union_variants([{:punct, :rbrace, _} | _] = rest, _docs, acc),
    do: {Enum.reverse(acc), rest}

  defp parse_union_variants([{:doc, body, _line} | rest], docs, acc),
    do: parse_union_variants(rest, docs ++ [body], acc)

  defp parse_union_variants(tokens, docs, acc) do
    {variant, rest} = parse_union_variant(tokens, docs)

    case rest do
      [{:punct, :comma, _} | r] ->
        parse_union_variants(r, [], [variant | acc])

      [{:punct, :rbrace, _} | _] ->
        {Enum.reverse([variant | acc]), rest}

      [tok | _] ->
        throw({:parse_error, {:unexpected_token_in_union, tok}})
    end
  end

  # A union variant is one of:
  #   TypeName
  #   alias_name : TypeName
  #   "string"  (the scalar — variant name defaults to "string")
  defp parse_union_variant([{:ident, alias_name, _}, {:punct, :colon, _} | rest], docs) do
    {type, rest2} = parse_type_ref(rest)
    {var_attrs, rest3} = maybe_parse_attribute_list(rest2)
    {%{name: alias_name, type: type, docs: docs, attributes: var_attrs}, rest3}
  end

  defp parse_union_variant([{:ident, name, _} | rest], docs) do
    case Map.fetch(@scalar_types, name) do
      {:ok, :string} ->
        {var_attrs, rest2} = maybe_parse_attribute_list(rest)
        {%{name: "string", type: :string, docs: docs, attributes: var_attrs}, rest2}

      {:ok, _other} ->
        throw({:parse_error, {:bad_union_variant, name}})

      :error ->
        {full, rest2} =
          case rest do
            [{:punct, :dot, _} | _] -> continue_dotted(rest, name)
            _ -> {name, rest}
          end

        {var_attrs, rest3} = maybe_parse_attribute_list(rest2)
        variant_name = full |> String.split(".") |> List.last()
        {%{name: variant_name, type: {:name, full}, docs: docs, attributes: var_attrs}, rest3}
    end
  end

  defp parse_union_variant([tok | _], _docs),
    do: throw({:parse_error, {:expected_union_variant, tok}})

  # Enum ------------------------------------------------------------------

  defp parse_enum(tokens, line, docs) do
    {name, rest} = expect_ident(tokens, "enum name")
    rest1 = expect_punct(rest, :colon)
    {underlying, rest2} = parse_underlying(rest1)
    {attrs, rest3} = maybe_parse_attribute_list(rest2)
    rest4 = expect_punct(rest3, :lbrace)
    {variants, rest5} = parse_enum_variants(rest4, [], [])
    rest6 = expect_punct(rest5, :rbrace)

    {{:enum,
      %{
        name: name,
        underlying_type: underlying,
        variants: variants,
        attributes: attrs,
        docs: docs,
        line: line
      }}, rest6}
  end

  defp parse_underlying([{:ident, name, _} | rest]) do
    case Map.fetch(@scalar_types, name) do
      {:ok, scalar} when scalar != :string ->
        {scalar, rest}

      _ ->
        throw({:parse_error, {:bad_enum_underlying, name}})
    end
  end

  defp parse_underlying([tok | _]),
    do: throw({:parse_error, {:expected_underlying_type, tok}})

  defp parse_enum_variants([{:punct, :rbrace, _} | _] = rest, _docs, acc),
    do: {Enum.reverse(acc), rest}

  defp parse_enum_variants([{:doc, body, _line} | rest], docs, acc),
    do: parse_enum_variants(rest, docs ++ [body], acc)

  defp parse_enum_variants(tokens, docs, acc) do
    {name, rest} = expect_ident(tokens, "enum variant name")

    {value, rest2} =
      case rest do
        [{:punct, :eq, _} | r] ->
          {lit, r2} = parse_literal(r)

          case lit do
            {:int, n} -> {n, r2}
            other -> throw({:parse_error, {:bad_enum_value, other}})
          end

        _ ->
          {nil, rest}
      end

    {var_attrs, rest2} = maybe_parse_attribute_list(rest2)

    variant = %{name: name, value: value, docs: docs, attributes: var_attrs}

    case rest2 do
      [{:punct, :comma, _} | r] ->
        parse_enum_variants(r, [], [variant | acc])

      [{:punct, :rbrace, _} | _] ->
        {Enum.reverse([variant | acc]), rest2}

      [tok | _] ->
        throw({:parse_error, {:unexpected_token_in_enum, tok}})
    end
  end

  # Token helpers ---------------------------------------------------------

  defp expect_ident([{:ident, name, _} | rest], _context), do: {name, rest}

  defp expect_ident([tok | _], context),
    do: throw({:parse_error, {:expected_ident, context, tok}})

  defp expect_ident([], context),
    do: throw({:parse_error, {:expected_ident_eof, context}})

  defp expect_string([{:string, s, _} | rest], _context), do: {s, rest}

  defp expect_string([tok | _], context),
    do: throw({:parse_error, {:expected_string, context, tok}})

  defp expect_punct([{:punct, kind, _} | rest], kind), do: rest

  defp expect_punct([tok | _], kind),
    do: throw({:parse_error, {:expected_punct, kind, tok}})

  defp parse_dotted_name(tokens) do
    {head, rest} = expect_ident(tokens, "namespace part")
    continue_dotted(rest, head)
  end

  defp head_line([{_, _, line} | _]), do: line
  defp head_line(_), do: nil
end
