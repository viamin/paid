# frozen_string_literal: true

require "rails_helper"
require "tempfile"

RSpec.describe AgentHarness::Authentication, :no_db do
  def synthetic_jwt(account_id:, expires_at: 1.hour.from_now)
    header = Base64.urlsafe_encode64(JSON.generate(alg: "none"), padding: false)
    payload = Base64.urlsafe_encode64(JSON.generate(
      exp: expires_at.to_i,
      "https://api.openai.com/auth" => { chatgpt_account_id: account_id }
    ), padding: false)
    "#{header}.#{payload}.signature"
  end

  def successful_http_factory(account_id:)
    response = Net::HTTPOK.new("1.1", "200", "OK")
    response.instance_variable_set(:@body, JSON.generate(
      access_token: synthetic_jwt(account_id:), refresh_token: "rotated-refresh"
    ))
    response.instance_variable_set(:@read, true)
    client = instance_double(Net::HTTP, request: response)
    allow(client).to receive(:use_ssl=)
    allow(client).to receive(:open_timeout=)
    allow(client).to receive(:read_timeout=)
    allow(client).to receive(:write_timeout=)
    Class.new do
      define_method(:initialize) { |http_client| @http_client = http_client }
      define_method(:new) { |_host, _port| @http_client }
    end.new(client)
  end

  def recover_codex(path:, metadata:, account_id: metadata.fetch(:account_id))
    described_class.exchange_refresh_token(
      :codex,
      credential_path: path,
      expected_generation: metadata.fetch(:generation),
      expected_account_id: account_id,
      timeout: 1,
      http_factory: successful_http_factory(account_id:)
    )
  end

  def expect_recovery_error(code, &)
    expect(&).to raise_error(AgentHarness::AuthenticationError) { |error| expect(error.error_code).to eq(code) }
  end

  # @spec TOOLCHAIN-PIN-035 SUBSCRIPTION-RUNNER-AUTH-006 LLM-ROUTING-011
  it "advertises managed Codex recovery while preserving Claude and unsupported-provider capabilities" do
    auth_path = Tempfile.new("paid-codex-auth")
    auth_path.write(file_fixture("codex_auth_valid.json").read)
    auth_path.flush

    codex = described_class.auth_capabilities(:codex)
    metadata = described_class.credential_metadata(:codex, credential_path: auth_path.path)

    expect(AgentHarness::VERSION).to eq("0.46.2")
    expect(codex).to include(exchange: true, managed_oauth_recovery: true)
    expect(metadata).to include(
      provider: :codex,
      billing_mode: :chatgpt_subscription,
      account_id: "acc_managed-codex-001",
      refreshable: true,
      generation: a_string_matching(/\A[0-9a-f]{64}\z/)
    )
    expect(described_class.auth_capabilities(:claude)).to include(exchange: true)
    expect(described_class.exchange_refresh_token_supported?(:gemini)).to be(false)
  ensure
    auth_path&.close!
  end

  # @spec TOOLCHAIN-PIN-035 SUBSCRIPTION-RUNNER-AUTH-006 LLM-ROUTING-011
  it "bounds synthetic recovery to the selected generation and account identity" do
    Dir.mktmpdir("paid-codex-recovery") do |directory|
      credential_path = File.join(directory, "auth.json")
      source = file_fixture("codex_auth_valid.json").read
      File.write(credential_path, source)
      metadata = described_class.credential_metadata(:codex, credential_path: credential_path)
      result = recover_codex(path: credential_path, metadata:)

      expect(result.fetch(:metadata)).to include(account_id: metadata.fetch(:account_id), refreshable: true)
      expect(File.read(credential_path)).to include("rotated-refresh")
      expect(Dir.children(directory)).to match_array(%w[auth.json auth.json.lock])

      expect_recovery_error(:concurrent_update) { recover_codex(path: credential_path, metadata:) }

      refreshed_metadata = described_class.credential_metadata(:codex, credential_path: credential_path)
      expect_recovery_error(:identity_mismatch) do
        recover_codex(path: credential_path, metadata: refreshed_metadata, account_id: "another-account")
      end
    end
  end
end
