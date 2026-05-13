defmodule Flatbuf.Schema.LexerTest do
  use ExUnit.Case, async: true

  alias Flatbuf.Schema.Lexer

  test "tokenizes a punctuation soup" do
    {:ok, tokens} = Lexer.tokenize("{ } ( ) [ ] : ; , = . + -")
    kinds = for {:punct, k, _} <- tokens, do: k

    assert kinds ==
             [
               :lbrace,
               :rbrace,
               :lparen,
               :rparen,
               :lbracket,
               :rbracket,
               :colon,
               :semi,
               :comma,
               :eq,
               :dot,
               :plus,
               :minus
             ]
  end

  test "recognizes keywords vs identifiers" do
    {:ok, tokens} = Lexer.tokenize("table Foo enum Color")
    [kw1, id1, kw2, id2 | _] = tokens
    assert kw1 == {:kw, :table, 1}
    assert id1 == {:ident, "Foo", 1}
    assert kw2 == {:kw, :enum, 1}
    assert id2 == {:ident, "Color", 1}
  end

  test "parses decimal, hex, and binary integers" do
    {:ok, tokens} = Lexer.tokenize("42 0xff 0b1010")
    ints = for {:int, v, _} <- tokens, do: v
    assert ints == [42, 255, 10]
  end

  test "parses floats" do
    {:ok, tokens} = Lexer.tokenize("3.14 1.5e2")
    floats = for {:float, v, _} <- tokens, do: v
    assert floats == [3.14, 150.0]
  end

  test "parses strings with escapes" do
    {:ok, tokens} = Lexer.tokenize(~S{"hello\n\"world\""})
    [{:string, s, _} | _] = tokens
    assert s == "hello\n\"world\""
  end

  test "extracts /// doc comments as :doc tokens, drops // and /* */" do
    {:ok, tokens} =
      Lexer.tokenize("""
      /// title
      // throwaway
      /* throwaway */
      table Foo {}
      """)

    docs = for {:doc, body, _} <- tokens, do: body
    assert docs == ["title"]
    assert Enum.any?(tokens, fn t -> match?({:kw, :table, _}, t) end)
  end

  test "tracks line numbers across newlines" do
    {:ok, [_, _, third | _]} = Lexer.tokenize("a\nb\nc")
    assert {:ident, "c", 3} = third
  end
end
