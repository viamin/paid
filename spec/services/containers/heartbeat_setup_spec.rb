# frozen_string_literal: true

require "rails_helper"

RSpec.describe Containers::HeartbeatSetup do
  let(:worktree_path) { "/var/paid/workspaces/abc/123" }
  let(:host_heartbeat_path) { "/tmp/paid-heartbeat-abc123/.paid-heartbeat" }

  describe "#heartbeat_path" do
    it "returns host_heartbeat_path when provided" do
      setup = described_class.new(provider: "claude", worktree_path: worktree_path, host_heartbeat_path: host_heartbeat_path)
      expect(setup.heartbeat_path).to eq(host_heartbeat_path)
    end

    it "returns nil when host_heartbeat_path is nil" do
      setup = described_class.new(provider: "claude", worktree_path: worktree_path, host_heartbeat_path: nil)
      expect(setup.heartbeat_path).to be_nil
    end
  end

  describe "#available?" do
    it "returns true for claude with host_heartbeat_path" do
      setup = described_class.new(provider: "claude", worktree_path: worktree_path, host_heartbeat_path: host_heartbeat_path)
      expect(setup).to be_available
    end

    it "returns true for claude_code with host_heartbeat_path" do
      setup = described_class.new(provider: "claude_code", worktree_path: worktree_path, host_heartbeat_path: host_heartbeat_path)
      expect(setup).to be_available
    end

    it "returns true for codex with host_heartbeat_path" do
      setup = described_class.new(provider: "codex", worktree_path: worktree_path, host_heartbeat_path: host_heartbeat_path)
      expect(setup).to be_available
    end

    it "returns false for unsupported provider" do
      setup = described_class.new(provider: "gemini", worktree_path: worktree_path, host_heartbeat_path: host_heartbeat_path)
      expect(setup).not_to be_available
    end

    it "returns false without host_heartbeat_path" do
      setup = described_class.new(provider: "claude", worktree_path: worktree_path, host_heartbeat_path: nil)
      expect(setup).not_to be_available
    end
  end

  describe "#env" do
    it "returns AGENT_HEARTBEAT_PATH for supported provider" do
      setup = described_class.new(provider: "claude", worktree_path: worktree_path, host_heartbeat_path: host_heartbeat_path)
      expect(setup.env).to eq("AGENT_HEARTBEAT_PATH" => "/paid-heartbeat/.paid-heartbeat")
    end

    it "returns empty hash for unsupported provider" do
      setup = described_class.new(provider: "gemini", worktree_path: worktree_path, host_heartbeat_path: host_heartbeat_path)
      expect(setup.env).to eq({})
    end

    it "returns empty hash without host_heartbeat_path" do
      setup = described_class.new(provider: "claude", worktree_path: worktree_path, host_heartbeat_path: nil)
      expect(setup.env).to eq({})
    end
  end

  describe "#preparation" do
    context "with claude provider" do
      let(:setup) { described_class.new(provider: "claude", worktree_path: worktree_path, host_heartbeat_path: host_heartbeat_path) }

      it "returns preparation with Claude settings file write" do
        preparation = setup.preparation
        expect(preparation).to be_a(AgentHarness::ExecutionPreparation)
        expect(preparation.file_writes.size).to eq(1)

        write = preparation.file_writes.first
        expect(write.path).to eq("/workspace/.claude/settings.json")

        settings = JSON.parse(write.content)
        hook = settings.dig("hooks", "PostToolUse", 0, "hooks", 0)
        expect(hook["type"]).to eq("command")
        expect(hook["command"]).to include("touch /paid-heartbeat/.paid-heartbeat")
      end

      context "with existing project settings" do
        let(:worktree_path) { Dir.mktmpdir("heartbeat-test") }

        after { FileUtils.rm_rf(worktree_path) }

        it "merges heartbeat hook into existing project settings" do
          existing_settings = {
            "permissions" => { "allow" => [ "Read", "Write" ] },
            "hooks" => {
              "PreToolUse" => [ { "matcher" => "Bash", "hooks" => [ { "type" => "command", "command" => "echo pre" } ] } ]
            }
          }

          settings_dir = File.join(worktree_path, ".claude")
          FileUtils.mkdir_p(settings_dir)
          File.write(File.join(settings_dir, "settings.json"), JSON.generate(existing_settings))

          setup = described_class.new(provider: "claude", worktree_path: worktree_path, host_heartbeat_path: host_heartbeat_path)
          preparation = setup.preparation
          settings = JSON.parse(preparation.file_writes.first.content)

          expect(settings["permissions"]).to eq("allow" => [ "Read", "Write" ])
          expect(settings.dig("hooks", "PreToolUse")).to eq(existing_settings["hooks"]["PreToolUse"])
          expect(settings.dig("hooks", "PostToolUse", 0, "hooks", 0, "command")).to include("touch /paid-heartbeat/.paid-heartbeat")
        end

        it "handles malformed existing settings gracefully" do
          settings_dir = File.join(worktree_path, ".claude")
          FileUtils.mkdir_p(settings_dir)
          File.write(File.join(settings_dir, "settings.json"), "not valid json")

          setup = described_class.new(provider: "claude", worktree_path: worktree_path, host_heartbeat_path: host_heartbeat_path)
          preparation = setup.preparation
          settings = JSON.parse(preparation.file_writes.first.content)
          expect(settings.dig("hooks", "PostToolUse")).to be_present
        end
      end
    end

    context "with claude_code provider" do
      let(:setup) { described_class.new(provider: "claude_code", worktree_path: worktree_path, host_heartbeat_path: host_heartbeat_path) }

      it "generates claude heartbeat config" do
        preparation = setup.preparation
        write = preparation.file_writes.first
        expect(write.path).to eq("/workspace/.claude/settings.json")
      end
    end

    context "with codex provider" do
      let(:setup) { described_class.new(provider: "codex", worktree_path: worktree_path, host_heartbeat_path: host_heartbeat_path) }

      it "returns nil because codex config is handled by Provision" do
        expect(setup.preparation).to be_nil
      end
    end

    context "with unsupported provider" do
      let(:setup) { described_class.new(provider: "gemini", worktree_path: worktree_path, host_heartbeat_path: host_heartbeat_path) }

      it "returns nil" do
        expect(setup.preparation).to be_nil
      end
    end

    context "without host_heartbeat_path" do
      let(:setup) { described_class.new(provider: "claude", worktree_path: worktree_path, host_heartbeat_path: nil) }

      it "returns nil" do
        expect(setup.preparation).to be_nil
      end
    end
  end

  describe "#reliable_heartbeat?" do
    it "returns true for claude" do
      setup = described_class.new(provider: "claude", worktree_path: worktree_path, host_heartbeat_path: host_heartbeat_path)
      expect(setup).to be_reliable_heartbeat
    end

    it "returns true for claude_code" do
      setup = described_class.new(provider: "claude_code", worktree_path: worktree_path, host_heartbeat_path: host_heartbeat_path)
      expect(setup).to be_reliable_heartbeat
    end

    it "returns false for codex" do
      setup = described_class.new(provider: "codex", worktree_path: worktree_path, host_heartbeat_path: host_heartbeat_path)
      expect(setup).not_to be_reliable_heartbeat
    end
  end

  describe "#idle_timeout_for" do
    let(:base_timeout) { 300 }

    it "returns nil for unsupported providers" do
      setup = described_class.new(provider: "gemini", worktree_path: worktree_path, host_heartbeat_path: host_heartbeat_path)
      expect(setup.idle_timeout_for(base_timeout)).to be_nil
    end

    it "returns nil without host_heartbeat_path" do
      setup = described_class.new(provider: "claude", worktree_path: worktree_path, host_heartbeat_path: nil)
      expect(setup.idle_timeout_for(base_timeout)).to be_nil
    end

    it "returns base timeout for reliable heartbeat providers" do
      setup = described_class.new(provider: "claude", worktree_path: worktree_path, host_heartbeat_path: host_heartbeat_path)
      expect(setup.idle_timeout_for(base_timeout)).to eq(300)
    end

    it "returns extended timeout for coarse heartbeat providers" do
      setup = described_class.new(provider: "codex", worktree_path: worktree_path, host_heartbeat_path: host_heartbeat_path)
      expected = base_timeout * described_class::COARSE_HEARTBEAT_IDLE_TIMEOUT_MULTIPLIER
      expect(setup.idle_timeout_for(base_timeout)).to eq(expected)
    end

    it "returns nil for coarse heartbeat provider with nil base timeout" do
      setup = described_class.new(provider: "codex", worktree_path: worktree_path, host_heartbeat_path: host_heartbeat_path)
      expect(setup.idle_timeout_for(nil)).to be_nil
    end
  end
end
