defmodule Mix.Tasks.Flatbuf.FetchFlatc do
  @shortdoc "Download the pinned flatc release binary for differential tests"

  @moduledoc """
  Download the upstream `flatc` reference compiler binary at the
  release tag pinned by `Flatbuf.Test.Flatc.tag/0`, and stash it under
  `_build/test/flatc/`.

  Most of the time you don't need to call this directly — the
  oracle-driven tests auto-install on first use. But running it once
  up front avoids the "wait, what's it downloading?" surprise the
  first time `mix test` hits the oracle suite.

      mix flatbuf.fetch_flatc

  Supported platforms: Linux x86_64, macOS arm64, macOS x86_64,
  Windows. On anything else: install `flatc` system-wide or point
  `$FLATBUF_FLATC` at an absolute path.

  This task only exists in `MIX_ENV=test`; it lives under
  `test/support/` precisely so it can't slip into a release build.
  """

  use Mix.Task

  @impl Mix.Task
  def run(_argv) do
    path = Flatbuf.Test.Flatc.ensure_available!()
    version = Flatbuf.Test.Flatc.version()
    Mix.shell().info("flatc ready at #{path} (#{version})")
  end
end
