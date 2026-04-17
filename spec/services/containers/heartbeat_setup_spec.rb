# frozen_string_literal: true

require "rails_helper"

RSpec.describe Containers::HeartbeatSetup do
  let(:worktree_path) { "/var/paid/workspaces/abc/123" }

  describe "#heartbeat_path" do
    it "returns host-side path for bind-mounted workspace" do
      setup = described_class.new(provider: "claude", worktree_path: worktree_path)
      expect(setup.heartbeat_path).to eq("/var/paid/workspaces/abc/123/.paid-heartbeat")
    end

    it "returns nil when worktree_path is nil" do
      setup = described_class.new(provider: "claude", worktree_path: nil)
      expect(setup.heartbeat_path).to be_nil
    end

    it "returns nil when worktree_path is blank" do
      setup = described_class.new(provider: "claude", worktree_path: "")
      expect(setup.heartbeat_path).to be_nil
    end
  end

  describe "#available?" do
    it "returns true for claude with worktree" do
      setup = described_class.new(provider: "claude", worktree_path: worktree_path)
      expect(setup).to be_available
    end

    it "returns true for claude_code with worktree" do
      setup = described_class.new(provider: "claude_code", worktree_path: worktree_path)
      expect(setup).to be_available
    end

    it "returns true for codex with worktree" do
      setup = described_class.new(provider: "codex", worktree_path: worktree_path)
      expect(setup).to be_available
    end

    it "returns false for unsupported provider" do
      setup = described_class.new(provider: "gemini", worktree_path: worktree_path)
      expect(setup).not_to be_available
    end

    it "returns false without worktree_path" do
      setup = described_class.new(provider: "claude", worktree_path: nil)
      expect(setup).not_to be_available
    end
  end

  describe "#env" do
    it "returns AGENT_HEARTBEAT_PATH for supported provider" do
      setup = described_class.new(provider: "claude", worktree_path: worktree_path)
      expect(setup.env).to eq("AGENT_HEARTBEAT_PATH" => "/workspace/.paid-heartbeat")
    end

    it "returns empty hash for unsupported provider" do
      setup = described_class.new(provider: "gemini", worktree_path: worktree_path)
      expect(setup.env).to eq({})
    end

    it "returns empty hash without worktree_path" do
      setup = described_class.new(provider: "claude", worktree_path: nil)
      expect(setup.env).to eq({})
    end
  end

  describe "#preparation" do
    context "with claude provider" do
      let(:setup) { described_class.new(provider: "claude", worktree_path: worktree_path) }

      it "returns preparation with Claude settings file write" do
        preparation = setup.preparation
        expect(preparation).to be_a(AgentHarness::ExecutionPreparation)
        expect(preparation.file_writes.size).to eq(1)

        write = preparation.file_writes.first
        expect(write.path).to eq("/workspace/.claude/settings.json")

        settings = JSON.parse(write.content)
        hook = settings.dig("hooks", "PostToolUse", 0, "hooks", 0)
        expect(hook["type"]).to eq("command")
        expect(hook["command"]).to include("touch /workspace/.paid-heartbeat")
      end
    end

    context "with claude_code provider" do
      let(:setup) { described_class.new(provider: "claude_code", worktree_path: worktree_path) }

      it "generates claude heartbeat config" do
        preparation = setup.preparation
        write = preparation.file_writes.first
        expect(write.path).to eq("/workspace/.claude/settings.json")
      end
    end

    context "with codex provider" do
      let(:setup) { described_class.new(provider: "codex", worktree_path: worktree_path) }

      it "returns preparation with Codex config file write" do
        preparation = setup.preparation
        expect(preparation).to be_a(AgentHarness::ExecutionPreparation)
        expect(preparation.file_writes.size).to eq(1)

        write = preparation.file_writes.first
        expect(write.path).to eq("~/.codex/config.toml")
        expect(write.content).to include("notify")
        expect(write.content).to include("/workspace/.paid-heartbeat")
      end
    end

    context "with unsupported provider" do
      let(:setup) { described_class.new(provider: "gemini", worktree_path: worktree_path) }

      it "returns nil" do
        expect(setup.preparation).to be_nil
      end
    end

    context "without worktree_path" do
      let(:setup) { described_class.new(provider: "claude", worktree_path: nil) }

      it "returns nil" do
        expect(setup.preparation).to be_nil
      end
    end
  end
end
