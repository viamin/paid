# frozen_string_literal: true

require "rails_helper"
require "tmpdir"

RSpec.describe Github::AppCredentialsPersister do
  let(:pem) { OpenSSL::PKey::RSA.new(2048).to_pem }
  let(:result) do
    Github::AppManifestExchanger::Result.new(
      app_id: 99,
      slug: "paid-agents-self-hosted",
      html_url: "https://github.com/apps/paid-agents-self-hosted",
      private_key: pem,
      webhook_secret: "shhh"
    )
  end
  let(:credentials_dir) { Dir.mktmpdir("credentials") }
  let(:credentials_path) { File.join(credentials_dir, "credentials.yml.enc") }
  let(:fake_credentials) do
    instance_double(
      ActiveSupport::EncryptedConfiguration,
      key?: true,
      config: {},
      content_path: Pathname.new(credentials_path)
    )
  end

  before do
    allow(Rails.application).to receive(:credentials).and_return(fake_credentials)
  end

  after do
    FileUtils.remove_entry(credentials_dir) if File.directory?(credentials_dir)
  end

  describe ".call" do
    it "writes the manifest result into the credentials file when writable" do
      written = nil
      allow(fake_credentials).to receive(:write) do |contents|
        written = contents
      end

      outcome = described_class.call(result: result)

      expect(outcome).to be_persisted
      expect(outcome.credentials_path).to eq(credentials_path)
      expect(outcome.written_keys).to contain_exactly(
        "paid_agent_app_id",
        "paid_agent_app_private_key",
        "paid_agent_app_slug",
        "paid_agent_app_webhook_secret"
      )

      parsed = YAML.safe_load(written)
      expect(parsed["paid_agent_app_id"]).to eq("99")
      expect(parsed["paid_agent_app_slug"]).to eq("paid-agents-self-hosted")
      expect(parsed["paid_agent_app_private_key"]).to eq(pem)
      expect(parsed["paid_agent_app_webhook_secret"]).to eq("shhh")
    end

    it "merges with existing credentials instead of clobbering them" do
      allow(fake_credentials).to receive(:config).and_return(
        "secret_key_base" => "abc",
        "operator_console" => { "emails" => [ "ops@example.com" ] }
      )

      written = nil
      allow(fake_credentials).to receive(:write) do |contents|
        written = contents
      end

      described_class.call(result: result)

      parsed = YAML.safe_load(written)
      expect(parsed["secret_key_base"]).to eq("abc")
      expect(parsed["operator_console"]["emails"]).to eq([ "ops@example.com" ])
      expect(parsed["paid_agent_app_id"]).to eq("99")
    end

    it "falls back to manual instructions when the credentials key is missing" do
      allow(fake_credentials).to receive(:key?).and_return(false)

      outcome = described_class.call(result: result)

      expect(outcome).to be_manual
      expect(outcome.written_keys).to be_empty
      expect(outcome.manual_instructions).to include("PAID_AGENT_APP_ID")
      expect(outcome.manual_instructions).to include("PAID_AGENT_APP_WEBHOOK_SECRET")
      expect(outcome.manual_instructions).to include("paid_agent_app_id")
      expect(outcome.manual_instructions).to include("99")
    end

    it "falls back to manual instructions when the credentials file is read-only" do
      allow(fake_credentials).to receive(:write).and_raise(Errno::EACCES)

      outcome = described_class.call(result: result)

      expect(outcome).to be_manual
      expect(outcome.manual_instructions).to include("PAID_AGENT_APP_ID")
    end

    # The manual instructions surface the PEM and webhook secret that GitHub
    # returns only once, so the YAML snippet must remain copy-pasteable into
    # credentials. Squishing the entire heredoc would collapse the
    # newline-separated YAML into one paragraph and break that path.
    it "preserves YAML line breaks in the manual instructions" do
      allow(fake_credentials).to receive(:key?).and_return(false)

      outcome = described_class.call(result: result)

      expect(outcome.manual_instructions).to include(
        "  paid_agent_app_id: \"99\"\n" \
        "  paid_agent_app_slug: \"paid-agents-self-hosted\"\n" \
        "  paid_agent_app_private_key: #{pem.inspect}\n" \
        "  paid_agent_app_webhook_secret: \"shhh\""
      )
    end

    it "falls back to manual instructions when the credentials file is missing the master key" do
      allow(fake_credentials).to receive(:write).and_raise(ActiveSupport::EncryptedFile::MissingKeyError.new(key_path: "/x", env_key: "RAILS_MASTER_KEY"))

      outcome = described_class.call(result: result)

      expect(outcome).to be_manual
      expect(outcome.manual_instructions).to include("PAID_AGENT_APP_ID")
    end

    it "omits blank values when assembling the payload" do
      sparse_result = Github::AppManifestExchanger::Result.new(
        app_id: 7,
        slug: nil,
        html_url: "https://github.com/apps/x",
        private_key: pem,
        webhook_secret: "shhh"
      )

      written = nil
      allow(fake_credentials).to receive(:write) do |contents|
        written = contents
      end

      described_class.call(result: sparse_result)

      parsed = YAML.safe_load(written)
      expect(parsed).not_to have_key("paid_agent_app_slug")
      expect(parsed["paid_agent_app_id"]).to eq("7")
    end
  end
end
