# frozen_string_literal: true

require "rails_helper"
require "digest"
require "webmock/rspec"

RSpec.describe Runners::ManagedCredentialLifecycle do
  # @spec SUBSCRIPTION-RUNNER-AUTH-007
  describe "the explicit Codex recovery contract" do
    let(:account_id) { "synthetic-managed-account" }
    let(:original) { JSON.generate(native_auth(expiry: 1.minute.ago, refresh: "synthetic-original")) }
    let(:rotated) { native_auth(expiry: 1.hour.from_now, refresh: "synthetic-rotated") }
    let(:paths) { [] }
    let(:exchanges) { [] }
    let(:credential) do
      Struct.new(:token, :expires_at, :metadata, :revoked_at, :saves, keyword_init: true) do
        def with_lock
          yield
        end

        def reload = self
        def id = 5280
        def revoked? = revoked_at.present?
        def active? = !revoked? && (expires_at.nil? || expires_at > Time.current)

        def assign_attributes(attributes)
          attributes.each { |key, value| public_send("#{key}=", value) }
        end

        def save!
          self.saves += 1
        end
      end.new(token: original, expires_at: 1.minute.ago, metadata: {}, saves: 0)
    end
    let(:authentication) do
      Module.new do
        def self.exchange_refresh_token_supported?(_provider) = true

        def self.credential_metadata(_provider, credential_path:)
          raise NotImplementedError
        end

        def self.exchange_refresh_token(_provider, credential_path:, expected_generation:, expected_account_id:, timeout:)
          raise NotImplementedError
        end
      end
    end

    def native_auth(expiry:, refresh:)
      claims = { "exp" => expiry.to_i, "https://api.openai.com/auth" => { "chatgpt_account_id" => account_id } }
      access = "header.#{Base64.urlsafe_encode64(JSON.generate(claims), padding: false)}.signature"
      { "OPENAI_API_KEY" => nil, "tokens" => { "account_id" => account_id,
        "access_token" => access, "refresh_token" => refresh } }
    end

    def metadata_for(path)
      parsed = CodexCredentials::Secret.parse(File.binread(path))
      { provider: :codex, billing_mode: :chatgpt_subscription, account_id: parsed.account_id,
        expires_at: parsed.expires_at, expired: parsed.expires_at <= Time.current,
        refreshable: parsed.refreshable?, generation: Digest::SHA256.file(path).hexdigest }
    end

    def write_result(path, native = rotated)
      File.write(path, JSON.pretty_generate(native))
      { credentials: native, metadata: metadata_for(path) }
    end

    def expect_private_stores_removed
      expect(paths).not_to be_empty
      paths.uniq.each do |path|
        expect(File.exist?(path)).to be(false)
        expect(Dir.exist?(File.dirname(path))).to be(false)
      end
    end

    before do
      stub_const("AgentHarness::Authentication", authentication)
      allow(authentication).to receive(:credential_metadata) do |_provider, credential_path:|
        paths << credential_path
        metadata_for(credential_path)
      end
      allow(authentication).to receive(:exchange_refresh_token) do |provider, credential_path:, expected_generation:, expected_account_id:, timeout:|
        exchanges << { provider: provider, native: File.binread(credential_path),
          mode: File.stat(credential_path).mode & 0o777, generation: expected_generation,
          account_id: expected_account_id, timeout: timeout }
        write_result(credential_path)
      end
    end

    it "exchanges only the selected private store and persists native credentials rather than the envelope" do
      expect(described_class.exchange_refresh_token!(credential, runner_key: "codex")).to be(true)
      expect(JSON.parse(credential.token)).to eq(rotated)
      expect(credential.expires_at).to be > Time.current
      expect(credential.saves).to eq(1)
      expect(exchanges.fetch(0)).to include(provider: :codex, native: original, mode: 0o600,
        generation: Digest::SHA256.hexdigest(original), account_id: account_id)
      expect(exchanges.fetch(0).fetch(:timeout)).to be_between(1, 60)
      expect_private_stores_removed
    end

    it "uses the same contract when recovering an expired credential before provisioning" do
      expect(described_class.refresh_if_near_expiry!(credential, runner_key: "codex", provision: true)).to eq(:refreshed)
      expect(JSON.parse(credential.token)).to eq(rotated)
      expect_private_stores_removed
    end

    it "does not select an expired credential without the required native account identity" do
      native = JSON.parse(original)
      native.fetch("tokens").delete("account_id")
      credential.token = JSON.generate(native)

      expect(described_class.readiness(credential, runner_key: "codex")).to eq(:missing_refresh_material)
    end

    [ "", " ", 123, {}, [] ].each do |identity|
      it "does not select a malformed #{identity.class} native account identity" do
        native = JSON.parse(original)
        native.fetch("tokens")["account_id"] = identity
        credential.token = JSON.generate(native)

        expect(described_class.readiness(credential, runner_key: "codex")).to eq(:missing_refresh_material)
      end
    end

    it "keeps fresh access usable without inspecting native secrets when recovery is unsupported" do
      credential.expires_at = Time.current + 1.minute
      allow(authentication).to receive(:exchange_refresh_token_supported?).and_return(false)
      expect(credential).not_to receive(:token)

      expect(described_class.readiness(credential, runner_key: "codex")).to eq(:fresh)
    end

    [ nil, [], { credentials: [] }, { credentials: {}, metadata: [] } ].each do |envelope|
      it "rejects a malformed #{envelope.inspect} envelope without persisting" do
        allow(authentication).to receive(:exchange_refresh_token).and_return(envelope)
        expect { described_class.exchange_refresh_token!(credential, runner_key: "codex") }
          .to raise_error(described_class::InvalidRefreshResponse)
        expect(credential.token).to eq(original)
        expect(credential.saves).to eq(0)
        expect_private_stores_removed
      end
    end

    it "rejects a stale returned generation" do
      allow(authentication).to receive(:exchange_refresh_token) do |_provider, credential_path:, **|
        write_result(credential_path).tap { |value| value[:metadata][:generation] = "0" * 64 }
      end
      expect { described_class.exchange_refresh_token!(credential, runner_key: "codex") }
        .to raise_error(described_class::InvalidRefreshResponse)
      expect(credential.token).to eq(original)
      expect_private_stores_removed
    end

    it "rejects a returned identity mismatch" do
      allow(authentication).to receive(:exchange_refresh_token) do |_provider, credential_path:, **|
        write_result(credential_path).tap { |value| value[:metadata][:account_id] = "another-account" }
      end
      expect { described_class.exchange_refresh_token!(credential, runner_key: "codex") }
        .to raise_error(described_class::InvalidRefreshResponse)
      expect(credential.token).to eq(original)
      expect_private_stores_removed
    end

    it "rejects expired returned access" do
      allow(authentication).to receive(:exchange_refresh_token) do |_provider, credential_path:, **|
        write_result(credential_path, native_auth(expiry: 1.minute.ago, refresh: "rotated"))
      end
      expect { described_class.exchange_refresh_token!(credential, runner_key: "codex") }
        .to raise_error(described_class::InvalidRefreshResponse)
      expect(credential.saves).to eq(0)
      expect_private_stores_removed
    end

    it "preserves a newer canonical generation instead of overwriting it" do
      newer = JSON.generate(native_auth(expiry: 2.hours.from_now, refresh: "newer-generation"))
      allow(authentication).to receive(:exchange_refresh_token) do |_provider, credential_path:, **|
        credential.token = newer
        write_result(credential_path)
      end
      expect { described_class.exchange_refresh_token!(credential, runner_key: "codex") }
        .to raise_error(described_class::InvalidRefreshResponse)
      expect(credential.token).to eq(newer)
      expect(credential.saves).to eq(0)
      expect_private_stores_removed
    end

    it "removes the private store after a provider authentication failure" do
      allow(authentication).to receive(:exchange_refresh_token).and_raise(AgentHarness::AuthenticationError, "invalid_refresh_token")
      expect { described_class.exchange_refresh_token!(credential, runner_key: "codex") }
        .to raise_error(AgentHarness::AuthenticationError)
      expect(credential.token).to eq(original)
      expect(credential.saves).to eq(0)
      expect_private_stores_removed
    end

    it "removes the private store on cancellation before commit" do
      allow(authentication).to receive(:exchange_refresh_token).and_raise(Timeout::Error)
      expect { described_class.exchange_refresh_token!(credential, runner_key: "codex") }.to raise_error(Timeout::Error)
      expect(credential.token).to eq(original)
      expect(credential.saves).to eq(0)
      expect_private_stores_removed
    end
  end

  # @spec SUBSCRIPTION-RUNNER-AUTH-007
  describe "the published SDK native-commit handoff" do
    let(:account) { create(:account) }
    let(:user) { create(:user, account: account) }
    let(:native) { JSON.parse(file_fixture("codex_auth_valid.json").read) }
    let(:paths) { [] }
    let(:native_commits) { [] }
    let(:credential) do
      create(:runner_credential, account: account, created_by: user, runner_key: "codex",
        auth_kind: "oauth_token", token: JSON.generate(native), expires_at: 1.minute.ago)
    end

    before do
      unless AgentHarness::Authentication.respond_to?(:credential_metadata) &&
          AgentHarness::Authentication.exchange_refresh_token_supported?(:codex)
        skip "Requires containing published Codex recovery release adoption; #5262"
      end
    end

    def observe_native_commit
      allow(AgentHarness::Authentication).to receive(:credential_metadata).and_wrap_original do |original, provider, credential_path:|
        paths << credential_path
        original.call(provider, credential_path: credential_path)
      end
      allow(File).to receive(:rename).and_wrap_original do |original, from, destination|
        result = original.call(from, destination)
        if destination.end_with?("/auth.json")
          native_commits << destination
          sleep 0.3
        end
        result
      end
    end

    def recover_with_caller_watchdog(record)
      Timeout.timeout(0.2) { described_class.exchange_refresh_token!(record, runner_key: "codex") }
    rescue Timeout::Error
      :caller_timeout
    end

    it "persists an actual committed rotation before removing the temporary store on caller timeout" do
      record = credential
      observe_native_commit
      access = fresh_codex_access_token(account_id: native.fetch("tokens").fetch("account_id"))
      stub_request(:post, "https://auth.openai.com/oauth/token").to_return(status: 200,
        body: JSON.generate("access_token" => access, "refresh_token" => "synthetic-handoff-refresh"))

      expect(recover_with_caller_watchdog(record)).to be(true).or(eq(:caller_timeout))
      expect(native_commits.size).to eq(1)
      expect(JSON.parse(record.reload.token).dig("tokens", "refresh_token")).to eq("synthetic-handoff-refresh")
      paths.uniq.each do |path|
        expect(File.exist?(path)).to be(false)
        expect(Dir.exist?(File.dirname(path))).to be(false)
      end
    end
  end
end
