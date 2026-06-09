require "neighbor"
require "ancestry"

module Enliterator
  class Engine < ::Rails::Engine
    isolate_namespace Enliterator

    # Zeitwerk acronym inflections so the adapter constants resolve to the names
    # the SPEC mandates: app/services/enliterator/adapters/llm/*.rb =>
    # Enliterator::Adapters::LLM::*, and embedder/openai.rb =>
    # Enliterator::Adapters::Embedder::OpenAI. Without these, the default
    # camelizer yields `Llm` and `Openai` and the constants never load.
    # `inflect` only overrides the listed basenames; everything else camelizes
    # normally.
    initializer "enliterator.inflections", before: :set_autoload_paths do
      Rails.autoloaders.main.inflector.inflect(
        "llm"    => "LLM",
        "openai" => "OpenAI"
      )
    end

    # Make the engine's migrations runnable from the host without copying.
    # Append the engine's db/migrate paths to the host app unless the host IS this
    # engine. The comparison is by realpath, not substring: the dummy host app is
    # nested inside the engine (spec/dummy), so its root string *contains* the
    # engine root string — a substring `match?` would wrongly skip the append.
    initializer "enliterator.append_migrations" do |app|
      next if app.root.to_s == root.to_s

      config.paths["db/migrate"].expanded.each do |expanded_path|
        next if app.config.paths["db/migrate"].include?(expanded_path)

        app.config.paths["db/migrate"] << expanded_path
      end
    end

    # Eager-load the measure registry so host-registered measures survive boot.
    config.to_prepare do
      Enliterator::Measures.load_default! if defined?(Enliterator::Measures)
    end
  end
end
