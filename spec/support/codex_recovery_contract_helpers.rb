# frozen_string_literal: true

require "base64"
require "digest"

module CodexRecoveryContractHelpers
  def fresh_codex_access_token(account_id:)
    claims = { "exp" => 1.hour.from_now.to_i,
      "https://api.openai.com/auth" => { "chatgpt_account_id" => account_id } }
    "header.#{Base64.urlsafe_encode64(JSON.generate(claims), padding: false)}.signature"
  end

  # Model the published explicit-store API while Paid's separate release-pin
  # change is pending. Real released-SDK acceptance runs separately (#5262).
  def stub_codex_harness_exchange(payload)
    original = AgentHarness::Authentication
    metadata = lambda do |path|
      parsed = CodexCredentials::Secret.parse(File.binread(path))
      { provider: :codex, billing_mode: :chatgpt_subscription, account_id: parsed.account_id,
        generation: Digest::SHA256.file(path).hexdigest, refreshable: parsed.refreshable?,
        expires_at: parsed.expires_at, expired: parsed.expires_at && parsed.expires_at <= Time.current }
    end
    contract = Module.new
    contract.define_singleton_method(:exchange_refresh_token_supported?) do |provider|
      provider.to_sym == :codex || original.exchange_refresh_token_supported?(provider)
    end
    contract.define_singleton_method(:credential_metadata) do |_provider, credential_path:|
      metadata.call(credential_path)
    end
    contract.define_singleton_method(:exchange_refresh_token) do |provider, **options|
      next original.exchange_refresh_token(provider, **options) unless provider.to_sym == :codex

      path = options.fetch(:credential_path)
      raise "Missing finite recovery budget" unless options.fetch(:timeout).between?(1, 60)
      raise "Stale generation" unless options.fetch(:expected_generation) == Digest::SHA256.file(path).hexdigest
      raise "Wrong selected account" unless options.fetch(:expected_account_id) == metadata.call(path).fetch(:account_id)

      File.write(path, JSON.pretty_generate(payload))
      { credentials: payload, metadata: metadata.call(path) }
    end
    contract.define_singleton_method(:method_missing) { |method, *args, **options, &block| original.public_send(method, *args, **options, &block) }
    contract.define_singleton_method(:respond_to_missing?) { |method, private_methods = false| original.respond_to?(method, private_methods) }
    stub_const("AgentHarness::Authentication", contract)
  end
end

RSpec.configure { |config| config.include CodexRecoveryContractHelpers }
