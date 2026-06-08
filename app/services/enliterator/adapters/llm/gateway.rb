module Enliterator
  module Adapters
    module LLM
      # LiteLLM gateway adapter — the v0.2 routing target.
      #
      # Talks to the LiteLLM gateway (https://llm.domt.app/v1, OpenAI-compatible)
      # via the official `openai` gem (github.com/openai/openai-ruby). The engine
      # names a capability TIER (a LiteLLM alias like "cheap" or "quality") as the
      # model id; LiteLLM owns provider selection, fallback, load-balancing, and
      # cost. The engine never names a provider.
      #
      #   Enliterator::Adapters::LLM::Gateway.new(
      #     tier:     "cheap",
      #     base_url: "https://llm.domt.app/v1",
      #     api_key:  ENV["LITELLM_KEY"]
      #   )
      #
      # Structured output uses a single FORCED tool ("emit_claims") bound to
      # RESPONSE_SCHEMA. Forced tool_choice is the portable structured-output path
      # across every tier (gpt-5.x supports json_schema; gemma4 supports only
      # tool_choice) — so we deliberately do NOT use json_schema response_format.
      #
      # Per-request spend attribution rides along as LiteLLM `metadata: {tags: [...]}`,
      # injected through request_options[:extra_body] so the tag ARRAY reaches
      # LiteLLM unmangled (the gem's typed `metadata:` param coerces values to
      # strings, which would flatten the array).
      #
      # The provider gem is lazy-required on first real use; specs inject a fake
      # `client:` and touch neither the gem nor the network.
      class Gateway < Base
        # @param tier     [String] LiteLLM alias used as the model id (e.g. "cheap", "quality").
        # @param base_url [String] gateway base URL (OpenAI-compatible, e.g. "https://llm.domt.app/v1").
        # @param api_key  [String] LiteLLM project key (from ENV; never committed).
        # @param client   [Object, nil] optional injected client responding to
        #   #chat.completions.create (specs pass a fake; no network).
        def initialize(tier:, base_url:, api_key:, client: nil)
          @tier     = tier.to_s
          @base_url = base_url
          @api_key  = api_key
          @client   = client
        end

        # The tier alias IS the model id we send to the gateway.
        def model_id
          @tier
        end

        # Tend a record through the gateway's chat completions endpoint with a
        # forced tool call. Accepts an optional +tags+ array for LiteLLM spend
        # attribution; defaults to [] so v0.1-shaped callers (which pass no tags)
        # keep working unchanged.
        #
        # +contract+ (v0.3) is an optional `{key => description}` hash. When
        # present the tool's parameter schema enums claim `key` to the allowed set
        # and adds an optional top-level `suggestions` array, and the system
        # message gains a controlled-vocabulary block. When absent (the default)
        # the request is byte-identical to v0.2: parameters == RESPONSE_SCHEMA and
        # the original system text.
        #
        # @return [Enliterator::Adapters::LLM::Base::Result]
        def tend(text:, stream:, state:, neighbors:, tags: [], contract: nil, required: nil)
          messages = [
            { role: "system", content: system_for(contract, required: required) },
            {
              role: "user",
              content: build_user(text: text, stream: stream, state: state, neighbors: neighbors)
            }
          ]

          params = {
            model:    @tier,
            messages: messages,
            tools: [
              {
                type: "function",
                function: {
                  name: TOOL_NAME,
                  description: "Emit the reconciled claims and overall confidence for this record.",
                  parameters: schema_for(contract)
                }
              }
            ],
            # FORCED tool_choice — compel the named tool so every tier returns
            # structured arguments (portable across gpt-5.x + gemma4).
            tool_choice: {
              type: "function",
              function: { name: TOOL_NAME }
            }
          }

          # LiteLLM spend tags travel via metadata. Route through extra_body so the
          # tags array survives untouched (the typed `metadata:` param would coerce
          # array values to strings).
          request_options = {}
          if Array(tags).any?
            request_options[:extra_body] = { metadata: { tags: Array(tags) } }
          end

          response =
            if request_options.empty?
              client.chat.completions.create(**params)
            else
              client.chat.completions.create(**params, request_options: request_options)
            end

          Result.new(
            parsed: extract_parsed(response),
            raw:    raw_hash(response),
            tokens: extract_tokens(response)
          )
        end

        # Free-form conversational completion (v0.6). No forced tool — the caller's
        # +messages+ (system = self-portrait, user = question + retrieved claims) are
        # answered in natural language. Streaming uses the official openai gem's
        # `chat.completions.stream_raw(...)` (NOT create(stream: true)); each chunk
        # carries an incremental `choices[0].delta.content`. Spend +tags+ ride via
        # request_options[:extra_body] exactly as #tend.
        def converse(messages:, tags: [], stream: false, &block)
          params = { model: @tier, messages: messages }
          request_options = {}
          request_options[:extra_body] = { metadata: { tags: Array(tags) } } if Array(tags).any?

          if stream && block
            full = +""
            args = params.dup
            args[:request_options] = request_options unless request_options.empty?
            client.chat.completions.stream_raw(**args).each do |chunk|
              delta = extract_delta(chunk)
              next if delta.nil? || delta.empty?
              full << delta
              block.call(delta)
            end
            full
          else
            response =
              if request_options.empty?
                client.chat.completions.create(**params)
              else
                client.chat.completions.create(**params, request_options: request_options)
              end
            extract_message_content(response).to_s
          end
        end

        # General forced-tool structured call (v0.8). Forces +tool_name+ bound to
        # +schema+ and returns the parsed arguments Hash. Reuses the tend tool
        # plumbing with a caller-supplied schema.
        def decide(messages:, schema:, tool_name:, tags: [])
          params = {
            model:    @tier,
            messages: messages,
            tools: [ { type: "function",
                       function: { name: tool_name, description: "Return the structured decision.", parameters: schema } } ],
            tool_choice: { type: "function", function: { name: tool_name } }
          }
          request_options = {}
          request_options[:extra_body] = { metadata: { tags: Array(tags) } } if Array(tags).any?

          response =
            if request_options.empty?
              client.chat.completions.create(**params)
            else
              client.chat.completions.create(**params, request_options: request_options)
            end

          parse_arguments(arguments_of(first_tool_call(response)))
        end

        private

        # Incremental text from a streamed chat-completion chunk. Tolerates the gem's
        # struct objects and plain Hashes (fakes in specs). nil when the chunk carries
        # no content delta (e.g. the final role/finish chunk).
        def extract_delta(chunk)
          choice = first_choice(chunk)
          return nil if choice.nil?
          delta =
            if choice.respond_to?(:delta) then choice.delta
            elsif choice.is_a?(Hash) then choice[:delta] || choice["delta"]
            end
          return nil if delta.nil?
          if delta.respond_to?(:content) then delta.content
          elsif delta.is_a?(Hash) then delta[:content] || delta["content"]
          end
        end

        # The assistant message content from a non-streamed chat completion.
        def extract_message_content(response)
          message = message_of(first_choice(response))
          return nil if message.nil?
          if message.respond_to?(:content) then message.content
          elsif message.is_a?(Hash) then message[:content] || message["content"]
          end
        end

        # Memoized client. Building it triggers the lazy require so a missing gem
        # surfaces as a ConfigurationError at first real call (never at boot).
        def client
          @client ||= build_client
        end

        def build_client
          begin
            require "openai"
          rescue LoadError => e
            raise Enliterator::ConfigurationError,
                  "Enliterator::Adapters::LLM::Gateway requires the `openai` gem. " \
                  'Add `gem "openai"` to your host Gemfile and run `bundle install`. ' \
                  "(#{e.message})"
          end

          ::OpenAI::Client.new(api_key: @api_key, base_url: @base_url)
        end

        # Pull the forced tool call's arguments (a JSON string) out of the chat
        # completion and normalize into {"claims"=>[...], "confidence"=>Float,
        # optional "escalate"=>Bool}. Handles the gem's response objects and plain
        # Hashes (for fake clients in specs).
        def extract_parsed(response)
          tool_call = first_tool_call(response)
          args      = tool_call ? arguments_of(tool_call) : nil
          input     = parse_arguments(args)

          parsed = {
            "claims"     => normalize_claims(input["claims"]),
            "confidence" => normalize_confidence(input["confidence"])
          }
          esc = input.key?("escalate") ? input["escalate"] : input[:escalate]
          parsed["escalate"] = !!esc unless esc.nil?

          # v0.3: pass through any model-proposed suggestions (contract path). The
          # Visitor persists these as Enliterator::Suggestion rows. Absent on the
          # no-contract path, so the key only appears when the model emits it.
          sugg = input.key?("suggestions") ? input["suggestions"] : input[:suggestions]
          parsed["suggestions"] = normalize_suggestions(sugg) unless sugg.nil?

          parsed
        end

        # Normalize the optional suggestions array into string-keyed hashes the
        # Visitor can persist directly. Tolerant of symbol/string keys.
        def normalize_suggestions(suggestions)
          Array(suggestions).map do |s|
            h = s.is_a?(Hash) ? s : {}
            {
              "proposed_key"  => h["proposed_key"]  || h[:proposed_key],
              "rationale"     => h["rationale"]     || h[:rationale],
              "example_value" => h.key?("example_value") ? h["example_value"] : h[:example_value]
            }.compact
          end
        end

        # The first tool call on the first choice's message, across struct/hash shapes.
        def first_tool_call(response)
          choice  = first_choice(response)
          message = message_of(choice)
          return nil unless message

          calls =
            if message.respond_to?(:tool_calls)
              message.tool_calls
            elsif message.is_a?(Hash)
              message[:tool_calls] || message["tool_calls"]
            end

          Array(calls).first
        end

        def first_choice(response)
          choices =
            if response.respond_to?(:choices)
              response.choices
            elsif response.is_a?(Hash)
              response[:choices] || response["choices"]
            end

          Array(choices).first
        end

        def message_of(choice)
          return nil if choice.nil?

          if choice.respond_to?(:message)
            choice.message
          elsif choice.is_a?(Hash)
            choice[:message] || choice["message"]
          end
        end

        # The JSON-string arguments live on tool_call.function.arguments.
        def arguments_of(tool_call)
          fn =
            if tool_call.respond_to?(:function)
              tool_call.function
            elsif tool_call.is_a?(Hash)
              tool_call[:function] || tool_call["function"]
            end
          return nil if fn.nil?

          if fn.respond_to?(:arguments)
            fn.arguments
          elsif fn.is_a?(Hash)
            fn[:arguments] || fn["arguments"]
          end
        end

        # Tool-call arguments are a JSON string per the OpenAI spec; tolerate an
        # already-parsed Hash defensively. Returns a Hash (string keys preferred).
        def parse_arguments(args)
          case args
          when Hash   then args
          when String then (JSON.parse(args) rescue {})
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

        # Map the chat completion usage into the engine's token shape.
        def extract_tokens(response)
          usage =
            if response.respond_to?(:usage)
              response.usage
            elsif response.is_a?(Hash)
              response[:usage] || response["usage"]
            end
          return {} unless usage

          {
            "input"  => usage_value(usage, :prompt_tokens),
            "output" => usage_value(usage, :completion_tokens),
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
            { "adapter" => "gateway", "tier" => @tier }
          end
        rescue StandardError
          { "adapter" => "gateway", "tier" => @tier }
        end
      end
    end
  end
end
