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

  shared_examples "managed native-file materialization" do |runner_key:, seed_method:, native_path:, token_value:|
    it "writes the minimal native config and records a managed materialization row" do
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
      host_dir = Dir.mktmpdir("gemini-host")
      begin
        File.write(File.join(host_dir, "oauth_creds.json"), "{}")
        svc = described_class.new(agent_run: agent_run, project: project, backend: local_backend)
        allow(svc).to receive_messages(
          gemini_managed_secret: nil,
          gemini_config_host_path: host_dir,
          gemini_local_config_path: nil,
          seed_host_credentials!: true,
          log_system: nil
        )

        svc.send(:seed_gemini_credentials!)

        attempt = RunnerAuthAttempt.where(attempt_stage: "materialization", runner_key: "gemini").last
        expect(attempt).not_to be_nil
        expect(attempt.auth_source).to eq("host_forwarded")
        expect(attempt.materialization_mode).to eq("host_mount")
        expect(attempt.result).to eq("materialized")
      ensure
        FileUtils.rm_rf(host_dir)
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
      host_dir = Dir.mktmpdir("copilot-host")
      begin
        File.write(File.join(host_dir, "config.json"), "{}")
        svc = described_class.new(agent_run: agent_run, project: project, backend: local_backend)
        allow(svc).to receive_messages(
          copilot_managed_secret: nil,
          copilot_config_host_path: host_dir,
          copilot_local_config_path: nil,
          seed_host_credentials!: true,
          log_system: nil
        )

        svc.send(:seed_copilot_credentials!)

        attempt = RunnerAuthAttempt.where(attempt_stage: "materialization", runner_key: "copilot").last
        expect(attempt).not_to be_nil
        expect(attempt.auth_source).to eq("host_forwarded")
        expect(attempt.materialization_mode).to eq("host_mount")
        expect(attempt.result).to eq("materialized")
      ensure
        FileUtils.rm_rf(host_dir)
      end
    end
  end

  describe "subscription_auth? predicate" do
    it "treats a managed Gemini credential as subscription auth even without host files" do
      create_managed_credential(runner_key: "gemini", token: gemini_payload)
      svc = described_class.new(agent_run: agent_run, project: project, backend: local_backend)
      allow(svc).to receive_messages(gemini_config_host_path: nil, gemini_local_config_path: nil)

      expect(svc.send(:gemini_subscription_auth?)).to be(true)
    end

    it "treats a managed Copilot credential as subscription auth even without host files" do
      create_managed_credential(runner_key: "copilot", token: copilot_payload)
      svc = described_class.new(agent_run: agent_run, project: project, backend: local_backend)
      allow(svc).to receive_messages(copilot_config_host_path: nil, copilot_local_config_path: nil)

      expect(svc.send(:copilot_subscription_auth?)).to be(true)
    end
  end
end
