import Config

# `bun` is pulled in transitively by `spellweaver` and emits a warning
# at load time when no version is pinned. We don't drive any
# JavaScript tooling — this just quiets the noise.
config :bun, :version, "1.3.0"
