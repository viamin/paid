# frozen_string_literal: true

require "rails_helper"
require "json"
require "tmpdir"

RSpec.describe Containers::Provision do
  let(:local_backend) do
    instance_double(
      Containers::Backends::Base,
      identifier: "local",
      remote?: false,
      supports_host_paths?: true
    )
  end

  let(:account) { create(:account) }
  let(:project) do
    create(:project,
      account: account,
      created_by: create(:user, account: account))
  end
  let(:agent_run) { create(:agent_run, project: project) }

  let(:gemini_payload) do
    JSON.generate(
      "access_token" => "ya29.managed-gemini-access",
      "refresh_token" => "1//managed-gemini-refresh",
      "scope" => "https://www.googleapis.com/auth/cloud-platform",
      "token_type" => "Bearer",
      "expiry_date" => 4102444800000
    )
  end

  let(:copilot_payload) do
    JSON.generate(
      "oauth_token" => "tid=managed-copilot-oauth;exp=4102444800",
      "refresh_token" => "managed-copilot-refresh",
      "expires_at" => "2100-01-01T00:00:00Z"
    )
  end

  def create_managed_credential(runner_key:, token:)
    create(
      :runner_credential,
      account: project.account,
      created_by: project.created_by,
      runner_key: runner_key,
      auth_kind: "oauth_token",
      token: token
    )
  end

  def stub_managed_subscription_runner_auth(enabled)
    allow(FeatureFlags).to receive(:enabled?)
      .with(:managed_subscription_runner_auth, project: project)
      .and_return(enabled)
  end

  def with_temp_config_dir(prefix:, file_name:)
    dir = Dir.mktmpdir(prefix)
    File.write(File.join(dir, file_name), "{}")
    yield dir
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  def expect_host_forwarded_materialization(svc:, seed_method:, runner_key:)
    allow(svc).to receive(:write_container_file)

    svc.send(seed_method)

    expect(svc).not_to have_received(:write_container_file)
    attempt = RunnerAuthAttempt.where(attempt_stage: "materialization", runner_key: runner_key).last
    expect(attempt).not_to be_nil
    expect(attempt.auth_source).to eq("host_forwarded")
    expect(attempt.materialization_mode).to eq("host_mount")
    expect(attempt.result).to eq("materialized")
  end

  shared_examples "managed native-file materialization" do |runner_key:, seed_method:, native_path:, token_value:|
    it "writes the minimal native config and records a managed materialization row" do
      stub_managed_subscription_runner_auth(true)
      credential = create_managed_credential(runner_key: runner_key, token: send("#{runner_key}_payload"))

      svc = described_class.new(agent_run: agent_run, project: project, backend: local_backend)
      written = []
      allow(svc).to receive(:write_container_file) { |path, content| written << [ path, content ] }
      allow(svc).to receive(:log_system)

      svc.send(seed_method)

      expect(written).to include([ native_path, anything ])
      _, content = written.find { |path, _| path == native_path }
      expect(content).to include(token_value)

      attempt = RunnerAuthAttempt.where(attempt_stage: "materialization", runner_key: runner_key).last
      expect(attempt).not_to be_nil
      expect(attempt.auth_source).to eq("managed")
      expect(attempt.materialization_mode).to eq("native_file")
      expect(attempt.runner_credential).to eq(credential)
      expect(attempt.result).to eq("materialized")
    end

    it "records no secrets in the materialization telemetry row" do
      stub_managed_subscription_runner_auth(true)
      create_managed_credential(runner_key: runner_key, token: send("#{runner_key}_payload"))

      svc = described_class.new(agent_run: agent_run, project: project, backend: local_backend)
      allow(svc).to receive(:write_container_file)
      allow(svc).to receive(:log_system)

      svc.send(seed_method)

      attempt = RunnerAuthAttempt.where(attempt_stage: "materialization", runner_key: runner_key).last
      serialized = attempt.attributes.values.compact.map(&:to_s).join("\n")

      expect(serialized).not_to include(token_value)
      expect(attempt.metadata.to_s).not_to include(token_value)
    end
  end

  describe "managed Gemini materialization" do
    it_behaves_like "managed native-file materialization",
      runner_key: "gemini",
      seed_method: :seed_gemini_credentials!,
      native_path: "/home/agent/.gemini/oauth_creds.json",
      token_value: "ya29.managed-gemini-access"

    it "falls back to host_forwarded telemetry when no managed credential exists" do
      stub_managed_subscription_runner_auth(true)
      with_temp_config_dir(prefix: "gemini-host", file_name: "oauth_creds.json") do |host_dir|
        svc = described_class.new(agent_run: agent_run, project: project, backend: local_backend)
        allow(svc).to receive_messages(
          gemini_managed_secret: nil,
          gemini_config_host_path: host_dir,
          gemini_local_config_path: nil,
          seed_host_credentials!: true,
          log_system: nil
        )

        expect_host_forwarded_materialization(
          svc: svc,
          seed_method: :seed_gemini_credentials!,
          runner_key: "gemini"
        )
      end
    end

    it "keeps the legacy host-forwarded path when the rollout flag is disabled" do
      stub_managed_subscription_runner_auth(false)
      create_managed_credential(runner_key: "gemini", token: gemini_payload)
      with_temp_config_dir(prefix: "gemini-host", file_name: "oauth_creds.json") do |host_dir|
        svc = described_class.new(agent_run: agent_run, project: project, backend: local_backend)
        allow(svc).to receive_messages(
          gemini_config_host_path: host_dir,
          gemini_local_config_path: nil,
          seed_host_credentials!: true,
          log_system: nil
        )

        expect_host_forwarded_materialization(
          svc: svc,
          seed_method: :seed_gemini_credentials!,
          runner_key: "gemini"
        )
      end
    end
  end

  describe "managed Copilot materialization" do
    it_behaves_like "managed native-file materialization",
      runner_key: "copilot",
      seed_method: :seed_copilot_credentials!,
      native_path: "/home/agent/.copilot/config.json",
      token_value: "tid=managed-copilot-oauth"

    it "falls back to host_forwarded telemetry when no managed credential exists" do
      stub_managed_subscription_runner_auth(true)
      with_temp_config_dir(prefix: "copilot-host", file_name: "config.json") do |host_dir|
        svc = described_class.new(agent_run: agent_run, project: project, backend: local_backend)
        allow(svc).to receive_messages(
          copilot_managed_secret: nil,
          copilot_config_host_path: host_dir,
          copilot_local_config_path: nil,
          seed_host_credentials!: true,
          log_system: nil
        )

        expect_host_forwarded_materialization(
          svc: svc,
          seed_method: :seed_copilot_credentials!,
          runner_key: "copilot"
        )
      end
    end

    it "keeps the legacy host-forwarded path when the rollout flag is disabled" do
      stub_managed_subscription_runner_auth(false)
      create_managed_credential(runner_key: "copilot", token: copilot_payload)
      with_temp_config_dir(prefix: "copilot-host", file_name: "config.json") do |host_dir|
        svc = described_class.new(agent_run: agent_run, project: project, backend: local_backend)
        allow(svc).to receive_messages(
          copilot_config_host_path: host_dir,
          copilot_local_config_path: nil,
          seed_host_credentials!: true,
          log_system: nil
        )

        expect_host_forwarded_materialization(
          svc: svc,
          seed_method: :seed_copilot_credentials!,
          runner_key: "copilot"
        )
      end
    end
  end

  describe "subscription_auth? predicate" do
    it "treats a managed Gemini credential as subscription auth even without host files" do
      stub_managed_subscription_runner_auth(true)
      create_managed_credential(runner_key: "gemini", token: gemini_payload)
      svc = described_class.new(agent_run: agent_run, project: project, backend: local_backend)
      allow(svc).to receive_messages(gemini_config_host_path: nil, gemini_local_config_path: nil)

      expect(svc.send(:gemini_subscription_auth?)).to be(true)
    end

    it "treats a managed Copilot credential as subscription auth even without host files" do
      stub_managed_subscription_runner_auth(true)
      create_managed_credential(runner_key: "copilot", token: copilot_payload)
      svc = described_class.new(agent_run: agent_run, project: project, backend: local_backend)
      allow(svc).to receive_messages(copilot_config_host_path: nil, copilot_local_config_path: nil)

      expect(svc.send(:copilot_subscription_auth?)).to be(true)
    end

    it "does not treat a managed Gemini credential as subscription auth while the rollout flag is disabled" do
      stub_managed_subscription_runner_auth(false)
      create_managed_credential(runner_key: "gemini", token: gemini_payload)
      svc = described_class.new(agent_run: agent_run, project: project, backend: local_backend)
      allow(svc).to receive_messages(gemini_config_host_path: nil, gemini_local_config_path: nil)

      expect(svc.send(:gemini_subscription_auth?)).to be(false)
    end

    it "does not treat a managed Copilot credential as subscription auth while the rollout flag is disabled" do
      stub_managed_subscription_runner_auth(false)
      create_managed_credential(runner_key: "copilot", token: copilot_payload)
      svc = described_class.new(agent_run: agent_run, project: project, backend: local_backend)
      allow(svc).to receive_messages(copilot_config_host_path: nil, copilot_local_config_path: nil)

      expect(svc.send(:copilot_subscription_auth?)).to be(false)
    end
  end

  describe "managed remote-safe gating" do
    before do
      stub_managed_subscription_runner_auth(flag_enabled)
    end

    context "when the rollout flag is disabled" do
      let(:flag_enabled) { false }

      it "does not treat Gemini and Copilot managed credentials as remote-safe" do
        create_managed_credential(runner_key: "gemini", token: gemini_payload)
        create_managed_credential(runner_key: "copilot", token: copilot_payload)
        svc = described_class.new(agent_run: agent_run, project: project, backend: local_backend)

        expect(svc.send(:managed_remote_safe_for?, "gemini")).to be(false)
        expect(svc.send(:managed_remote_safe_for?, "copilot")).to be(false)
      end
    end

    context "when the rollout flag is enabled" do
      let(:flag_enabled) { true }

      it "rejects malformed Gemini and Copilot managed payloads as remote-safe" do
        create_managed_credential(runner_key: "gemini", token: "{\"unexpected\":true}")
        create_managed_credential(runner_key: "copilot", token: "{\"unexpected\":true}")
        svc = described_class.new(agent_run: agent_run, project: project, backend: local_backend)

        expect(svc.send(:managed_remote_safe_for?, "gemini")).to be(false)
        expect(svc.send(:managed_remote_safe_for?, "copilot")).to be(false)
      end
    end
  end

  describe "eligibility telemetry auth source" do
    before do
      stub_managed_subscription_runner_auth(flag_enabled)
    end

    let(:flag_enabled) { true }

    it "keeps Gemini host-forwarded when the managed payload is malformed" do
      create_managed_credential(runner_key: "gemini", token: "{\"unexpected\":true}")
      svc = described_class.new(agent_run: agent_run, project: project, backend: local_backend)
      allow(svc).to receive(:subscription_auth_host_sources).and_return([ { runner_key: "gemini", host_path: "/host/.gemini", detected: true } ])

      svc.send(:record_eligibility_attempts!)

      attempt = RunnerAuthAttempt.where(attempt_stage: "eligibility", runner_key: "gemini").last
      expect(attempt).not_to be_nil
      expect(attempt.auth_source).to eq("host_forwarded")
      expect(attempt.materialization_mode).to eq("host_mount")
    end

    it "keeps Copilot host-forwarded while the rollout flag is disabled" do
      create_managed_credential(runner_key: "copilot", token: copilot_payload)
      stub_managed_subscription_runner_auth(false)
      svc = described_class.new(agent_run: agent_run, project: project, backend: local_backend)
      allow(svc).to receive(:subscription_auth_host_sources).and_return([ { runner_key: "copilot", host_path: "/host/.copilot", detected: true } ])

      svc.send(:record_eligibility_attempts!)

      attempt = RunnerAuthAttempt.where(attempt_stage: "eligibility", runner_key: "copilot").last
      expect(attempt).not_to be_nil
      expect(attempt.auth_source).to eq("host_forwarded")
      expect(attempt.materialization_mode).to eq("host_mount")
    end
  end
end
