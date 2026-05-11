# frozen_string_literal: true

require "rails_helper"

RSpec.describe Github::ReviewBotInstallationToken do
  let(:repo_full_name) { "acme/widgets" }
  let(:service) { described_class.new(repo_full_name: repo_full_name) }
  let(:private_key) { OpenSSL::PKey::RSA.generate(2048).to_pem }

  describe ".configured?" do
    it "returns true when app id and private key are present and parseable" do
      allow(described_class).to receive_messages(
        app_id: "3340381",
        private_key: private_key
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

    it "returns false when the private key is present but not a valid RSA PEM" do
      # e.g. an OpenSSH-format key — passes a presence check but fails at runtime
      openssh_key = "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXk=\n-----END OPENSSH PRIVATE KEY-----\n"
      allow(described_class).to receive_messages(
        app_id: "3340381",
        private_key: openssh_key
      )

      expect(described_class.configured?).to be false
    end

    it "re-validates after the key value changes (no process restart needed)" do
      allow(described_class).to receive(:app_id).and_return("3340381")
      allow(described_class).to receive(:private_key).and_return("not a key")
      expect(described_class.configured?).to be false

      allow(described_class).to receive(:private_key).and_return(private_key)
      expect(described_class.configured?).to be true
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
