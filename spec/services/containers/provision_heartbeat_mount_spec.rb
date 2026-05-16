# frozen_string_literal: true

require "rails_helper"

RSpec.describe Containers::Provision, :no_db do
  def build_remote_service(project:, backend:, host_config_dir:)
    service = described_class.new(project:, backend:)
    allow(service).to receive_messages(
      claude_config_host_path: host_config_dir,
      codex_subscription_auth_host_mount_path: host_config_dir,
      gemini_config_host_path: host_config_dir,
      gemini_subscription_auth?: true,
      copilot_config_host_path: host_config_dir,
      copilot_subscription_auth?: true,
      claude_local_config_path: nil,
      gemini_local_config_path: nil,
      copilot_local_config_path: nil,
      container_network: "paid_agent"
    )
    service
  end

  let(:project) { double(id: 42) }
  let(:backend) { instance_double(Containers::Backends::Base) }
  let(:worktree_path) { Dir.mktmpdir("worktree") }
  let(:host_config_dir) { Dir.mktmpdir("host-config") }
  let(:settings) do
    double(
      container_memory_bytes: nil,
      container_cpu_quota: nil,
      container_timeout_seconds: nil,
      container_image: nil
    )
  end

  before do
    allow(AgentRuns::UserSettingsResolver).to receive(:call).with(project:, strict: false).and_return(settings)
    allow(backend).to receive_messages(supports_host_paths?: false, identifier: "swarm")
  end

  after do
    FileUtils.rm_rf(worktree_path) if Dir.exist?(worktree_path)
    FileUtils.rm_rf(host_config_dir) if Dir.exist?(host_config_dir)
  end

  it "uses tmpfs for /paid-heartbeat when the backend cannot mount host paths" do
    service = described_class.new(project:, worktree_path:, backend:)
    allow(service).to receive_messages(
      claude_config_host_path: nil,
      codex_subscription_auth_host_mount_path: nil,
      gemini_config_host_path: nil,
      gemini_subscription_auth?: false,
      copilot_config_host_path: nil,
      copilot_subscription_auth?: false,
      container_network: "paid_agent"
    )

    host_config = service.send(:host_config)

    expect(host_config.fetch("Tmpfs")).to include(
      described_class::HEARTBEAT_MOUNT_POINT => "size=1048576,mode=0777"
    )
    expect(host_config.fetch("Binds").grep(/#{Regexp.escape(described_class::HEARTBEAT_MOUNT_POINT)}/)).to be_empty
  end

  it "rejects host-backed worktrees when the backend cannot mount host paths" do
    service = described_class.new(project:, worktree_path:, backend:)

    expect { service.send(:prepare_workspace!) }
      .to raise_error(Containers::Provision::ProvisionError, /does not support host-backed worktree paths/)
  end

  it "rejects host-only credential sources when the backend cannot mount host paths" do
    File.write(File.join(host_config_dir, ".credentials.json"), "{}")
    File.write(File.join(host_config_dir, "auth.json"), "{}")
    File.write(File.join(host_config_dir, "oauth_creds.json"), "{}")
    File.write(File.join(host_config_dir, "config.json"), "{}")

    service = described_class.new(project:, backend:)
    allow(service).to receive_messages(
      claude_config_host_path: host_config_dir,
      claude_local_config_path: nil,
      codex_subscription_auth_host_mount_path: host_config_dir,
      gemini_config_host_path: host_config_dir,
      gemini_local_config_path: nil,
      copilot_config_host_path: host_config_dir,
      copilot_local_config_path: nil
    )

    message_pattern = /Claude subscription auth.*Codex subscription auth.*Gemini subscription auth.*Copilot subscription auth/

    expect { service.send(:validate_backend_mount_support!) }
      .to raise_error(Containers::Provision::ProvisionError, message_pattern)
  end

  it "does not emit host credential binds when the backend cannot mount host paths" do
    File.write(File.join(host_config_dir, ".credentials.json"), "{}")
    File.write(File.join(host_config_dir, "oauth_creds.json"), "{}")
    File.write(File.join(host_config_dir, "config.json"), "{}")

    service = build_remote_service(project:, backend:, host_config_dir:)

    host_config = service.send(:host_config)
    binds = host_config.fetch("Binds").join("\n")
    expect(binds).not_to include("/home/agent/.claude-host")
    expect(binds).not_to include("/home/agent/.codex/auth.json")
    expect(binds).not_to include("/home/agent/.gemini-host")
    expect(binds).not_to include("/home/agent/.copilot-host")
  end
end
