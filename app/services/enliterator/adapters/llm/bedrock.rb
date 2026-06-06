module Enliterator
  module Adapters
    module LLM
      # AWS Bedrock LLM adapter (Claude on Bedrock by default).
      #
      # Uses the Bedrock Runtime Converse API with a single forced tool
      # ("emit_claims") whose input_schema is RESPONSE_SCHEMA, so the model is
      # compelled to return structured claims. The provider gem is lazy-required;
      # if it is missing we raise a ConfigurationError telling the host what to add.
      #
      # NOTE: model ids change over time and differ per region/account. Never
      # hardcode one — it is read from `model_id`, supplied by the host initializer.
      # A current Anthropic-on-Bedrock id (e.g.
      # "anthropic.claude-3-5-sonnet-20241022-v2:0", or a region-prefixed inference
      # profile id like "us.anthropic.claude-3-5-sonnet-20241022-v2:0") is documented
      # in the README; the host passes whichever is enabled for its account.
      class Bedrock < Base
        # @param model_id [String] Bedrock model id / inference profile id (required).
        # @param region   [String] AWS region; defaults to AWS_REGION or us-east-1.
        # @param client   [Object] optional injected client responding to #converse
        #   (specs pass a fake or an Aws::BedrockRuntime::Client with stubbed responses).
        def initialize(model_id:, region: ENV["AWS_REGION"] || "us-east-1", client: nil)
          @model_id = model_id
          @region   = region
          @client   = client
        end

        def model_id
          @model_id
        end

        def tend(text:, stream:, state:, neighbors:)
          response = client.converse(
            model_id: @model_id,
            system:   [ { text: build_system } ],
            messages: [
              {
                role: "user",
                content: [ { text: build_user(text: text, stream: stream, state: state, neighbors: neighbors) } ]
              }
            ],
            tool_config: {
              tools: [
                {
                  tool_spec: {
                    name: TOOL_NAME,
                    description: "Emit the reconciled claims and overall confidence for this record.",
                    input_schema: { json: RESPONSE_SCHEMA }
                  }
                }
              ],
              tool_choice: { tool: { name: TOOL_NAME } }
            }
          )

          Result.new(
            parsed: extract_parsed(response),
            raw:    raw_hash(response),
            tokens: extract_tokens(response)
          )
        end

        private

        # Memoized client. Building it triggers the lazy require so a missing gem
        # surfaces as a ConfigurationError at first real call (never at boot).
        def client
          @client ||= begin
            require_sdk!
            Aws::BedrockRuntime::Client.new(region: @region)
          end
        end

        def require_sdk!
          require "aws-sdk-bedrockruntime"
        rescue LoadError => e
          raise Enliterator::ConfigurationError,
                "Enliterator::Adapters::LLM::Bedrock requires the AWS Bedrock Runtime SDK. " \
                'Add `gem "aws-sdk-bedrockruntime"` to your host Gemfile and run `bundle install`. ' \
                "(#{e.message})"
        end

        # Pull the forced tool's input out of the Converse response and normalize
        # it into the {"claims"=>[...], "confidence"=>Float} shape.
        def extract_parsed(response)
          blocks = dig_content(response)
          tool_block = blocks.find { |b| tool_use_of(b) }
          input = tool_block ? input_of(tool_use_of(tool_block)) : {}
          input = parse_input(input)

          {
            "claims"     => normalize_claims(input["claims"]),
            "confidence" => normalize_confidence(input["confidence"])
          }
        end

        # Content blocks live at response.output.message.content (struct) or the
        # equivalent nested hash when a fake client returns plain hashes.
        def dig_content(response)
          message =
            if response.respond_to?(:output) && response.output
              response.output.respond_to?(:message) ? response.output.message : nil
            elsif response.is_a?(Hash)
              response.dig(:output, :message) || response.dig("output", "message")
            end
          return [] unless message

          content =
            if message.respond_to?(:content)
              message.content
            elsif message.is_a?(Hash)
              message[:content] || message["content"]
            end
          Array(content)
        end

        # Return the tool_use member of a content block, across struct/hash shapes.
        def tool_use_of(block)
          if block.respond_to?(:tool_use)
            block.tool_use
          elsif block.is_a?(Hash)
            block[:tool_use] || block["tool_use"]
          end
        end

        # The model-generated arguments on a tool_use member.
        def input_of(tool_use)
          if tool_use.respond_to?(:input)
            tool_use.input
          elsif tool_use.is_a?(Hash)
            tool_use[:input] || tool_use["input"]
          end
        end

        # Converse may surface tool input as a Hash (document type) or, defensively,
        # a JSON string. Normalize to a string-keyed Hash.
        def parse_input(input)
          case input
          when Hash   then input
          when String then (JSON.parse(input) rescue {})
          else {}
          end
        end

        def normalize_claims(claims)
          Array(claims).map do |c|
            h = c.is_a?(Hash) ? c : {}
            {
              "key"        => h["key"] || h[:key],
              "value"      => h.key?("value") ? h["value"] : h[:value],
              "confidence" => h["confidence"] || h[:confidence],
              "op"         => h["op"] || h[:op]
            }.compact
          end
        end

        def normalize_confidence(conf)
          conf.nil? ? 0.0 : conf.to_f
        end

        def extract_tokens(response)
          usage =
            if response.respond_to?(:usage)
              response.usage
            elsif response.is_a?(Hash)
              response[:usage] || response["usage"]
            end
          return {} unless usage

          {
            "input"  => usage_value(usage, :input_tokens),
            "output" => usage_value(usage, :output_tokens),
            "total"  => usage_value(usage, :total_tokens)
          }.compact
        end

        def usage_value(usage, key)
          if usage.respond_to?(key)
            usage.public_send(key)
          elsif usage.is_a?(Hash)
            usage[key] || usage[key.to_s]
          end
        end

        # Best-effort JSON-safe snapshot of the raw response for the Visit row.
        def raw_hash(response)
          if response.respond_to?(:to_h)
            response.to_h
          elsif response.is_a?(Hash)
            response
          else
            { "adapter" => "bedrock", "model_id" => @model_id }
          end
        rescue StandardError
          { "adapter" => "bedrock", "model_id" => @model_id }
        end
      end
    end
  end
end
