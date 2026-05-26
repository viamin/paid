# frozen_string_literal: true

require "rails_helper"

RSpec.describe Github::AppInstallation do
  let(:installation_id) { 42 }
  let(:repo_full_name) { "acme/test-repo" }
  let(:app_id) { "123456" }
  let(:private_key) { OpenSSL::PKey::RSA.new(2048).to_pem }
  let(:fake_token) { "ghs_test_token_abc123" }

  around do |example|
    original_id = ENV.delete("PAID_AGENT_APP_ID")
    original_key = ENV.delete("PAID_AGENT_APP_PRIVATE_KEY")
    example.run
  ensure
    ENV["PAID_AGENT_APP_ID"] = original_id
    ENV["PAID_AGENT_APP_PRIVATE_KEY"] = original_key
  end

  before do
    ENV["PAID_AGENT_APP_ID"] = app_id
    ENV["PAID_AGENT_APP_PRIVATE_KEY"] = private_key
  end

  describe ".token_for" do
    before do
      stub_request(:post, %r{/app/installations/\d+/access_tokens})
        .to_return(
          status: 201,
          body: { token: fake_token, expires_at: 1.hour.from_now.iso8601 }.to_json,
          headers: { "Content-Type" => "application/json" }
        )
    end

    it "mints and caches an installation token" do
      token = described_class.token_for(installation_id: installation_id, repo_full_name: repo_full_name)
      expect(token).to eq(fake_token)
    end

    it "uses the configured cache key" do
      cache_key = described_class.cache_key(installation_id, repo_full_name)
      expect(cache_key).to include(installation_id.to_s)
      expect(cache_key).to include(repo_full_name)
    end
  end

  describe "#mint" do
    context "when App is not configured" do
      before do
        ENV["PAID_AGENT_APP_PRIVATE_KEY"] = ""
      end

      it "raises ConfigurationError" do
        instance = described_class.new(installation_id: installation_id, repo_full_name: repo_full_name)
        expect { instance.mint }.to raise_error(Github::AppInstallation::ConfigurationError, /not configured/i)
      end
    end

    context "when API returns an error" do
      before do
        stub_request(:post, %r{/app/installations/\d+/access_tokens})
          .to_return(status: 401, body: { message: "Bad credentials" }.to_json)
      end

      it "raises Error with status and message" do
        expect {
          described_class.token_for(installation_id: installation_id, repo_full_name: repo_full_name)
        }.to raise_error(Github::AppInstallation::Error, /401.*Bad credentials/)
      end
    end
  end
end
