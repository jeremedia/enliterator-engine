require_relative "lib/enliterator/version"

Gem::Specification.new do |spec|
  spec.name        = "enliterator"
  spec.version     = Enliterator::VERSION
  spec.authors     = [ "Jeremy Roush" ]
  spec.email       = [ "j@zinod.com" ]
  spec.homepage    = "https://github.com/jeremedia/enliterator"
  spec.summary     = "Enliterate your data: a reusable per-record AI tending loop for Rails."
  spec.description = "Enliterator is a mountable Rails engine that confers literacy on data. " \
                     "Any host model becomes Tendable: it gains embeddings, a provenance-tracked " \
                     "claim store, quality measures, and a tending loop where each visit " \
                     "reads the record's accumulated history plus its corpus neighbors and " \
                     "reconciles its understanding. Understanding compounds across visits."
  spec.license     = "MIT"

  spec.required_ruby_version = ">= 3.2"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    Dir["{app,config,db,lib}/**/*", "MIT-LICENSE", "Rakefile", "README.md"]
  end

  spec.add_dependency "rails", ">= 7.1"
  spec.add_dependency "neighbor", ">= 0.5"
  spec.add_dependency "ancestry", ">= 4.3"   # the Context tree (v0.13 — nested enliterated collections)

  # LLM and embedding providers are intentionally NOT dependencies.
  # Adapters lazy-require their provider gem (anthropic / openai / aws-sdk-bedrockruntime)
  # and raise a helpful error if the host has not bundled it. This keeps the engine
  # provider-agnostic and light.
end
