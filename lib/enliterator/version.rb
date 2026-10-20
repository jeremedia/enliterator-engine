module Enliterator
  # The engine's release. The gemspec reads it, `rake release` tags the commit
  # "v#{VERSION}", and a host may require it in its Gemfile
  # (`gem "enliterator", "~> 0.91", git: ..., tag: "v0.91.0"`), so Bundler refuses a
  # stale pin. Bump it in the commit that cuts a release; between releases it names
  # the last one cut. (Jeremy, 2026-10-20, hub ledger 1e2df0: option A, the gemspec
  # version — no separate RELEASE constant.)
  VERSION = "0.1.0"
end
