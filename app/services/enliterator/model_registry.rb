# frozen_string_literal: true

module Enliterator
  # v0.68.1 — WHICH MODEL STANDS BEHIND A TIER ALIAS.
  #
  # A gateway alias ("enliterator-quality") names a capability level; the gateway
  # resolves it to a deployment. v0.68 tried to learn the resolved deployment from
  # the chat response body and could not: LiteLLM ECHOES the requested alias there,
  # so provenance kept recording the alias — the exact gap v0.68 existed to close.
  #
  # The mapping is published at GET {base_url}/model/info:
  #
  #   { "model_name" => "enliterator-quality",
  #     "litellm_params" => { "model" => "bedrock_mantle/openai.gpt-5.6-terra" },
  #     "model_info" => { "id" => "374a0bcf-..." } }
  #
  # HONEST LIMIT: this is the mapping as published *now*, not proof of what served
  # a particular call. A repoint inside the cache TTL mis-stamps that window. Exact
  # per-call attribution is in the `x-litellm-model-id` response header, which the
  # openai gem (0.77.1) gives no way to read — it has no with_raw_response. The map
  # is a large improvement over recording the alias (which is never informative)
  # and is not a guarantee; the deployment id is carried alongside so a repoint is
  # still detectable after the fact.
  #
  # Gated by config.resolve_model_backends. Off (default) ⇒ every method returns
  # nil/empty WITHOUT a network call, so a host that never opts in is byte-identical
  # and the suite never touches the wire.
  class ModelRegistry
    CACHE_KEY = "enliterator/model_registry/v1"
    TTL       = 5.minutes
    TIMEOUT   = 5

    class << self
      # The underlying model behind a tier alias, or nil when unknown/disabled.
      def backend_for(tier, base_url:, api_key:)
        return nil unless enabled?
        map(base_url: base_url, api_key: api_key).dig(tier.to_s, :model)
      end

      # The gateway's deployment id for a tier alias — the value that CHANGES when
      # an alias is repointed, even if the underlying model name looks similar.
      def deployment_for(tier, base_url:, api_key:)
        return nil unless enabled?
        map(base_url: base_url, api_key: api_key).dig(tier.to_s, :deployment)
      end

      # { "alias" => { model: "provider/model", deployment: "uuid" } }
      def map(base_url:, api_key:)
        return {} unless enabled? && base_url.present?

        cached = Rails.cache.fetch(CACHE_KEY, expires_in: TTL) do
          fetch(base_url: base_url, api_key: api_key)
        end
        cached.is_a?(Hash) ? cached : {}
      rescue StandardError => e
        # Never let a metadata lookup break a tend (rule 3: log, don't swallow).
        Enliterator.logger&.warn("[enliterator] model registry unavailable: #{e.class}: #{e.message[0, 160]}")
        {}
      end

      def reset!
        Rails.cache.delete(CACHE_KEY)
      end

      private

      def enabled?
        !!Enliterator.configuration.resolve_model_backends
      end

      def fetch(base_url:, api_key:)
        require "net/http"
        require "json"

        uri = URI.join("#{base_url.to_s.chomp('/')}/", "model/info")
        req = Net::HTTP::Get.new(uri)
        req["Authorization"] = "Bearer #{api_key}" if api_key.present?

        res = Net::HTTP.start(uri.host, uri.port,
                              use_ssl: uri.scheme == "https",
                              open_timeout: TIMEOUT, read_timeout: TIMEOUT) { |h| h.request(req) }
        return {} unless res.is_a?(Net::HTTPSuccess)

        rows = JSON.parse(res.body)["data"]
        return {} unless rows.is_a?(Array)

        rows.each_with_object({}) do |row, acc|
          name = row["model_name"].to_s
          next if name.empty?
          acc[name] = {
            model:      row.dig("litellm_params", "model").presence,
            deployment: row.dig("model_info", "id").presence
          }
        end
      end
    end
  end
end
