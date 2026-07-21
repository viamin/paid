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
      supports_host_paths?: true,
      exec_in_container: [ [], [], 0 ]
    )
  end

  let(:claude_config_dir) { Dir.mktmpdir("claude-host") }
  let(:config_dirs) do
    {
      gemini: Dir.mktmpdir("gemini-host"),
      copilot: Dir.mktmpdir("copilot-host"),
      codex: Dir.mktmpdir("codex-host")
    }
  end

  let(:account) { create(:account) }
  let(:project) do
    create(:project,
      account: account,
      created_by: create(:user, account: account))
  end

  after do
    FileUtils.rm_rf(claude_config_dir) if claude_config_dir && Dir.exist?(claude_config_dir)
    config_dirs.each_value do |dir|
      FileUtils.rm_rf(dir) if Dir.exist?(dir)
    end
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

    it "records one eligibility row per detected host auth source" do
      File.write(File.join(gemini_config_dir, "oauth_creds.json"), "{}")
      File.write(File.join(copilot_config_dir, "config.json"), "{}")

      svc = described_class.new(agent_run: nil, project: project, backend: remote_backend)
      allow(svc).to receive_messages(
        claude_local_config_path: nil,
        codex_local_config_path: nil,
        gemini_local_config_path: nil,
        copilot_local_config_path: nil,
        codex_subscription_auth_host_mount_path: codex_config_dir,
        gemini_config_host_path: gemini_config_dir,
        copilot_config_host_path: copilot_config_dir
      )

      expect {
        svc.send(:validate_backend_mount_support!)
      }.to raise_error(Containers::Provision::ProvisionError)

      attempts = RunnerAuthAttempt.where(attempt_stage: "eligibility").order(:runner_key)
      expect(attempts.pluck(:runner_key)).to eq(%w[claude codex copilot gemini])
      expect(attempts.pluck(:auth_source).uniq).to eq([ "host_forwarded" ])
      expect(attempts.pluck(:result).uniq).to eq([ "failed" ])
      expect_host_forwarded_attempt(attempts.find { |attempt| attempt.runner_key == "codex" })
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

  describe "Codex harvest telemetry" do
    let(:agent_run) { create(:agent_run, project: project) }
    let(:service) { described_class.new(agent_run: agent_run, project: project, backend: local_backend) }

    before do
      allow(service).to receive_messages(
        codex_subscription_auth_source_path: codex_config_dir,
        container: container,
        log_system: nil
      )
    end

    it "records a skipped harvest when the container returns no rotated credential" do
      allow(local_backend).to receive(:exec_in_container).and_return([ [], [], 0 ])

      service.send(:sync_codex_auth_file_to_source!)

      attempt = RunnerAuthAttempt.where(attempt_stage: "harvest", runner_key: "codex").last
      expect(attempt.result).to eq("skipped")
      expect(attempt.failure_reason).to eq("no_rotated_credential")
    end

    it "records a harvested result when the rotated credential is returned" do
      encoded = Base64.strict_encode64('{"user":"paid"}')
      allow(local_backend).to receive(:exec_in_container).and_return([ [ encoded ], [], 0 ])

      service.send(:sync_codex_auth_file_to_source!)

      attempt = RunnerAuthAttempt.where(attempt_stage: "harvest", runner_key: "codex").last
      expect(attempt.result).to eq("harvested")
      expect(attempt.failure_reason).to be_nil
      expect(File.read(File.join(codex_config_dir, "auth.json"))).to eq('{"user":"paid"}')
    end

    it "records a harvest failure when the container exec fails" do
      allow(local_backend).to receive(:exec_in_container).and_return([ [], [ "boom" ], 1 ])

      service.send(:sync_codex_auth_file_to_source!)

      attempt = RunnerAuthAttempt.where(attempt_stage: "harvest", runner_key: "codex").last
      expect(attempt.result).to eq("harvest_failed")
      expect(attempt.failure_reason).to eq("exec_failed")
    end
  end

  describe "Claude lease telemetry" do
    let(:agent_run) { create(:agent_run, project: project) }
    let(:service) { described_class.new(agent_run: agent_run, project: project, backend: local_backend) }

    it "records an acquired lease result" do
      service.send(:record_claude_lease_attempt!,
        state: RunnerAuthAttempt::LEASE_ACQUIRED,
        started_at: Process.clock_gettime(Process::CLOCK_MONOTONIC) - 0.05,
        metadata: { source: "host_mount" })

      attempt = RunnerAuthAttempt.where(attempt_stage: "lease", runner_key: "claude").last
      expect(attempt.lease_state).to eq("acquired")
      expect(attempt.result).to eq("lease_acquired")
    end

    it "records a timeout lease result" do
      service.send(:record_claude_lease_attempt!,
        state: RunnerAuthAttempt::LEASE_TIMEOUT,
        started_at: Process.clock_gettime(Process::CLOCK_MONOTONIC) - 0.05,
        metadata: { source: "host_mount" })

      attempt = RunnerAuthAttempt.where(attempt_stage: "lease", runner_key: "claude").last
      expect(attempt.lease_state).to eq("timeout")
      expect(attempt.result).to eq("lease_timeout")
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

  def expect_host_forwarded_attempt(attempt)
    expect(attempt.materialization_mode).to eq("host_mount")
    expect(attempt.container_host).to eq("elguapo")
  end

  def gemini_config_dir
    config_dirs.fetch(:gemini)
  end

  def copilot_config_dir
    config_dirs.fetch(:copilot)
  end

  def codex_config_dir
    config_dirs.fetch(:codex)
  end

  def container
    @container ||= instance_double(Docker::Container)
  end
end
