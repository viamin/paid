# frozen_string_literal: true

require "rails_helper"

RSpec.describe Github::ReviewBotInstallationToken do
  let(:repo_full_name) { "acme/widgets" }
  let(:service) { described_class.new(repo_full_name: repo_full_name) }
  let(:private_key) { OpenSSL::PKey::RSA.generate(2048).to_pem }

  describe ".configured?" do
    it "returns true when app id and private key are present" do
      allow(described_class).to receive_messages(
        app_id: "3340381",
        private_key: "key"
      )

      expect(described_class.configured?).to be true
    end

    it "returns false when the private key is missing" do
      allow(described_class).to receive_messages(
        app_id: "3340381",
        private_key: nil
      )

      expect(described_class.configured?).to be false
    end
  end

  describe "#fetch" do
    before do
      allow(described_class).to receive_messages(
        private_key: private_key,
        app_id: "3340381",
        configured?: true
      )
    end

    it "fetches an installation token for the repository" do
      stub_request(:get, "https://api.github.com/repos/acme/widgets/installation")
        .with(headers: { "Accept" => "application/vnd.github+json", "Authorization" => /^Bearer / })
        .to_return(status: 200, body: { id: 77 }.to_json, headers: { "Content-Type" => "application/json" })

      stub_request(:post, "https://api.github.com/app/installations/77/access_tokens")
        .with(headers: { "Accept" => "application/vnd.github+json", "Authorization" => /^Bearer / })
        .to_return(status: 201, body: { token: "ghs_installation_token" }.to_json,
          headers: { "Content-Type" => "application/json" })

      expect(service.fetch).to eq("ghs_installation_token")
    end

    it "raises a configuration error when the app is not configured" do
      allow(described_class).to receive(:configured?).and_return(false)

      expect { service.fetch }
        .to raise_error(described_class::ConfigurationError, /not configured/)
    end
  end
end
