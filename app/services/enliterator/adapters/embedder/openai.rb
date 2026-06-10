module Enliterator
  module Adapters
    module Embedder
      # Embedder backed by OpenAI's embeddings endpoint via the official `openai`
      # gem (github.com/openai/openai-ruby), the same gem HSDL uses.
      #
      # Default model is text-embedding-3-small (1536d) to stay compatible with
      # HSDL's existing vector(1536) columns.
      #
      #   Enliterator::Adapters::Embedder::OpenAI.new
      #   Enliterator::Adapters::Embedder::OpenAI.new(model: "text-embedding-3-small", api_key: ENV["OPENAI_API_KEY"])
      #
      # The provider gem is lazy-required on first real use; specs can inject a
      # `client:` and avoid both the gem and the network entirely.
      class OpenAI < Base
        # Known output widths for OpenAI embedding models. text-embedding-3-small
        # is 1536 per the engine default; others documented for host convenience.
        DIMENSIONS = {
          "text-embedding-3-small" => 1536,
          "text-embedding-3-large" => 3072,
          "text-embedding-ada-002" => 1536
        }.freeze

        DEFAULT_MODEL = "text-embedding-3-small".freeze

        attr_reader :model

        # @param model [String] OpenAI embedding model id
        # @param api_key [String, nil] OpenAI API key; falls back to ENV["OPENAI_API_KEY"] when the real client is built
        # @param base_url [String, nil] OpenAI-compatible base URL. Default nil => the gem's
        #   own default (https://api.openai.com/v1). Set to the LiteLLM gateway
        #   (https://llm.domt.app/v1) to embed via the `embed` alias instead of OpenAI directly.
        # @param client [Object, nil] injected client responding to embeddings.create (for specs)
        def initialize(model: DEFAULT_MODEL, api_key: nil, base_url: nil, client: nil)
          @model = model
          @api_key = api_key
          @base_url = base_url
          @client = client
        end

        def model_id
          @model
        end

        # @return [Integer] 1536 for text-embedding-3-small; looked up per model, else configured default
        def dimensions
          DIMENSIONS.fetch(@model, Enliterator.configuration.default_embedding_dimensions)
        end

        # @param text [String]
        # @return [Array<Float>] the embedding vector
        def embed(text)
          response = client.embeddings.create(model: @model, input: text.to_s)
          extract_vector(response)
        end

        private

        # Build (and memoize) the OpenAI client lazily so the gem is only required
        # when the real adapter is actually used. An injected client short-circuits this.
        def client
          @client ||= build_client
        end

        def build_client
          begin
            require "openai"
          rescue LoadError
            raise Enliterator::ConfigurationError,
                  'Enliterator::Adapters::Embedder::OpenAI requires the `openai` gem. ' \
                  'Add `gem "openai"` to your host Gemfile.'
          end

          # Pass base_url only when set so we inherit the gem's default
          # (https://api.openai.com/v1) when the host hasn't pointed us at a gateway.
          # v0.23: bounded calls — same discipline as the LLM gateway client.
          opts = { api_key: @api_key || ENV["OPENAI_API_KEY"],
                   timeout: Enliterator.configuration.gateway_timeout,
                   max_retries: Enliterator.configuration.gateway_max_retries }
          opts[:base_url] = @base_url if @base_url
          ::OpenAI::Client.new(**opts)
        end

        # Pull the float vector out of the embeddings response. Handles the
        # official gem's response objects (response.data.first.embedding) as well
        # as plain Hashes (handy for stubbed clients in specs).
        def extract_vector(response)
          row = first_data_row(response)
          raise Enliterator::ConfigurationError, "OpenAI embeddings response had no data" if row.nil?

          vector =
            if row.respond_to?(:embedding)
              row.embedding
            elsif row.respond_to?(:[])
              row[:embedding] || row["embedding"]
            end

          raise Enliterator::ConfigurationError, "OpenAI embeddings response missing embedding vector" if vector.nil?

          Array(vector).map(&:to_f)
        end

        def first_data_row(response)
          data =
            if response.respond_to?(:data)
              response.data
            elsif response.respond_to?(:[])
              response[:data] || response["data"]
            end

          Array(data).first
        end
      end
    end
  end
end
