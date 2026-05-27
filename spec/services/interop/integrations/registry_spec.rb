# frozen_string_literal: true

require "rails_helper"

RSpec.describe Interop::Integrations::Registry do
  describe ".all" do
    it "returns all integration pattern classes" do
      classes = described_class.all
      expect(classes).to include(
        Interop::Integrations::GithubCopilot,
        Interop::Integrations::Cursor,
        Interop::Integrations::Devin,
        Interop::Integrations::Factory,
        Interop::Integrations::InternalAgentWorkflows
      )
    end
  end

  describe ".find" do
    it "returns the integration class for a known key" do
      expect(described_class.find("github_copilot")).to eq(Interop::Integrations::GithubCopilot)
      expect(described_class.find("cursor")).to eq(Interop::Integrations::Cursor)
      expect(described_class.find("devin")).to eq(Interop::Integrations::Devin)
      expect(described_class.find("factory")).to eq(Interop::Integrations::Factory)
      expect(described_class.find("internal_agent_workflows")).to eq(Interop::Integrations::InternalAgentWorkflows)
    end

    it "returns nil for unknown keys" do
      expect(described_class.find("unknown")).to be_nil
    end
  end

  describe ".keys" do
    it "returns all integration keys matching the catalog" do
      expect(described_class.keys).to match_array(Interop::Catalog.tool_integration_keys)
    end
  end
end
