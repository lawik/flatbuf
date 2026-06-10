# The upstream google/flatbuffers corpus (and the flatc oracle binary)
# are fetched on demand and gitignored. Without them the suite still
# runs — the corpus-gated modules skip themselves — but say so once up
# front instead of leaving a pile of unexplained skips.
unless File.exists?(Path.expand("fixtures/upstream", __DIR__)) do
  IO.puts("""
  flatbuf: upstream corpus not present — running the offline subset \
  (corpus-gated tests are skipped).
  flatbuf: for the full suite, run:
      MIX_ENV=test mix flatbuf.fetch_fixtures
      MIX_ENV=test mix flatbuf.fetch_flatc
  """)
end

ExUnit.start()
