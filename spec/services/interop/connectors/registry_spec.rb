# frozen_string_literal: true

require "rails_helper"

RSpec.describe Interop::Connectors::Registry do
  describe ".all" do
    it "returns all connector classes" do
      classes = described_class.all
      expect(classes).to include(
        Interop::Connectors::Jira,
        Interop::Connectors::Linear,
        Interop::Connectors::GitLab,
        Interop::Connectors::Bitbucket,
        Interop::Connectors::Slack,
        Interop::Connectors::Teams,
        Interop::Connectors::CiSystems
      )
    end
  end

  describe ".find" do
    it "returns the connector class for a known key" do
      expect(described_class.find("jira")).to eq(Interop::Connectors::Jira)
      expect(described_class.find("linear")).to eq(Interop::Connectors::Linear)
    end

    it "returns nil for unknown keys" do
      expect(described_class.find("unknown")).to be_nil
    end
  end

  describe ".keys" do
    it "returns connector keys matching the catalog" do
      expect(described_class.keys).to match_array(Interop::Catalog.connector_keys)
    end
  end
end
