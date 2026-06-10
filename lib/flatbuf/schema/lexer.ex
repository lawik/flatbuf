defmodule Flatbuf.Schema.Lexer do
  @moduledoc """
  Lexer for FlatBuffers schema (`.fbs`) source.

  Produces a flat list of tokens preserving line numbers for error reporting.
  Doc comments (`/// ...`) are emitted as `:doc` tokens so the parser can
  attach them to the following declaration; ordinary comments are discarded.
  """

  @keywords ~w(namespace table struct enum union root_type attribute file_identifier file_extension include rpc_service true false null)
  @keyword_set MapSet.new(@keywords)

  @type token ::
          {:kw, atom(), pos_integer()}
          | {:ident, String.t(), pos_integer()}
          | {:int, integer(), pos_integer()}
          | {:float, float(), pos_integer()}
          | {:string, String.t(), pos_integer()}
          | {:doc, String.t(), pos_integer()}
          | {:punct, atom(), pos_integer()}
          | {:eof, nil, pos_integer()}

  @spec tokenize(binary()) :: {:ok, [token()]} | {:error, term()}
  def tokenize(source) when is_binary(source) do
    case do_tokenize(source, 1, []) do
      {:ok, acc, line} -> {:ok, Enum.reverse([{:eof, nil, line} | acc])}
      {:error, _} = err -> err
    end
  end

  # End of input
  defp do_tokenize("", line, acc), do: {:ok, acc, line}

  # Newlines
  defp do_tokenize(<<"\r\n", rest::binary>>, line, acc), do: do_tokenize(rest, line + 1, acc)
  defp do_tokenize(<<"\n", rest::binary>>, line, acc), do: do_tokenize(rest, line + 1, acc)
  defp do_tokenize(<<"\r", rest::binary>>, line, acc), do: do_tokenize(rest, line + 1, acc)

  # Whitespace
  defp do_tokenize(<<c, rest::binary>>, line, acc) when c in [?\s, ?\t],
    do: do_tokenize(rest, line, acc)

  # Doc comment (must check before //)
  defp do_tokenize(<<"///", rest::binary>>, line, acc) do
    {body, rest2, newlines} = read_to_newline(rest)
    do_tokenize(rest2, line + newlines, [{:doc, String.trim(body), line} | acc])
  end

  # Line comment
  defp do_tokenize(<<"//", rest::binary>>, line, acc) do
    {_, rest2, newlines} = read_to_newline(rest)
    do_tokenize(rest2, line + newlines, acc)
  end

  # Block comment
  defp do_tokenize(<<"/*", rest::binary>>, line, acc) do
    case skip_block_comment(rest, line) do
      {:ok, rest2, line2} -> do_tokenize(rest2, line2, acc)
      {:error, _} = err -> err
    end
  end

  # String literal — both "…" and '…' per the .fbs grammar.
  defp do_tokenize(<<?", rest::binary>>, line, acc) do
    case read_string(rest, line, ?", []) do
      {:ok, str, line2, rest2} -> do_tokenize(rest2, line2, [{:string, str, line} | acc])
      {:error, _} = err -> err
    end
  end

  defp do_tokenize(<<?', rest::binary>>, line, acc) do
    case read_string(rest, line, ?', []) do
      {:ok, str, line2, rest2} -> do_tokenize(rest2, line2, [{:string, str, line} | acc])
      {:error, _} = err -> err
    end
  end

  # Float with no integer part: `.5` (must precede the `.` punct clause)
  defp do_tokenize(<<?., c, _::binary>> = bin, line, acc) when c in ?0..?9 do
    tokenize_number(bin, line, acc)
  end

  # Punctuation
  for {ch, tok} <- [
        {"{", :lbrace},
        {"}", :rbrace},
        {"(", :lparen},
        {")", :rparen},
        {"[", :lbracket},
        {"]", :rbracket},
        {":", :colon},
        {";", :semi},
        {",", :comma},
        {"=", :eq},
        {".", :dot},
        {"+", :plus},
        {"-", :minus}
      ] do
    defp do_tokenize(<<unquote(ch), rest::binary>>, line, acc),
      do: do_tokenize(rest, line, [{:punct, unquote(tok), line} | acc])
  end

  # Numbers
  defp do_tokenize(<<c, _::binary>> = bin, line, acc) when c in ?0..?9 do
    tokenize_number(bin, line, acc)
  end

  # Identifier / keyword
  defp do_tokenize(<<c, _::binary>> = bin, line, acc)
       when c in ?a..?z or c in ?A..?Z or c == ?_ do
    {ident, rest} = read_ident(bin, [])

    tok =
      if MapSet.member?(@keyword_set, ident) do
        {:kw, String.to_atom(ident), line}
      else
        {:ident, ident, line}
      end

    do_tokenize(rest, line, [tok | acc])
  end

  defp do_tokenize(<<c::utf8, _::binary>>, line, _acc) do
    {:error, {:unexpected_char, <<c::utf8>>, line}}
  end

  # Any byte that isn't valid UTF-8 (e.g. a Latin-1 file) — error tuple,
  # never a FunctionClauseError.
  defp do_tokenize(<<byte, _::binary>>, line, _acc) do
    {:error, {:invalid_byte, byte, line}}
  end

  defp tokenize_number(bin, line, acc) do
    case read_number(bin) do
      {:ok, {:int, v}, rest} -> do_tokenize(rest, line, [{:int, v, line} | acc])
      {:ok, {:float, v}, rest} -> do_tokenize(rest, line, [{:float, v, line} | acc])
      {:error, {:bad_number, text}} -> {:error, {:bad_number, text, line}}
    end
  end

  # Helpers ----------------------------------------------------------------

  defp read_to_newline(bin), do: read_to_newline(bin, [], 0)
  defp read_to_newline("", body, nl), do: {iolist_to_binary_rev(body), "", nl}

  defp read_to_newline(<<"\r\n", rest::binary>>, body, nl),
    do: {iolist_to_binary_rev(body), rest, nl + 1}

  defp read_to_newline(<<"\n", rest::binary>>, body, nl),
    do: {iolist_to_binary_rev(body), rest, nl + 1}

  defp read_to_newline(<<"\r", rest::binary>>, body, nl),
    do: {iolist_to_binary_rev(body), rest, nl + 1}

  defp read_to_newline(<<c, rest::binary>>, body, nl),
    do: read_to_newline(rest, [c | body], nl)

  defp iolist_to_binary_rev(list), do: list |> Enum.reverse() |> IO.iodata_to_binary()

  defp skip_block_comment("", line), do: {:error, {:unterminated_block_comment, line}}

  defp skip_block_comment(<<"*/", rest::binary>>, line), do: {:ok, rest, line}

  defp skip_block_comment(<<"\r\n", rest::binary>>, line),
    do: skip_block_comment(rest, line + 1)

  defp skip_block_comment(<<"\n", rest::binary>>, line), do: skip_block_comment(rest, line + 1)
  defp skip_block_comment(<<"\r", rest::binary>>, line), do: skip_block_comment(rest, line + 1)
  defp skip_block_comment(<<_, rest::binary>>, line), do: skip_block_comment(rest, line)

  defp read_string("", line, _term, _acc), do: {:error, {:unterminated_string, line}}

  defp read_string(<<c, rest::binary>>, line, term, acc) when c == term do
    str = IO.iodata_to_binary(Enum.reverse(acc))

    # `\xHH` injects raw bytes, so validate the assembled string as a
    # whole — flatc rejects string literals that aren't valid UTF-8.
    if String.valid?(str) do
      {:ok, str, line, rest}
    else
      {:error, {:illegal_utf8_in_string, line}}
    end
  end

  defp read_string(<<"\\", rest::binary>>, line, term, acc) do
    case rest do
      <<?n, r::binary>> -> read_string(r, line, term, [?\n | acc])
      <<?t, r::binary>> -> read_string(r, line, term, [?\t | acc])
      <<?r, r::binary>> -> read_string(r, line, term, [?\r | acc])
      <<?b, r::binary>> -> read_string(r, line, term, [?\b | acc])
      <<?f, r::binary>> -> read_string(r, line, term, [?\f | acc])
      <<?\\, r::binary>> -> read_string(r, line, term, [?\\ | acc])
      <<?/, r::binary>> -> read_string(r, line, term, [?/ | acc])
      <<?", r::binary>> -> read_string(r, line, term, [?" | acc])
      <<?', r::binary>> -> read_string(r, line, term, [?' | acc])
      <<?0, r::binary>> -> read_string(r, line, term, [0 | acc])
      <<?x, r::binary>> -> read_hex_escape(r, line, term, acc)
      <<?u, r::binary>> -> read_unicode_escape(r, line, term, acc)
      <<c, _::binary>> -> {:error, {:bad_escape, <<c>>, line}}
      "" -> {:error, {:unterminated_string, line}}
    end
  end

  defp read_string(<<"\n", rest::binary>>, line, term, acc),
    do: read_string(rest, line + 1, term, [?\n | acc])

  defp read_string(<<c::utf8, rest::binary>>, line, term, acc),
    do: read_string(rest, line, term, [<<c::utf8>> | acc])

  defp read_string(<<_byte, _::binary>>, line, _term, _acc),
    do: {:error, {:illegal_utf8_in_string, line}}

  # `\xHH` — exactly two hex digits, yielding one raw byte (flatc semantics;
  # multi-byte UTF-8 sequences can be spelled as consecutive escapes).
  defp read_hex_escape(<<h1, h2, rest::binary>>, line, term, acc)
       when (h1 in ?0..?9 or h1 in ?a..?f or h1 in ?A..?F) and
              (h2 in ?0..?9 or h2 in ?a..?f or h2 in ?A..?F) do
    byte = String.to_integer(<<h1, h2>>, 16)
    read_string(rest, line, term, [byte | acc])
  end

  defp read_hex_escape(_rest, line, _term, _acc),
    do: {:error, {:bad_hex_escape, line}}

  # `\uXXXX` — exactly four hex digits; UTF-16 surrogate pairs combine.
  defp read_unicode_escape(rest, line, term, acc) do
    case take_u16(rest) do
      {:ok, cp, rest2} when cp in 0xD800..0xDBFF ->
        case rest2 do
          <<"\\u", more::binary>> ->
            case take_u16(more) do
              {:ok, lo, rest3} when lo in 0xDC00..0xDFFF ->
                combined = 0x10000 + Bitwise.bsl(cp - 0xD800, 10) + (lo - 0xDC00)
                read_string(rest3, line, term, [<<combined::utf8>> | acc])

              _ ->
                {:error, {:unpaired_surrogate, line}}
            end

          _ ->
            {:error, {:unpaired_surrogate, line}}
        end

      {:ok, cp, _rest2} when cp in 0xDC00..0xDFFF ->
        {:error, {:unpaired_surrogate, line}}

      {:ok, cp, rest2} ->
        read_string(rest2, line, term, [<<cp::utf8>> | acc])

      :error ->
        {:error, {:bad_unicode_escape, line}}
    end
  end

  defp take_u16(<<h1, h2, h3, h4, rest::binary>>)
       when (h1 in ?0..?9 or h1 in ?a..?f or h1 in ?A..?F) and
              (h2 in ?0..?9 or h2 in ?a..?f or h2 in ?A..?F) and
              (h3 in ?0..?9 or h3 in ?a..?f or h3 in ?A..?F) and
              (h4 in ?0..?9 or h4 in ?a..?f or h4 in ?A..?F) do
    {:ok, String.to_integer(<<h1, h2, h3, h4>>, 16), rest}
  end

  defp take_u16(_), do: :error

  defp read_ident(<<c, rest::binary>>, acc)
       when c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c == ?_,
       do: read_ident(rest, [c | acc])

  defp read_ident(rest, acc),
    do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}

  # Number parsing: integer or float; supports 0x/0b/0o prefixes for int
  defp read_number(<<"0x", rest::binary>>) do
    {hex, rest2} = take_hex(rest, [])

    case Integer.parse(hex, 16) do
      {n, ""} -> {:ok, {:int, n}, rest2}
      _ -> {:error, {:bad_number, "0x" <> hex}}
    end
  end

  defp read_number(<<"0b", rest::binary>>) do
    {bin, rest2} = take_bin(rest, [])

    case Integer.parse(bin, 2) do
      {n, ""} -> {:ok, {:int, n}, rest2}
      _ -> {:error, {:bad_number, "0b" <> bin}}
    end
  end

  # `.5` — fraction with no integer part (flatc accepts it).
  defp read_number(<<".", rest::binary>>) do
    {frac, rest2} = take_digits(rest, [])
    {exp_part, rest3} = take_exponent(rest2)
    parse_float("0." <> frac <> exp_part, rest3)
  end

  defp read_number(bin) do
    {digits, rest} = take_digits(bin, [])

    case rest do
      # `1.5`, `1.` and `1.e2` are all floats (flatc accepts the bare dot).
      <<".", more::binary>> ->
        {frac, rest2} = take_digits(more, [])
        {exp_part, rest3} = take_exponent(rest2)
        frac = if frac == "", do: "0", else: frac
        parse_float(digits <> "." <> frac <> exp_part, rest3)

      <<c, _::binary>> when c in [?e, ?E] ->
        {exp_part, rest2} = take_exponent(rest)
        parse_float(digits <> exp_part, rest2)

      _ ->
        case Integer.parse(digits) do
          {n, ""} -> {:ok, {:int, n}, rest}
          _ -> {:error, {:bad_number, digits}}
        end
    end
  end

  defp parse_float(text, rest) do
    case Float.parse(text) do
      {f, ""} -> {:ok, {:float, f}, rest}
      _ -> {:error, {:bad_number, text}}
    end
  end

  defp take_digits(<<c, rest::binary>>, acc) when c in ?0..?9,
    do: take_digits(rest, [c | acc])

  defp take_digits(rest, acc),
    do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}

  defp take_hex(<<c, rest::binary>>, acc)
       when c in ?0..?9 or c in ?a..?f or c in ?A..?F,
       do: take_hex(rest, [c | acc])

  defp take_hex(rest, acc),
    do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}

  defp take_bin(<<c, rest::binary>>, acc) when c in [?0, ?1],
    do: take_bin(rest, [c | acc])

  defp take_bin(rest, acc),
    do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}

  defp take_exponent(<<c, rest::binary>>) when c in [?e, ?E] do
    {sign, rest2} =
      case rest do
        <<?+, r::binary>> -> {"+", r}
        <<?-, r::binary>> -> {"-", r}
        _ -> {"", rest}
      end

    {digits, rest3} = take_digits(rest2, [])
    {<<c>> <> sign <> digits, rest3}
  end

  defp take_exponent(rest), do: {"", rest}
end
