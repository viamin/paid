# frozen_string_literal: true

require "rails_helper"

RSpec.describe Runners::AuthHealth do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account, name: "Runner Owner") }
  let(:runner) { user.runners.find_by!(runner_key: "claude", auth_type: "subscription") }

  def call_auth_health
    described_class.call(account: account).fetch(0)
  end

  def stub_claude_auth_status(stdout:, success:)
    status = instance_double(Process::Status, success?: success)
    allow(Open3).to receive(:capture3)
      .with({}, "claude", "auth", "status", "--json")
      .and_return([ stdout, "", status ])
  end

  def with_claude_credentials(payload)
    Dir.mktmpdir do |dir|
      original_dir = ENV["CLAUDE_CONFIG_DIR"]
      ENV["CLAUDE_CONFIG_DIR"] = dir
      File.write(File.join(dir, ".credentials.json"), payload.to_json)
      yield
    ensure
      ENV["CLAUDE_CONFIG_DIR"] = original_dir
    end
  end

  describe ".call" do
    it "returns an empty array when the account has no Claude subscription runners" do
      runner.update_column(:discarded_at, Time.current)
      create(:runner, user: user, runner_key: "codex", auth_type: "subscription")

      expect(described_class.call(account: account)).to eq([])
    end

    it "reports managed OAuth token health for Claude subscription runners" do
      expires_at = 2.days.from_now
      runner
      create(
        :integration_credential,
        :oauth,
        account: account,
        created_by: user,
        service_key: "claude",
        expires_at: expires_at
      )

      result = call_auth_health

      expect(result.valid).to be(true)
      expect(result.expires_at).to be_within(1.second).of(expires_at)
      expect(result.source).to eq(:managed_token)
      expect(result.error).to be_nil
    end

    it "reports expired managed OAuth tokens as invalid" do
      expires_at = 1.hour.ago
      runner
      create(
        :integration_credential,
        :oauth,
        account: account,
        created_by: user,
        service_key: "claude",
        expires_at: expires_at
      )

      result = call_auth_health

      expect(result.valid).to be(false)
      expect(result.expires_at).to be_within(1.second).of(expires_at)
      expect(result.source).to eq(:managed_token)
      expect(result.error).to eq("Managed token expired")
    end

    it "prefers claude auth status JSON for host-forwarded credentials" do
      expires_at = 4.hours.from_now
      runner
      stub_claude_auth_status(stdout: { expiresAt: expires_at.iso8601 }.to_json, success: true)

      result = call_auth_health

      expect(result.valid).to be(true)
      expect(result.expires_at).to be_within(1.second).of(expires_at)
      expect(result.source).to eq(:host_forwarded)
      expect(result.error).to be_nil
    end

    it "falls back to the native Claude credential file when the CLI is unavailable" do
      expires_at = 90.minutes.ago
      runner
      allow(Open3).to receive(:capture3)
        .with({}, "claude", "auth", "status", "--json")
        .and_raise(Errno::ENOENT)

      with_claude_credentials(
        {
          claudeAiOauth: {
            expiresAt: expires_at.iso8601
          }
        }
      ) do
        result = call_auth_health

        expect(result.valid).to be(false)
        expect(result.expires_at).to be_within(1.second).of(expires_at)
        expect(result.source).to eq(:host_forwarded)
        expect(result.error).to eq("Session expired")
      end
    end

    it "reports missing host-forwarded credentials when no fallback file exists" do
      runner
      allow(Open3).to receive(:capture3)
        .with({}, "claude", "auth", "status", "--json")
        .and_raise(Errno::ENOENT)

      with_claude_credentials({}) do
        File.delete(File.join(ENV.fetch("CLAUDE_CONFIG_DIR"), ".credentials.json"))

        result = call_auth_health

        expect(result.valid).to be(false)
        expect(result.expires_at).to be_nil
        expect(result.source).to eq(:host_forwarded)
        expect(result.error).to eq("No credentials found")
      end
    end
  end
end
