# frozen_string_literal: true

require "rails_helper"

RSpec.describe Containers::Provision, :no_db do
  let(:project) { double(id: 42) }
  let(:backend) { instance_double(Containers::Backends::Base) }
  let(:worktree_path) { Dir.mktmpdir("worktree") }
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
    allow(backend).to receive(:supports_host_paths?).and_return(false)
  end

  after do
    FileUtils.rm_rf(worktree_path) if Dir.exist?(worktree_path)
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
end
