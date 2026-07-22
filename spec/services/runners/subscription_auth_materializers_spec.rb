# frozen_string_literal: true

require "rails_helper"

RSpec.describe Runners::SubscriptionAuthMaterializers, :no_db do
  describe ".for_runner" do
    it "returns the Claude materializer marked remote-safe" do
      materializer = described_class.for_runner("claude")

      expect(materializer).not_to be_nil
      expect(materializer.remote_safe?).to be(true)
      expect(materializer.materialization_mode).to eq("env")
      expect(materializer.rotation_risk).to eq("server_refresh_only")
      expect(materializer.requires_host_paths?).to be(false)
    end

    it "marks Codex as host-mount and not remote-safe (pending #2962)" do
      materializer = described_class.for_runner("codex")

      expect(materializer.remote_safe?).to be(false)
      expect(materializer.materialization_mode).to eq("host_mount")
      expect(materializer.requires_host_paths?).to be(true)
    end

    it "marks Gemini and Copilot as remote-safe native-file materializers (#2964)" do
      %w[gemini copilot].each do |runner_key|
        materializer = described_class.for_runner(runner_key)

        expect(materializer.remote_safe?).to be(true)
        expect(materializer.materialization_mode).to eq("native_file")
        expect(materializer.rotation_risk).to eq("container_may_rotate")
        expect(materializer.requires_host_paths?).to be(false)
      end
    end

    it "returns nil for unknown runner keys" do
      expect(described_class.for_runner("unknown")).to be_nil
      expect(described_class.for_runner(nil)).to be_nil
    end
  end

  describe ".remote_safe?" do
    it "is true for Claude, Gemini, and Copilot today" do
      expect(described_class.remote_safe?("claude")).to be(true)
      expect(described_class.remote_safe?("codex")).to be(false)
      expect(described_class.remote_safe?("gemini")).to be(true)
      expect(described_class.remote_safe?("copilot")).to be(true)
    end

    it "coerces symbols" do
      expect(described_class.remote_safe?(:claude)).to be(true)
    end
  end

  describe ".registered_runner_keys" do
    it "includes all subscription providers" do
      expect(described_class.registered_runner_keys).to contain_exactly("claude", "codex", "gemini", "copilot")
    end
  end
end
