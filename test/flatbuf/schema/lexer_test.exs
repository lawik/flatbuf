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

  describe "non-UTF-8 input" do
    test "a stray invalid byte returns an error tuple, never raises" do
      assert {:error, {:invalid_byte, 0xFF, 1}} = Lexer.tokenize(<<0xFF>>)
    end

    test "invalid byte carries the right line number" do
      assert {:error, {:invalid_byte, 0xC0, 3}} = Lexer.tokenize(<<"a\nb\n", 0xC0>>)
    end

    test "an invalid byte inside a string literal returns an error tuple" do
      assert {:error, {:illegal_utf8_in_string, 2}} =
               Lexer.tokenize(<<"x\n\"ab", 0xFF, "cd\"">>)
    end

    test "valid multi-byte UTF-8 still lexes inside strings" do
      assert {:ok, [{:string, "héllo😀", 1} | _]} = Lexer.tokenize(~S{"héllo😀"})
    end
  end

  describe "string escapes" do
    test "backspace, formfeed, and forward slash" do
      assert {:ok, [{:string, "\b\f/", 1} | _]} = Lexer.tokenize(~S{"\b\f\/"})
    end

    test "\\xHH hex escapes produce raw bytes" do
      assert {:ok, [{:string, "A", 1} | _]} = Lexer.tokenize(~S{"\x41"})
    end

    test "consecutive \\xHH escapes can spell a multi-byte UTF-8 character" do
      assert {:ok, [{:string, "é", 1} | _]} = Lexer.tokenize(~S{"\xC3\xA9"})
    end

    test "\\xHH bytes that don't form valid UTF-8 are rejected like flatc" do
      assert {:error, {:illegal_utf8_in_string, 1}} = Lexer.tokenize(~S{"\xFF"})
    end

    test "\\x requires exactly two hex digits" do
      assert {:error, {:bad_hex_escape, 1}} = Lexer.tokenize(~S{"\x4"})
    end

    test "\\uXXXX basic multilingual plane escape" do
      assert {:ok, [{:string, "é!", 1} | _]} = Lexer.tokenize(~S{"\u00E9!"})
    end

    test "\\u requires exactly four hex digits" do
      assert {:error, {:bad_unicode_escape, 1}} = Lexer.tokenize(~S{"\u12"})
    end

    test "UTF-16 surrogate pairs combine into one code point" do
      assert {:ok, [{:string, "😀", 1} | _]} = Lexer.tokenize(~S{"\uD83D\uDE00"})
    end

    test "an unpaired high surrogate is rejected" do
      assert {:error, {:unpaired_surrogate, 1}} = Lexer.tokenize(~S{"\uD83D"})
    end

    test "a high surrogate followed by a non-surrogate is rejected" do
      assert {:error, {:unpaired_surrogate, 1}} = Lexer.tokenize(~S{"\uD83DA"})
    end

    test "a lone low surrogate is rejected" do
      assert {:error, {:unpaired_surrogate, 1}} = Lexer.tokenize(~S{"\uDE00"})
    end

    test "unknown escapes are still rejected" do
      assert {:error, {:bad_escape, "q", 1}} = Lexer.tokenize(~S{"\q"})
    end
  end

  describe "float literal forms" do
    test "fraction with no integer part: .5 (flatc accepts)" do
      assert {:ok, [{:float, 0.5, 1} | _]} = Lexer.tokenize(".5")
    end

    test "integer part with bare trailing dot: 1. (flatc accepts)" do
      assert {:ok, [{:float, 1.0, 1} | _]} = Lexer.tokenize("1.")
    end

    test "bare dot with exponent: 2.e3" do
      assert {:ok, [{:float, 2.0e3, 1} | _]} = Lexer.tokenize("2.e3")
    end

    test ".5 with exponent" do
      assert {:ok, [{:float, 50.0, 1} | _]} = Lexer.tokenize(".5e2")
    end

    test "a lone dot is still punctuation" do
      assert {:ok, [{:punct, :dot, 1} | _]} = Lexer.tokenize(".")
    end

    test "leading-zero integers are decimal, matching flatc (017 == 17)" do
      {:ok, tokens} = Lexer.tokenize("017 018")
      assert [{:int, 17, 1}, {:int, 18, 1} | _] = tokens
    end
  end

  test "unexpected (but valid UTF-8) characters error with a line" do
    assert {:error, {:unexpected_char, "§", 2}} = Lexer.tokenize("a\n§")
  end
end
