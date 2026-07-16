module Enliterator
  module Adapters
    module LLM
      # LiteLLM gateway adapter — the v0.2 routing target.
      #
      # Talks to the LiteLLM gateway (https://llm.example.com/v1, OpenAI-compatible)
      # via the official `openai` gem (github.com/openai/openai-ruby). The engine
      # names a capability TIER (a LiteLLM alias like "cheap" or "quality") as the
      # model id; LiteLLM owns provider selection, fallback, load-balancing, and
      # cost. The engine never names a provider.
      #
      #   Enliterator::Adapters::LLM::Gateway.new(
      #     tier:     "cheap",
      #     base_url: "https://llm.example.com/v1",
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
        # The outcome of one converse_with_tools round: a final text answer, OR a
        # set of tool calls to execute and feed back. Exactly one is populated.
        # +tokens+ is {} on the stream path (stream_raw yields no usage block) —
        # that empty hash is expected there, not a bug.
        ToolTurn = Struct.new(:text, :tool_calls, :assistant_message, :tokens, keyword_init: true)

        # @param tier     [String] LiteLLM alias used as the model id (e.g. "cheap", "quality").
        # @param base_url [String] gateway base URL (OpenAI-compatible, e.g. "https://llm.example.com/v1").
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
        def tend(text:, facet:, state:, neighbors:, tags: [], contract: nil, required: nil, candidates: nil, source_changed: false)
          messages = [
            { role: "system", content: system_for(contract, required: required, candidates: candidates, source_changed: source_changed) },
            {
              role: "user",
              content: build_user(text: text, facet: facet, state: state, neighbors: neighbors)
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
                  parameters: schema_for(contract, required: required)
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

          # v0.57.1: optional explicit output ceiling (nil default sends nothing —
          # request byte-identical) so finish_reason=length means a REAL truncation.
          if (cap = Enliterator.configuration.gateway_max_tokens)
            params[:max_tokens] = cap.to_i
          end

          # v0.57.1: auto-retry the PROVIDER-SERIALIZATION quirk. Root-caused by
          # the spine host (~7% of long subject_indexing tends): bedrock via
          # LiteLLM intermittently double-encodes the tool-call claims array into
          # a JSON string, rarely unparseable — the model's output is fine, and a
          # plain re-ask clears it (2 of 3 on first retry, the rest on the second
          # in the field). Without this, a transient quirk became a PERMANENT
          # silent facet hole. The retry lives HERE (not the HTTP client — the
          # HTTP call succeeds) and only for ProviderSerializationError: genuine
          # model-format faults and every other error keep their old behavior.
          # Token spend of ALL attempts is summed into the Result — retries are
          # never free and never invisible.
          spent = []
          attempts = 0
          begin
            response =
              if request_options.empty?
                client.chat.completions.create(**params)
              else
                client.chat.completions.create(**params, request_options: request_options)
              end
            spent << extract_tokens(response)
            parsed = extract_parsed(response)
          rescue Enliterator::Adapters::LLM::ProviderSerializationError => e
            attempts += 1
            if attempts <= SERIALIZATION_RETRIES
              Enliterator.logger&.warn(
                "[enliterator] provider-serialization quirk on #{facet} (attempt #{attempts}/#{SERIALIZATION_RETRIES}) — re-asking: #{e.message[0, 120]}"
              )
              retry
            end
            raise
          end

          Result.new(
            parsed: parsed,
            raw:    raw_hash(response),
            tokens: sum_tokens(spent)
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

        # v0.28: one round of an optional-multi-tool conversation. With a block +
        # stream, text deltas are yielded and a text-only ToolTurn is returned.
        # Otherwise a non-streamed call returns either tool_calls (to execute) or
        # text (the final answer). The loop owns multi-round control flow.
        def converse_with_tools(messages:, tools:, tags: [], stream: false, &block)
          params = { model: @tier, messages: messages, tools: tools, tool_choice: "auto" }
          request_options = {}
          request_options[:extra_body] = { metadata: { tags: Array(tags) } } if Array(tags).any?

          if stream && block
            full = +""
            # Tool calls stream as fragmented choice.delta.tool_calls entries keyed by
            # index — id/name typically land on the first fragment, arguments accrete
            # across many. Accumulate per index; preserve emission order.
            fragments = {} # index => { id:, name:, args: +"" }
            args = params.dup
            args[:request_options] = request_options unless request_options.empty?
            client.chat.completions.stream_raw(**args).each do |chunk|
              delta = extract_delta(chunk)
              if delta && !delta.empty?
                full << delta
                block.call(delta)
              end
              extract_tool_call_deltas(chunk).each do |tcd|
                idx = tcd[:index] || fragments.size
                frag = (fragments[idx] ||= { id: nil, name: nil, args: +"" })
                frag[:id]   = tcd[:id]   unless tcd[:id].nil?
                frag[:name] = tcd[:name] unless tcd[:name].nil?
                frag[:args] << tcd[:arguments].to_s unless tcd[:arguments].nil?
              end
              # Skip chunks carrying neither content nor tool deltas (role/finish chunks).
            end

            if fragments.any?
              ordered = fragments.sort_by { |idx, _| idx }.map { |_, f| f }
              tool_calls = ordered.map do |f|
                { id: f[:id], name: f[:name].to_s, arguments: parse_arguments(f[:args]) }
              end
              assistant_message = {
                "role" => "assistant", "content" => nil,
                "tool_calls" => ordered.map do |f|
                  { "id" => f[:id], "type" => "function",
                    "function" => { "name" => f[:name], "arguments" => f[:args] } }
                end
              }
              return ToolTurn.new(text: full, tool_calls: tool_calls,
                                  assistant_message: assistant_message, tokens: {})
            end

            return ToolTurn.new(text: full, tool_calls: [], assistant_message: nil, tokens: {})
          end

          response =
            if request_options.empty?
              client.chat.completions.create(**params)
            else
              client.chat.completions.create(**params, request_options: request_options)
            end

          calls = all_tool_calls(response)
          if calls.any?
            ToolTurn.new(text: nil, tool_calls: calls, assistant_message: assistant_message_of(response),
                         tokens: extract_tokens(response))
          else
            ToolTurn.new(text: extract_message_content(response).to_s, tool_calls: [], assistant_message: nil,
                         tokens: extract_tokens(response))
          end
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

        # Tool-call fragments from a streamed chunk's choice.delta.tool_calls. Returns
        # [{index:, id:, name:, arguments:}] (any of id/name/arguments may be nil on a
        # given fragment), or [] when the chunk carries no tool-call delta. Tolerates the
        # gem's struct objects and plain Hashes (fakes in specs), mirroring extract_delta.
        def extract_tool_call_deltas(chunk)
          choice = first_choice(chunk)
          return [] if choice.nil?
          delta =
            if choice.respond_to?(:delta) then choice.delta
            elsif choice.is_a?(Hash) then choice[:delta] || choice["delta"]
            end
          return [] if delta.nil?
          raw =
            if delta.respond_to?(:tool_calls) then delta.tool_calls
            elsif delta.is_a?(Hash) then delta[:tool_calls] || delta["tool_calls"]
            end
          Array(raw).map do |tc|
            index = tc.respond_to?(:index) ? tc.index : (tc.is_a?(Hash) ? (tc[:index] || tc["index"]) : nil)
            id    = tc.respond_to?(:id)    ? tc.id    : (tc.is_a?(Hash) ? (tc[:id]    || tc["id"])    : nil)
            fn    = tc.respond_to?(:function) ? tc.function : (tc.is_a?(Hash) ? (tc[:function] || tc["function"]) : nil)
            name      = fn.respond_to?(:name)      ? fn.name      : (fn.is_a?(Hash) ? (fn[:name]      || fn["name"])      : nil)
            arguments = fn.respond_to?(:arguments) ? fn.arguments : (fn.is_a?(Hash) ? (fn[:arguments] || fn["arguments"]) : nil)
            { index: index, id: id, name: name, arguments: arguments }
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

          # v0.23: bounded calls — the gem's defaults (600s timeout × retries)
          # let one wedged request stall a heartbeat phase for tens of minutes.
          ::OpenAI::Client.new(
            api_key: @api_key, base_url: @base_url,
            timeout:     Enliterator.configuration.gateway_timeout,
            max_retries: Enliterator.configuration.gateway_max_retries
          )
        end

        # Pull the forced tool call's arguments (a JSON string) out of the chat
        # completion and normalize into {"claims"=>[...], "confidence"=>Float,
        # optional "escalate"=>Bool}. Handles the gem's response objects and plain
        # Hashes (for fake clients in specs).
        def extract_parsed(response)
          tool_call = first_tool_call(response)
          args      = tool_call ? arguments_of(tool_call) : nil
          input     = parse_arguments(args)

          raw_claims = input["claims"]
          claims     = normalize_claims(raw_claims)

          # No-silent-failures (rule 3): when the model returned a non-empty claims
          # STRING that could not be recovered as an Array by normalize_claims, raise
          # a visible ResponseFormatError so the visitor records a retriable failed
          # visit rather than silently producing empty claims → required_unmet → lacuna.
          #
          # Safe cases that must NOT raise:
          #   - raw_claims is nil / absent / a native Array → not a String
          #   - raw_claims is a String that JSON.parse recovers to an Array (including "[]")
          #     → parse succeeded; empty result is a legitimate no-claims response
          if claims.empty? && raw_claims.is_a?(String) && !raw_claims.strip.empty? &&
               recover_claims_array(raw_claims).nil?
            snippet = raw_claims[0, 200]
            fr      = finish_reason_of(response)
            # v0.57.1: named for what it IS — a provider-serialization quirk
            # (double-encoded tool-call array), not a model-format fault. The
            # subclass keeps every existing rescue working while #tend's
            # auto-retry targets exactly this. finish_reason distinguishes a
            # REAL truncation (length) from the quirk (tool_calls/stop).
            raise Enliterator::Adapters::LLM::ProviderSerializationError,
                  "claims arrived as an unparseable JSON string (provider double-encoding; " \
                  "finish_reason=#{fr || 'unknown'}#{fr == 'length' ? ' — REAL truncation, consider config.gateway_max_tokens' : ''}). " \
                  "Snippet: #{snippet.inspect}"
          end

          parsed = {
            "claims"     => claims,
            "confidence" => normalize_confidence(input["confidence"])
          }
          esc = input.key?("escalate") ? input["escalate"] : input[:escalate]
          parsed["escalate"] = !!esc unless esc.nil?

          # v0.3: pass through any model-proposed suggestions (contract path). The
          # Visitor persists these as Enliterator::Suggestion rows. Absent on the
          # no-contract path, so the key only appears when the model emits it.
          sugg = input.key?("suggestions") ? input["suggestions"] : input[:suggestions]
          parsed["suggestions"] = normalize_suggestions(sugg) unless sugg.nil?

          # v0.46.1: pass through any model-emitted absences (diagnosis channel). The
          # Visitor's absences_index reads {term, diagnosis, note}. Absent on the
          # no-required / flag-off path, so the key only appears when the model emits it.
          abs = input.key?("absences") ? input["absences"] : input[:absences]
          parsed["absences"] = normalize_absences(abs) unless abs.nil?

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

        # Normalize the optional absences array (v0.46.1) into string-keyed hashes the
        # Visitor's absences_index reads directly ({term, diagnosis, note}). Tolerant of
        # symbol/string keys. .compact drops an absent note; term/diagnosis are required
        # by the schema, so they are present when the model emits an entry.
        def normalize_absences(absences)
          Array(absences).map do |a|
            h = a.is_a?(Hash) ? a : {}
            {
              "term"      => h["term"]      || h[:term],
              "diagnosis" => h["diagnosis"] || h[:diagnosis],
              "note"      => h.key?("note") ? h["note"] : h[:note]
            }.compact
          end
        end

        # v0.57.1: bounded re-asks for the provider-serialization quirk. Field
        # data: 2 of 3 clear on the first retry, the rest on the second.
        SERIALIZATION_RETRIES = 2

        # The finish_reason on the first choice ("tool_calls"/"stop"/"length"),
        # across struct/hash shapes; nil when absent (fake clients in specs).
        def finish_reason_of(response)
          choice = first_choice(response)
          return nil unless choice
          fr =
            if choice.respond_to?(:finish_reason)
              choice.finish_reason
            elsif choice.is_a?(Hash)
              choice[:finish_reason] || choice["finish_reason"]
            end
          fr&.to_s
        end

        # Sum per-attempt token hashes into one (v0.57.1: serialization retries
        # bill every attempt — spend is never invisible).
        def sum_tokens(spent)
          spent = spent.reject(&:empty?)
          return spent.last || {} if spent.size <= 1
          %w[input output total].each_with_object({}) do |k, h|
            h[k] = spent.sum { |t| t[k].to_i }
          end
        end

        # v0.57.1: recover a stringified claims array, tolerantly. Bedrock via
        # LiteLLM intermittently double-encodes the tool-call array into a JSON
        # string; usually a plain parse recovers it (the v0.48.1 layer), and two
        # further SAFE repairs salvage the easy malformed shapes (the #tend
        # auto-retry is the real fix for the rest — never guess at content):
        #   (a) double-decoded — the outer parse yields a STRING that is itself
        #       JSON (the quirk's cleanest form);
        #   (b) wrapped — a valid array embedded in stray prose/whitespace:
        #       parse the outermost [...] span.
        # Returns the Array or nil. The ONE shared judge of recoverability —
        # normalize_claims (recovery) and extract_parsed (the raise condition)
        # must never disagree about what counts as recoverable.
        def recover_claims_array(str)
          parsed = (JSON.parse(str) rescue nil)
          parsed = (JSON.parse(parsed) rescue nil) if parsed.is_a?(String)
          if !parsed.is_a?(Array) && (m = str[/\[.*\]/m])
            parsed = (JSON.parse(m) rescue nil)
          end
          parsed.is_a?(Array) ? parsed : nil
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

        # ALL tool calls on the first choice's message, normalized to
        # {id:, name:, arguments: Hash}. (first_tool_call returns only the first.)
        def all_tool_calls(response)
          message = message_of(first_choice(response))
          return [] unless message
          raw =
            if message.respond_to?(:tool_calls)
              message.tool_calls
            elsif message.is_a?(Hash)
              message[:tool_calls] || message["tool_calls"]
            end
          Array(raw).map do |tc|
            id = tc.respond_to?(:id) ? tc.id : (tc.is_a?(Hash) ? (tc[:id] || tc["id"]) : nil)
            fn = tc.respond_to?(:function) ? tc.function : (tc.is_a?(Hash) ? (tc[:function] || tc["function"]) : nil)
            name = fn.respond_to?(:name) ? fn.name : (fn.is_a?(Hash) ? (fn[:name] || fn["name"]) : nil)
            { id: id, name: name.to_s, arguments: parse_arguments(arguments_of(tc)) }
          end
        end

        # The assistant message, as a plain Hash with its tool_calls, for the loop
        # to append to messages before the tool-result messages (OpenAI requires the
        # assistant turn carrying tool_calls to precede the matching tool messages).
        def assistant_message_of(response)
          message = message_of(first_choice(response))
          calls = (message.respond_to?(:tool_calls) ? message.tool_calls :
                   (message.is_a?(Hash) ? (message[:tool_calls] || message["tool_calls"]) : [])) || []
          {
            "role" => "assistant",
            "content" => nil,
            "tool_calls" => Array(calls).map do |tc|
              id = tc.respond_to?(:id) ? tc.id : (tc.is_a?(Hash) ? (tc[:id] || tc["id"]) : nil)
              fn = tc.respond_to?(:function) ? tc.function : (tc.is_a?(Hash) ? (tc[:function] || tc["function"]) : nil)
              name = fn.respond_to?(:name) ? fn.name : (fn.is_a?(Hash) ? (fn[:name] || fn["name"]) : nil)
              { "id" => id, "type" => "function",
                "function" => { "name" => name, "arguments" => arguments_of(tc).to_s } }
            end
          }
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
          # Re-parse a stringified claims array. Bedrock-sonnet intermittently returns
          # the `claims` array as a JSON string rather than a native array. Attempt
          # recovery before falling through to the per-element normalization.
          # When the string cannot be parsed (malformed JSON), claims stays as-is;
          # Array(String) wraps it in a single-element array; the element is not a Hash
          # so it normalizes to {} and is rejected below. extract_parsed detects the
          # non-empty-string-with-empty-result case and raises ResponseFormatError.
          if claims.is_a?(String)
            parsed = recover_claims_array(claims)
            claims = parsed if parsed
          end
          Array(claims).map do |c|
            h = c.is_a?(Hash) ? c : {}
            {
              "key"        => h["key"] || h[:key],
              "value"      => h.key?("value") ? h["value"] : h[:value],
              "confidence" => h["confidence"] || h[:confidence],
              "op"         => h["op"] || h[:op]
            }.compact
          end.reject { |h| h["key"].nil? }
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
