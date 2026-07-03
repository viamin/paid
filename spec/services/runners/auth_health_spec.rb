# frozen_string_literal: true

require "rails_helper"

RSpec.describe Runners::AuthHealth do
  around do |example|
    original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    Rails.cache.clear
    example.run
  ensure
    Rails.cache = original_cache
  end

  let(:account) { create(:account) }
  let(:user) { create(:user, account: account, name: "Runner Owner") }
  let(:runner) { user.runners.find_by!(runner_key: "claude", auth_type: "subscription") }
  let(:stderr) { "" }

  def call_auth_health
    described_class.call(account: account).fetch(0)
  end

  def stub_claude_auth_status(stdout:, success:, stderr: self.stderr)
    status = instance_double(Process::Status, success?: success)
    wait_thr = instance_double(Process::Waiter, pid: 12_345, value: status)

    allow(Open3).to receive(:popen3)
      .with({}, "claude", "auth", "status", "--json", pgroup: true)
      .and_yield(
        Popen3Stub::FakeIO.new,
        Popen3Stub::FakeIO.new(stdout),
        Popen3Stub::FakeIO.new(stderr),
        wait_thr
      )
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

  def with_home_dir
    Dir.mktmpdir do |dir|
      original_home = ENV["HOME"]
      ENV["HOME"] = dir
      yield dir
    ensure
      ENV["HOME"] = original_home
    end
  end

  def with_claude_config_dir_unset
    original_dir = ENV["CLAUDE_CONFIG_DIR"]
    ENV.delete("CLAUDE_CONFIG_DIR")
    yield
  ensure
    ENV["CLAUDE_CONFIG_DIR"] = original_dir
  end

  def write_claude_credentials(dir, payload)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, ".credentials.json"), payload.to_json)
  end

  def create_claude_oauth_credential(expires_at:, **attributes)
    create(
      :runner_credential,
      account: account,
      created_by: user,
      runner_key: "claude",
      auth_kind: "oauth_token",
      token: JSON.generate("claudeAiOauth" => { "expiresAt" => expires_at.iso8601 }),
      expires_at: expires_at,
      **attributes
    )
  end

  describe ".call" do
    it "returns an empty array when the account has no Claude subscription runners" do
      runner.update_column(:discarded_at, Time.current)
      create(:runner, user: user, runner_key: "codex", auth_type: "subscription")

      expect(described_class.call(account: account)).to eq([])
    end

    it "reports managed runner credential health for Claude subscription runners" do
      expires_at = 2.days.from_now
      runner
      create_claude_oauth_credential(expires_at:)

      result = call_auth_health

      expect(result.valid).to be(true)
      expect(result.expires_at).to be_within(1.second).of(expires_at)
      expect(result.source).to eq(:managed_token)
      expect(result.error).to be_nil
    end

    it "falls back to host-forwarded auth when the newest managed runner credential is expired" do
      expires_at = 1.hour.ago
      runner
      create_claude_oauth_credential(expires_at:)
      host_forwarded_expires_at = 2.hours.from_now
      stub_claude_auth_status(stdout: { expiresAt: host_forwarded_expires_at.iso8601 }.to_json, success: true)

      result = call_auth_health

      expect(result.valid).to be(true)
      expect(result.expires_at).to be_within(1.second).of(host_forwarded_expires_at)
      expect(result.source).to eq(:host_forwarded)
      expect(result.error).to be_nil
    end

    it "uses the newest active managed runner credential when a newer revoked token exists" do
      active_expires_at = 2.days.from_now
      revoked_expires_at = 5.days.from_now
      runner
      create_claude_oauth_credential(expires_at: active_expires_at, created_at: 2.days.ago)
      create_claude_oauth_credential(expires_at: revoked_expires_at, revoked_at: 1.hour.ago, created_at: 1.day.ago)

      result = call_auth_health

      expect(result.valid).to be(true)
      expect(result.expires_at).to be_within(1.second).of(active_expires_at)
      expect(result.source).to eq(:managed_token)
      expect(result.error).to be_nil
    end

    it "uses the newest active managed runner credential when a newer expired token exists" do
      active_expires_at = 2.days.from_now
      expired_expires_at = 1.hour.ago
      runner
      create_claude_oauth_credential(expires_at: active_expires_at, created_at: 2.days.ago)
      create_claude_oauth_credential(expires_at: expired_expires_at, created_at: 1.day.ago)

      result = call_auth_health

      expect(result.valid).to be(true)
      expect(result.expires_at).to be_within(1.second).of(active_expires_at)
      expect(result.source).to eq(:managed_token)
      expect(result.error).to be_nil
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

    it "treats Claude auth error payloads as invalid even when the CLI exits successfully" do
      runner
      stub_claude_auth_status(
        stdout: {
          error: "Token expired",
          message: "Please run claude auth login"
        }.to_json,
        success: true
      )

      result = call_auth_health

      expect(result.valid).to be(false)
      expect(result.expires_at).to be_nil
      expect(result.source).to eq(:host_forwarded)
      expect(result.error).to eq("Token expired")
    end

    it "checks each host-forwarded runner key only once per service call" do
      runner
      other_user = create(:user, account: account, name: "Second Runner Owner")
      other_user.runners.find_by!(runner_key: "claude", auth_type: "subscription")
      expires_at = 4.hours.from_now
      stub_claude_auth_status(stdout: { expiresAt: expires_at.iso8601 }.to_json, success: true)

      results = described_class.call(account: account)

      expect(results.size).to eq(2)
      expect(Open3).to have_received(:popen3).once
      expect(results.map(&:valid)).to all(be(true))
    end

    it "caches auth health per account to avoid repeated CLI checks on the request path" do
      runner
      expires_at = 4.hours.from_now
      stub_claude_auth_status(stdout: { expiresAt: expires_at.iso8601 }.to_json, success: true)

      first_result = call_auth_health
      second_result = call_auth_health

      expect(Open3).to have_received(:popen3).once
      expect(first_result.valid).to be(true)
      expect(second_result.valid).to be(true)
      expect(second_result.expires_at).to eq(first_result.expires_at)
    end

    it "reuses a shared host-forwarded status cache when provided" do
      runner
      other_account = create(:account)
      other_user = create(:user, account: other_account, name: "Other Runner Owner")
      other_user.runners.find_by!(runner_key: "claude", auth_type: "subscription")
      expires_at = 4.hours.from_now
      stub_claude_auth_status(stdout: { expiresAt: expires_at.iso8601 }.to_json, success: true)
      shared_cache = {}

      first_results = described_class.call(account: account, host_forwarded_status_by_runner_key: shared_cache)
      second_results = described_class.call(account: other_account, host_forwarded_status_by_runner_key: shared_cache)

      expect(first_results.size).to eq(1)
      expect(second_results.size).to eq(1)
      expect(Open3).to have_received(:popen3).once
      expect(shared_cache.fetch("claude")).to include(valid: true, source: :host_forwarded)
    end

    it "can bypass the per-account cache when a caller needs a fresh auth check" do
      runner
      first_expires_at = 4.hours.from_now
      second_expires_at = 5.hours.from_now
      stub_claude_auth_status(stdout: { expiresAt: first_expires_at.iso8601 }.to_json, success: true)

      cached_result = call_auth_health

      stub_claude_auth_status(stdout: { expiresAt: second_expires_at.iso8601 }.to_json, success: true)
      fresh_result = described_class.call(account: account, use_cache: false).fetch(0)

      expect(Open3).to have_received(:popen3).twice
      expect(cached_result.expires_at).to be_within(1.second).of(first_expires_at)
      expect(fresh_result.expires_at).to be_within(1.second).of(second_expires_at)
    end

    it "falls back to the native Claude credential file when the CLI is unavailable" do
      expires_at = 90.minutes.ago
      runner
      allow(Open3).to receive(:popen3)
        .with({}, "claude", "auth", "status", "--json", pgroup: true)
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

    it "does not trust the Claude credential file after a non-JSON CLI response" do
      expires_at = 90.minutes.from_now
      runner
      stub_claude_auth_status(stdout: "Authentication required", success: false, stderr: "")

      with_claude_credentials(
        {
          claudeAiOauth: {
            expiresAt: expires_at.iso8601
          }
        }
      ) do
        result = call_auth_health

        expect(result.valid).to be(false)
        expect(result.expires_at).to be_nil
        expect(result.source).to eq(:host_forwarded)
        expect(result.error).to eq("Authentication required")
      end
    end

    it "finds fallback Claude credentials in ~/.config/claude when the CLI is unavailable" do
      expires_at = 90.minutes.from_now
      runner
      allow(Open3).to receive(:popen3)
        .with({}, "claude", "auth", "status", "--json", pgroup: true)
        .and_raise(Errno::ENOENT)

      with_home_dir do |home|
        config_dir = File.join(home, ".config", "claude")
        write_claude_credentials(config_dir, { claudeAiOauth: { expiresAt: expires_at.iso8601 } })

        with_claude_config_dir_unset do
          result = call_auth_health

          expect(result.valid).to be(true)
          expect(result.expires_at).to be_within(1.second).of(expires_at)
          expect(result.source).to eq(:host_forwarded)
          expect(result.error).to be_nil
        end
      end
    end

    it "reports missing host-forwarded credentials when no fallback file exists" do
      runner
      allow(Open3).to receive(:popen3)
        .with({}, "claude", "auth", "status", "--json", pgroup: true)
        .and_raise(Errno::ENOENT)

      with_home_dir do
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

    it "marks host-forwarded auth invalid when the Claude CLI status check times out" do
      runner
      wait_thr = instance_double(Process::Waiter, pid: 12_345)
      allow(wait_thr).to receive(:value)
      allow(Kernel).to receive(:sleep)
      allow(Timeout).to receive(:timeout)
        .with(described_class::CLI_TIMEOUT_SECONDS)
        .and_raise(Timeout::Error)
      allow(Process).to receive(:getpgid).with(12_345).and_return(12_345)
      allow(Process).to receive(:kill)

      allow(Open3).to receive(:popen3)
        .with({}, "claude", "auth", "status", "--json", pgroup: true)
        .and_yield(Popen3Stub::FakeIO.new, Popen3Stub::FakeIO.new, Popen3Stub::FakeIO.new, wait_thr)

      result = call_auth_health

      expect(Process).to have_received(:kill).with("TERM", -12_345)
      expect(Process).to have_received(:kill).with("KILL", -12_345)
      expect(wait_thr).to have_received(:value).once
      expect(result.valid).to be(false)
      expect(result.expires_at).to be_nil
      expect(result.source).to eq(:host_forwarded)
      expect(result.error).to eq("Claude auth status check timed out")
    end

    it "marks host-forwarded auth invalid when spawning the Claude CLI fails" do
      runner
      allow(Open3).to receive(:popen3)
        .with({}, "claude", "auth", "status", "--json", pgroup: true)
        .and_raise(Errno::EACCES, "Permission denied")

      result = call_auth_health

      expect(result.valid).to be(false)
      expect(result.expires_at).to be_nil
      expect(result.source).to eq(:host_forwarded)
      expect(result.error).to eq("Claude auth status check failed: Permission denied - Permission denied")
    end
  end
end
