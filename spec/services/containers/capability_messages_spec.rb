# frozen_string_literal: true

require "rails_helper"

RSpec.describe Containers::CapabilityMessages do
  describe ".unavailable_for" do
    it "returns the failed-container message" do
      expect(described_class.unavailable_for("failed")).to eq(
        "Workspace tools are unavailable because the workspace container failed to prepare."
      )
    end

    it "returns the stopped-container message" do
      expect(described_class.unavailable_for("stopped")).to eq(
        "Workspace tools are unavailable because the workspace container is stopped."
      )
    end

    it "returns the preparing message for pending capabilities" do
      expect(described_class.unavailable_for("pending")).to eq(
        "Workspace tools are still preparing. Retry shortly or fall back to inline tools."
      )
    end
  end

  describe ".notice_for" do
    it "returns the failed-container notice" do
      expect(described_class.notice_for("failed")).to eq(
        "Workspace tools are currently unavailable because the workspace container failed to prepare. Use inline tools until the workspace is restored."
      )
    end

    it "returns the stopped-container notice" do
      expect(described_class.notice_for("stopped")).to eq(
        "Workspace tools are currently unavailable because the workspace container is stopped. Use inline tools until the workspace is started again."
      )
    end

    it "returns nil for non-degraded capabilities" do
      expect(described_class.notice_for("ready")).to be_nil
    end
  end
end
