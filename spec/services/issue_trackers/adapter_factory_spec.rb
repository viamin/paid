# frozen_string_literal: true

require "rails_helper"

RSpec.describe IssueTrackers::AdapterFactory do
  describe ".build" do
    it "builds GithubIssues adapter for github_issues type" do
      config = build(:tracker_configuration, tracker_type: "github_issues")

      adapter = described_class.build(config)

      expect(adapter).to be_a(IssueTrackers::Adapters::GithubIssues)
      expect(adapter.tracker_configuration).to eq(config)
    end

    it "builds Jira adapter for jira type" do
      config = build(:tracker_configuration, :jira)

      expect(described_class.build(config)).to be_a(IssueTrackers::Adapters::Jira)
    end

    it "builds Linear adapter for linear type" do
      config = build(:tracker_configuration, :linear)

      expect(described_class.build(config)).to be_a(IssueTrackers::Adapters::Linear)
    end

    it "builds AzureDevops adapter for azure_devops type" do
      config = build(:tracker_configuration, :azure_devops)

      expect(described_class.build(config)).to be_a(IssueTrackers::Adapters::AzureDevops)
    end

    it "builds Mcp adapter for mcp type" do
      config = build(:tracker_configuration, :mcp)

      expect(described_class.build(config)).to be_a(IssueTrackers::Adapters::Mcp)
    end

    it "builds GenericWebhook adapter for generic_webhook type" do
      config = build(:tracker_configuration, :generic_webhook)

      expect(described_class.build(config)).to be_a(IssueTrackers::Adapters::GenericWebhook)
    end

    it "raises ArgumentError for unknown tracker type" do
      config = build(:tracker_configuration)
      allow(config).to receive(:tracker_type).and_return("unknown")

      expect { described_class.build(config) }.to raise_error(ArgumentError, /Unknown tracker type/)
    end
  end
end
