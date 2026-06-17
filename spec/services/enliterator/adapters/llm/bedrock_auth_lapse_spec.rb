# frozen_string_literal: true

require "rails_helper"

# v0.41.1 — the grant runs on a $10k Bedrock credit and MUST stay on bedrock
# (the campaign tier never falls back to another model). An expired AWS SSO
# session is therefore a re-auth PAUSE, not a failure: the heartbeat defers the
# bedrock work and resumes on the next beat. `auth_lapsed?` is how the heartbeat
# recognizes that ONE recoverable condition — scoped, by construction, to
# bedrock alone (the expiry signature ANDed with a bedrock scope). Pure string
# match: it never loads the AWS SDK, so it is safe to call from the heartbeat on
# any host (the engine does not depend on aws-sdk-bedrockruntime).

# A direct-SDK error whose class name carries both signals (bedrock + expiry).
module BedrockAuthLapseSpec
  module Aws
    module BedrockRuntime
      module Errors
        class ExpiredTokenException < StandardError; end
      end
    end
  end
end

RSpec.describe "Enliterator::Adapters::LLM::Bedrock.auth_lapsed? (v0.41.1)" do
  def lapsed?(error) = Enliterator::Adapters::LLM::Bedrock.auth_lapsed?(error)

  # HSDL's actual shape: the LiteLLM gateway wraps the BedrockException as a 500
  # whose body names the expired token and the bedrock model group.
  litellm_expired =
    'litellm.APIConnectionError: BedrockException - ' \
    '{"message":"The security token included in the request is expired"} ' \
    "Received Model Group=bedrock-sonnet"

  it "is true for the LiteLLM-wrapped expired token (HSDL's path)" do
    expect(lapsed?(RuntimeError.new(litellm_expired))).to be true
  end

  it "is true for a direct AWS Bedrock ExpiredToken error (class carries it)" do
    error = BedrockAuthLapseSpec::Aws::BedrockRuntime::Errors::ExpiredTokenException.new("token expired")
    expect(lapsed?(error)).to be true
  end

  it "is false for an SSO/expiry error that never mentions bedrock (only-on-bedrock)" do
    expect(lapsed?(RuntimeError.new("The security token included in the request is expired (sts)"))).to be false
  end

  it "is false for a bedrock error that is not an auth lapse (throttling)" do
    expect(lapsed?(RuntimeError.new("BedrockException: ThrottlingException, rate exceeded for bedrock-sonnet"))).to be false
  end

  it "is false for an unrelated runtime error" do
    expect(lapsed?(RuntimeError.new("boom"))).to be false
  end

  it "is false for nil" do
    expect(lapsed?(nil)).to be false
  end

  # v0.41.1 broaden: bedrock is the ONLY tier (the grant funds nothing else), so
  # the whole pipeline must survive transient bedrock unavailability — an
  # expired token AND a gateway timeout (id=56 timed out mid-considerer). Both
  # defer-and-resume; only a real fault stays fatal. `unavailable?` is the gate.
  def unavailable?(error) = Enliterator::Adapters::LLM::Bedrock.unavailable?(error)

  it "unavailable? is true for an API timeout (transient — retry next beat)" do
    expect(unavailable?(RuntimeError.new("OpenAI::Errors::APITimeoutError: Request timed out."))).to be true
  end

  it "unavailable? is true for a read timeout / connection blip" do
    expect(unavailable?(RuntimeError.new("Net::ReadTimeout with #<TCPSocket>"))).to be true
    expect(unavailable?(RuntimeError.new("ServiceUnavailable: 503"))).to be true
  end

  it "unavailable? is true for a bedrock auth lapse (composes auth_lapsed?)" do
    expect(unavailable?(RuntimeError.new(litellm_expired))).to be true
  end

  it "unavailable? is false for a real fault (model not found / bad request)" do
    expect(unavailable?(RuntimeError.new("BadRequestError: model not found"))).to be false
    expect(unavailable?(RuntimeError.new("boom"))).to be false
    expect(unavailable?(nil)).to be false
  end

  it "auth_lapsed? stays auth-specific — a plain timeout is NOT an auth lapse" do
    expect(lapsed?(RuntimeError.new("OpenAI::Errors::APITimeoutError: Request timed out."))).to be false
  end
end
