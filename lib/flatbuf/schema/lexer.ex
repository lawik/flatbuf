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
    case read_number(bin) do
      {:ok, tok_value, rest} ->
        tok =
          case tok_value do
            {:int, v} -> {:int, v, line}
            {:float, v} -> {:float, v, line}
          end

        do_tokenize(rest, line, [tok | acc])

      {:error, _} = err ->
        err
    end
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

  defp read_string(<<c, rest::binary>>, line, term, acc) when c == term,
    do: {:ok, IO.iodata_to_binary(Enum.reverse(acc)), line, rest}

  defp read_string(<<"\\", rest::binary>>, line, term, acc) do
    case rest do
      <<?n, r::binary>> -> read_string(r, line, term, [?\n | acc])
      <<?t, r::binary>> -> read_string(r, line, term, [?\t | acc])
      <<?r, r::binary>> -> read_string(r, line, term, [?\r | acc])
      <<?\\, r::binary>> -> read_string(r, line, term, [?\\ | acc])
      <<?", r::binary>> -> read_string(r, line, term, [?" | acc])
      <<?', r::binary>> -> read_string(r, line, term, [?' | acc])
      <<?0, r::binary>> -> read_string(r, line, term, [0 | acc])
      <<c, _::binary>> -> {:error, {:bad_escape, <<c>>, line}}
      "" -> {:error, {:unterminated_string, line}}
    end
  end

  defp read_string(<<"\n", rest::binary>>, line, term, acc),
    do: read_string(rest, line + 1, term, [?\n | acc])

  defp read_string(<<c::utf8, rest::binary>>, line, term, acc),
    do: read_string(rest, line, term, [<<c::utf8>> | acc])

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

  defp read_number(bin) do
    {digits, rest} = take_digits(bin, [])

    case rest do
      <<".", more::binary>> when more != "" ->
        case more do
          <<c, _::binary>> when c in ?0..?9 ->
            {frac, rest2} = take_digits(more, [])
            {exp_part, rest3} = take_exponent(rest2)
            text = digits <> "." <> frac <> exp_part

            case Float.parse(text) do
              {f, ""} -> {:ok, {:float, f}, rest3}
              _ -> {:error, {:bad_number, text}}
            end

          _ ->
            int_with_exponent(digits, rest)
        end

      <<c, _::binary>> when c in [?e, ?E] ->
        {exp_part, rest2} = take_exponent(rest)
        text = digits <> exp_part

        case Float.parse(text) do
          {f, ""} -> {:ok, {:float, f}, rest2}
          _ -> {:error, {:bad_number, text}}
        end

      _ ->
        case Integer.parse(digits) do
          {n, ""} -> {:ok, {:int, n}, rest}
          _ -> {:error, {:bad_number, digits}}
        end
    end
  end

  defp int_with_exponent(digits, rest) do
    case Integer.parse(digits) do
      {n, ""} -> {:ok, {:int, n}, rest}
      _ -> {:error, {:bad_number, digits}}
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
