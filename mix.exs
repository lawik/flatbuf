defmodule Flatbuf.MixProject do
  use Mix.Project

  @description """
  Pure-Elixir FlatBuffers with compile-time, file-emitting codegen.
  Generated modules have no runtime dependency on :flatbuf.
  """

  def project do
    [
      app: :flatbuf,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      # Tests compile generated modules into the running VM, including
      # ones that `@derive Jason.Encoder`; consolidated protocols would
      # never dispatch to those runtime-compiled impls.
      consolidate_protocols: Mix.env() != :test,
      # Data files consumed by test support code that live under
      # test/fixtures/ but aren't themselves test modules.
      test_ignore_filters: [
        &String.ends_with?(&1, "conformance_manifest.exs"),
        &String.ends_with?(&1, "fixture_manifest.exs")
      ],
      deps: deps(),
      name: "flatbuf",
      description: @description,
      docs: docs(),
      package: package(),
      aliases: aliases(),
      dialyzer: dialyzer()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  def docs do
    [
      main: "readme",
      extras: ["README.md", "CHANGELOG.md"],
      source_url: "https://github.com/lawik/flatbuf"
    ]
  end

  def package do
    [
      name: :flatbuf,
      licenses: ["Apache-2.0"],
      maintainers: ["Lars Wikman"],
      files: ~w(lib mix.exs README.md CHANGELOG.md LICENSE.md),
      links: %{
        "GitHub" => "https://github.com/lawik/flatbuf",
        "Changelog" => "https://github.com/lawik/flatbuf/blob/main/CHANGELOG.md"
      }
    ]
  end

  def aliases do
    [
      check: [
        "hex.audit",
        "compile --warnings-as-errors --force",
        "format --check-formatted",
        "credo",
        "deps.unlock --check-unused",
        "spellweaver.check",
        "dialyzer"
      ],
      precommit: [
        "hex.audit",
        "compile --warnings-as-errors --force",
        "format",
        "credo",
        "deps.unlock --unused",
        "spellweaver.check",
        "dialyzer",
        "test"
      ]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  def dialyzer do
    [
      plt_add_apps: [:mix],
      ignore_warnings: ".dialyzer_ignore.exs"
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:nstandard, "~> 0.3", only: [:dev, :test], runtime: false},
      {:igniter, "~> 0.6", only: [:dev, :test]},
      {:jason, "~> 1.4", only: [:dev, :test]},
      {:ex_doc, "~> 0.40", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:spellweaver, "~> 0.1", only: [:dev, :test], runtime: false},
      {:stream_data, "~> 1.0", only: [:dev, :test]}
      # {:dep_from_hexpm, "~> 0.3.0"},
      # {:dep_from_git, git: "https://github.com/elixir-lang/my_dep.git", tag: "0.1.0"}
    ]
  end
end
