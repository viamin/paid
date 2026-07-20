# frozen_string_literal: true

require "rails_helper"
require "tmpdir"

RSpec.describe Containers::Provision do
  let(:remote_backend) do
    instance_double(
      Containers::Backends::RemoteDocker,
      identifier: "elguapo",
      remote?: true,
      supports_host_paths?: false
    )
  end

  let(:local_backend) do
    instance_double(
      Containers::Backends::Base,
      identifier: "local",
      remote?: false,
      supports_host_paths?: true
    )
  end

  let(:claude_config_dir) { Dir.mktmpdir("claude-host") }

  let(:account) { create(:account) }
  let(:project) do
    create(:project,
      account: account,
      created_by: create(:user, account: account))
  end

  after do
    FileUtils.rm_rf(claude_config_dir) if claude_config_dir && Dir.exist?(claude_config_dir)
  end

  def stub_env_for_auth(auth_dir:)
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("CLAUDE_CONFIG_DIR").and_return(auth_dir)
    allow(ENV).to receive(:[]).with("CODEX_CONFIG_DIR").and_return(nil)
    allow(ENV).to receive(:[]).with("CODEX_HOME").and_return(nil)
    allow(ENV).to receive(:[]).with("GEMINI_CONFIG_DIR").and_return(nil)
    allow(ENV).to receive(:[]).with("COPILOT_HOME").and_return(nil)
    allow(ENV).to receive(:[]).with("COPILOT_CONFIG_DIR").and_return(nil)
    allow(ENV).to receive(:[]).with("PAID_PROXY_EXTERNAL_URL").and_return("http://paid.example:3000")
  end

  def stub_no_local_or_other_paths(svc)
    allow(svc).to receive_messages(
      claude_local_config_path: nil,
      codex_local_config_path: nil,
      gemini_local_config_path: nil,
      copilot_local_config_path: nil,
      codex_subscription_auth_host_mount_path: nil,
      gemini_config_host_path: nil,
      copilot_config_host_path: nil
    )
  end

  def create_remote_safe_claude_credential
    create(
      :runner_credential,
      account: project.account,
      created_by: project.created_by,
      runner_key: "claude",
      auth_kind: "oauth_token",
      token: JSON.generate(
        "claudeAiOauth" => {
          "accessToken" => "managed-access",
          "refreshToken" => "managed-refresh",
          "expiresAt" => 12.hours.from_now.iso8601
        }
      )
    )
  end

  describe "validate_backend_mount_support! telemetry" do
    before do
      File.write(File.join(claude_config_dir, ".credentials.json"), "{}")
      stub_env_for_auth(auth_dir: claude_config_dir)
    end

    it "records a managed eligibility attempt when a remote-safe RunnerCredential exists" do
      create_remote_safe_claude_credential
      svc = described_class.new(agent_run: nil, project: project, backend: remote_backend)
      stub_no_local_or_other_paths(svc)

      expect { svc.send(:validate_backend_mount_support!) }.not_to raise_error

      attempt = RunnerAuthAttempt.where(runner_key: "claude").last
      expect(attempt).not_to be_nil
      expect(attempt.attempt_stage).to eq("eligibility")
      expect(attempt.auth_source).to eq("managed")
      expect(attempt.materialization_mode).to eq("env")
      expect(attempt.container_host).to eq("elguapo")
      expect(attempt.result).to eq("materialized")
      expect(attempt.account).to eq(account)
      expect(attempt.project).to eq(project)
    end

    it "records a host_forwarded eligibility attempt that ends in a named rejection" do
      svc = described_class.new(agent_run: nil, project: project, backend: remote_backend)
      stub_no_local_or_other_paths(svc)

      expect {
        svc.send(:validate_backend_mount_support!)
      }.to raise_error(Containers::Provision::ProvisionError, /requires_host_bind_mount/)

      attempt = RunnerAuthAttempt.where(runner_key: "claude").last
      expect(attempt).not_to be_nil
      expect(attempt.attempt_stage).to eq("eligibility")
      expect(attempt.auth_source).to eq("host_forwarded")
      expect(attempt.materialization_mode).to eq("host_mount")
      expect(attempt.container_host).to eq("elguapo")
      expect(attempt.backend_supports_host_paths).to be(false)
      expect(attempt.backend_remote).to be(true)
      expect(attempt.result).to eq("failed")
      expect(attempt.failure_reason).to eq("requires_host_bind_mount")
    end
  end

  describe "managed Claude materialization telemetry" do
    let(:agent_run) { create(:agent_run, project: project) }

    before do
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("CLAUDE_CONFIG_DIR").and_return(nil)
      allow(ENV).to receive(:[]).with("CODEX_CONFIG_DIR").and_return(nil)
      allow(ENV).to receive(:[]).with("CODEX_HOME").and_return(nil)
      allow(ENV).to receive(:[]).with("GEMINI_CONFIG_DIR").and_return(nil)
      allow(ENV).to receive(:[]).with("COPILOT_HOME").and_return(nil)
      allow(ENV).to receive(:[]).with("COPILOT_CONFIG_DIR").and_return(nil)
    end

    it "records a managed env-token materialization attempt with no secrets in the row" do
      credential = create_remote_safe_claude_credential
      svc = described_class.new(agent_run: agent_run, project: project, backend: local_backend)
      allow(svc).to receive(:write_container_file)
      allow(svc).to receive(:log_system)

      svc.send(:seed_claude_credentials!)

      attempt = RunnerAuthAttempt.where(attempt_stage: "materialization", runner_key: "claude").last
      expect_attempt_to_be_secret_free(attempt, credential)
    end
  end

  def expect_attempt_to_be_secret_free(attempt, credential)
    expect(attempt).not_to be_nil
    expect(attempt.auth_source).to eq("managed")
    expect(attempt.materialization_mode).to be_in(%w[env native_file])
    expect(attempt.runner_credential).to eq(credential)
    expect(attempt.result).to eq("materialized")

    serialized = attempt.attributes.values.compact.map(&:to_s).join("\n")
    expect(serialized).not_to include("managed-access")
    expect(serialized).not_to include("managed-refresh")
    expect(serialized).not_to match(/Bearer\s+/)

    serialized_metadata = attempt.metadata.to_s
    expect(serialized_metadata).not_to include("managed-access")
    expect(serialized_metadata).not_to include("managed-refresh")
  end
end
