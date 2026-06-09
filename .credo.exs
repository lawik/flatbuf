%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/"]
      },
      strict: true,
      checks: [
        {Credo.Check.Refactor.MapInto, false},
        {Credo.Check.Warning.LazyLogging, false},
        {Credo.Check.Readability.LargeNumbers, only_greater_than: 86400},
        {Credo.Check.Readability.ParenthesesOnZeroArityDefs, parens: true},
        {Credo.Check.Readability.Specs, tags: []},
        {Credo.Check.Readability.StrictModuleLayout, tags: []},
        # The codegen, lexer, resolver, and mix tasks are dominated by
        # big pattern-match switches over the FlatBuffers type grammar.
        # Cyclomatic complexity / nesting flags there don't point at
        # real code smell — splitting the switches would just spread
        # one decision across many functions. Disabled by file glob.
        {Credo.Check.Refactor.CyclomaticComplexity,
         files: %{
           excluded: [
             ~r"lib/flatbuf/codegen/",
             ~r"lib/flatbuf/schema/lexer\.ex",
             ~r"lib/flatbuf/schema/resolver\.ex",
             ~r"lib/mix/tasks/"
           ]
         }},
        {Credo.Check.Refactor.Nesting,
         files: %{
           excluded: [
             ~r"lib/flatbuf/codegen/",
             ~r"lib/flatbuf/schema/lexer\.ex",
             ~r"lib/flatbuf/schema/resolver\.ex",
             ~r"lib/mix/tasks/"
           ]
         }}
      ]
    }
  ]
}
